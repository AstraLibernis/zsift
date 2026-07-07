# zsift vs rust-csv — head-to-head parse throughput

A like-for-like benchmark of zsift against Rust's [`BurntSushi/rust-csv`](https://github.com/BurntSushi/rust-csv),
recorded 2026-07-07. This exists because the main README's "Numbers" only compared
zsift to its own scalar path; this measures it against another library.

## Result, scoped

On the machine and workloads below (parse the whole file, touch every field), zsift
was faster than rust-csv on every CSV shape tested:

- **zsift `push`** (zero-copy callback): **3.0–5.2×** rust's `csv::Reader` on random
  workloads (up to 7.3× on trivially clean data).
- **zsift `pull`** (iterator — the same API shape as rust's `read_byte_record` loop):
  **2.1–3.3×**.
- rust-csv performed comparably to zsift's *scalar* (non-SIMD) path — i.e. the gap is
  essentially zsift's vectorized structural scan.

These are **numbers from one throttled shared VM**; treat the *ratios* as the durable
finding and the absolute MB/s as machine-specific. See caveats.

## Method

- **One corpus, both parsers.** Each parser reads the *same bytes* off disk. Corpora
  are generated deterministically by `gen.py` (structured: clean / quoted / escapey)
  and `genrand.py` (randomized shapes), 16 MiB each, 8-bit ASCII CSV, RFC 4180 quoting.
- **Matched task.** Both sides parse the whole file, iterate every field, and sum
  field byte-lengths (a checksum so nothing is optimized away) while counting
  records + fields. No field materialization beyond what each parser does natively.
- **Cross-validated.** Before timing, zsift and both rust layers are checked to agree
  *exactly* on record and field counts for every corpus (they did) — so the two are
  doing identical structural work, not parsing differently.
- **Two rust reference points**, because "rust-csv" has two honest ones:
  - `byterecord` — `csv::Reader` + a reused `ByteRecord` (the common high-level fast path);
  - `core` — `csv_core::Reader`, the `no_std` DFA that unquotes into a caller buffer
    (the closest peer to zsift's low-level, no-per-field-alloc design).
- **zsift paths:** `push` (`forEachField` callback, zero-copy), `pull` (`SimdParser`
  iterator). `scalar` (non-SIMD) is shown in the structured run as a baseline.
- **Fenced.** Every sample runs under [benchfence](https://codeberg.org/AstraLibernis/benchfence)
  `--bound mem` (a CSV parser is memory-bound): pinned to a quiet physical core, and
  each measurement is gated — the core must be back at its idle baseline before the
  sample and stay quiet through it, or the sample is discarded and retaken. The
  headline number is **`best_trusted`**: the fastest gate-verified-clean sample =
  the machine's capability, not a contended outlier.

## Environment

| | |
|---|---|
| Machine | Hyper-V VM, Intel i7-1365U (Raptor Lake, AVX2), no clock lock (base ~1.8 GHz), 6 vCPU = 3 physical cores + SMT, no GPU |
| Venue class | `vm-shared` (host preempts — unstable; this is *why* it's fenced) |
| Date | 2026-07-07 |
| Toolchains | zig 0.16.0 · rustc/cargo 1.96.0 · nu 0.113.1 |
| Libraries | `csv` 1.4.0 · `csv-core` 0.1.13 |
| Fence | benchfence `--bound mem`, cores [2,4], tolerance 8.6% |

## Results

### Randomized workloads — 4 fenced passes (the primary, reproducible result)

Mean of `best_trusted` MB/s across 4 independent fenced sessions; CV = coefficient of
variation across the 4 passes (run-to-run stability).

| workload | shape | zsift push | zsift pull | rust byterecord | rust core | push/byte | pull/byte |
|---|---|--:|--:|--:|--:|--:|--:|
| rand0 | 6 col, mixed, quote 7% | 3158 | 2018 | 612 | 432 | **5.2×** | 3.3× |
| rand1 | 10 col, numeric, quote 45% | 1899 | 1372 | 617 | 467 | **3.1×** | 2.2× |
| rand2 | 12 col, numeric, quote 59% | 1927 | 1398 | 644 | 444 | **3.0×** | 2.2× |
| rand3 | 7 col, mixed, quote 37% | 1800 | 1256 | 523 | 421 | **3.4×** | 2.4× |

Run-to-run CV was **≤1.1%** for every zsift and `byterecord` cell across the 4 passes
(the ratios above were identical to one decimal place every pass). Two `rust/core`
cells wobbled to ~9% CV from a single contended pass; it is the slowest parser
regardless, so it does not affect the finding.

### Structured workloads — single fenced pass (the clean→escapey gradient)

`best_trusted` MB/s. Higher within-run spread (single pass, 15 reps) — directional.

| corpus | records | zsift push | zsift pull | zsift scalar | rust byterecord | rust core |
|---|--:|--:|--:|--:|--:|--:|
| clean | 393,145 | 3343 | 941 | 461 | 459 | 346 |
| quoted | 313,793 | 1646 | 956 | 573 | 399 | 359 |
| escapey | 220,004 | 936 | 700 | 548 | 396 | 415 |

zsift's lead is largest on clean data (SIMD structural scan dominates) and narrows as
quoting/escaping rises (escape handling is where SIMD helps least). rust-csv ≈ zsift
scalar on clean data (459 vs 461).

## Caveats

1. **Absolute MB/s are throttled-VM numbers.** The host preempts a shared core and
   there is no clock lock; a bare-metal run would be faster and tighter for *all*
   parsers. The *ratios* are the durable finding — every parser was measured
   interleaved under the same fence in the same session.
2. **`push` vs `byterecord` is not the same work.** zsift `push` borrows fields from
   the input (zero-copy); rust `ByteRecord` copies each field into an owned record and
   `csv_core` unquotes into a caller buffer. zsift's zero-copy design is a real
   advantage, but the *same-shape* comparison is zsift `pull` vs rust `byterecord`
   (still 2.1–3.3×).
3. **Task is parse-and-touch.** A workload that materializes/copies every field, or
   does heavy per-field work, would narrow zsift's lead.
4. Single delimiter (`,`), ASCII, LF newlines, 16 MiB corpora. No embedded newlines
   in the generated data (embedded commas inside quotes are present).

## Reproduce

From this directory (`bench/vs-rust-csv/`):

```sh
# 0. build zsift release + the rust bench
( cd ../.. && zig build -Doptimize=ReleaseFast )
( cd rustcsv && cargo build --release )

# 1. generate corpora (deterministic; regenerable — not committed)
python3 gen.py corpus            # clean / quoted / escapey
python3 genrand.py rcorpus 4     # rand0..rand3 (params drawn from a fixed master seed)

# 2. fenced runs (edit the hardcoded benchfence path at the top of the drivers first)
benchfence --bound mem --run driver.nu  --reps 15   # structured
benchfence --bound mem --run rdriver.nu --reps 12   # randomized
```

`results/*.json` are the raw recorded outputs from 2026-07-07 (structured + 4 random
passes) and `results/random-workloads.json` records the drawn parameters of each
random workload.

> **Note on the generators:** `gen.py` / `genrand.py` are Python purely for
> disposable data generation — the *measured* code is Zig (zsift) and Rust
> (rust-csv), fed identical bytes. Corpora are deterministic, so the input is fixed
> regardless of the generator's language.
