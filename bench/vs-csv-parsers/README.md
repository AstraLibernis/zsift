# zsift vs other CSV parsers — head-to-head parse throughput

> **Historical record (v0.1.1–v0.3.1).** These runs were driven through benchfence, which
> was retired on 2026-09-29, and the `zig build vs-*` / `random` drivers were removed with
> it. To re-run them exactly as recorded, check out tag `v0.3.1`. The Rust and C harness
> sources and the raw results stay here as the record.

Where zsift stands against two reference points, recorded 2026-07-07:

- **[`BurntSushi/rust-csv`](https://github.com/BurntSushi/rust-csv)** — the *common*
  one: the CSV library most people actually reach for. Full-featured (serde
  deserialization, writing, rich config, UTF-8 validation, error positions). Not a
  pure-speed tool — a useful "what does the popular library do?" yardstick.
- **[`liquidaty/zsv`](https://github.com/liquidaty/zsv)** — the *less common* one: a
  SIMD C parser purpose-built for speed ("world's fastest CSV parser"). Same one job
  as zsift — turn bytes into cells, fast — so this is the true racecar-vs-racecar test.

Both are included on purpose: rust-csv shows the margin over the everyday choice; zsv
shows the margin over a specialist that's actually trying to win the same race.

## Result, scoped

Parse the whole file, touch every field. On the machine and workloads below, zsift was
fastest on every CSV shape tested:

- **vs rust-csv (`csv::Reader`):** zsift `push` **3.0–5.2×** (up to 7.3× on trivially
  clean data), `pull` **2.1–3.3×**. rust-csv landed near zsift's own *scalar* path — the
  gap is essentially zsift's SIMD scan plus its zero-copy delivery.
- **vs zsv (the specialist):** zsift `push` **2.1–2.85×**, `pull` **1.0–1.6×** (roughly
  tied on clean data, ~1.5× ahead once quoting appears).
- **zsv itself beat rust-csv 1.1–2.6×** — confirming zsv, not rust-csv, is the real
  speed peer; racing only against rust-csv would overstate zsift's lead.

Numbers are from one throttled shared VM — treat the **ratios** as the finding, the
absolute MB/s as machine-specific. See caveats.

## Method

- **One corpus, every parser.** Each parser reads the *same bytes* off disk. Corpora
  are generated deterministically by `zig build gen-structured` (clean / quoted / escapey)
  and `zig build gen-random` (randomized shapes), 16 MiB each, 8-bit ASCII CSV, RFC 4180 quoting.
- **Matched task.** Every parser parses the whole file, iterates every field/cell, and
  sums field byte-lengths (a checksum so nothing is optimized away) while counting
  records + fields. No materialization beyond what each parser does natively.
- **Cross-validated.** Before timing, all parsers are checked to agree on record and
  field counts and on the field-length sum for every corpus (they do; zsv emits one
  extra trailing blank row per file — see caveats — but identical field content).
- **Reference points measured:**
  - zsift `push` (`forEachField` callback, zero-copy) and `pull` (`SimdParser` iterator);
    `scalar` (non-SIMD) shown in the structured run as a baseline;
  - rust `byterecord` (`csv::Reader` + reused `ByteRecord`, the common high-level fast
    path) and `core` (`csv_core`, the no_std scalar DFA — rust's low-level floor);
  - zsv (`zsv_new` + per-row handler + `zsv_get_cell`), built `-O3 -march=native -mavx2`.
- **Fenced.** Every sample runs under benchfence (vendored as [`bench/benchfence`](../benchfence))
  `--bound mem` (a CSV parser is memory-bound): pinned to a quiet physical core, each
  measurement gated — the core must be at its idle baseline before the sample and stay
  quiet through it, or the sample is discarded and retaken. Headline = **`best_trusted`**:
  the fastest gate-verified-clean sample (capability, not a contended outlier).

## Environment

| | |
|---|---|
| Machine | Hyper-V VM, Intel i7-1365U (Raptor Lake, AVX2), no clock lock (base ~1.8 GHz), 6 vCPU = 3 physical cores + SMT, no GPU |
| Venue class | `vm-shared` (host preempts — unstable; this is *why* it's fenced) |
| Date | 2026-07-07 |
| Toolchains | zig 0.16.0 · rustc/cargo 1.96.0 · gcc 16.1.1 · nu 0.113.1 |
| Libraries | `csv` 1.4.0 · `csv-core` 0.1.13 · zsv @70cc701 (`-O3 -march=native -mavx2`, UTF-8 check off) |
| Fence | benchfence `--bound mem`, cores [2,4], tolerance 8.6% |

## Results

### Three-way — single fenced pass (`best_trusted` MB/s)

| corpus | zsift push | zsift pull | zsv | rust byterecord | push/zsv | pull/zsv | zsv/rust |
|---|--:|--:|--:|--:|--:|--:|--:|
| clean | 3400 | 1240 | 1193 | 460 | 2.85× | 1.04× | 2.59× |
| quoted | 1612 | 958 | 605 | 394 | 2.66× | 1.58× | 1.54× |
| escapey | 917 | 687 | 429 | 390 | 2.14× | 1.60× | 1.10× |
| rand0 (6c mixed q7) | 3126 | 1995 | 1285 | 610 | 2.43× | 1.55× | 2.11× |
| rand1 (10c num q45) | 1889 | 1360 | 850 | 610 | 2.22× | 1.60× | 1.39× |
| rand2 (12c num q59) | 1924 | 1389 | 889 | 636 | 2.16× | 1.56× | 1.40× |
| rand3 (7c mixed q37) | 1806 | 1249 | 767 | 522 | 2.35× | 1.63× | 1.47× |

Raw: `results/comparison-zsift-zsv-rust.json`.

### zsift vs rust-csv — 4 fenced passes (run-to-run stability)

An earlier run measured zsift push/pull vs rust `byterecord`/`core` over the four random
workloads across **four independent fenced sessions**. `best_trusted` reproduced to
**≤1.1% CV** for every zsift and `byterecord` cell; the push/byterecord and pull/byterecord
ratios were identical to one decimal every pass (push **3.0–5.2×**, pull **2.1–3.3×**).
Raw: `results/random-pass{1..4}.json`, params in `results/random-workloads.json`. This is
why the single-pass three-way table above can be trusted as directional — the zsift/rust
ratios there track the 4-pass numbers.

### Structured gradient — single fenced pass (`best_trusted` MB/s)

| corpus | records | zsift push | zsift pull | zsift scalar | zsv | rust byterecord | rust core |
|---|--:|--:|--:|--:|--:|--:|--:|
| clean | 393,145 | 3400 | 1240 | ~461 | 1193 | 460 | 346 |
| quoted | 313,793 | 1612 | 958 | ~573 | 605 | 394 | 359 |
| escapey | 220,004 | 917 | 687 | ~548 | 429 | 390 | 415 |

(scalar from `results/structured.json`, a separate pass.) zsift's lead is largest on
clean data (SIMD structural scan dominates) and narrows as quoting/escaping rises.

## Caveats

1. **Absolute MB/s are throttled-VM numbers.** Host preempts a shared core, no clock
   lock; bare metal would be faster and tighter for *all* parsers. The **ratios** are the
   finding — every parser measured interleaved under the same fence in the same session.
2. **`push` vs the others isn't identical work.** zsift `push` borrows fields from the
   input (zero-copy); rust `ByteRecord` copies into an owned record; zsv borrows cells
   from its own buffer (close to zsift). The nearest same-shape pairs are zsift `pull`
   ↔ rust `byterecord` and zsift `push`/`pull` ↔ zsv. zsift's zero-copy design is a real
   advantage — and part of why it's fast — but it means the caller does anything more.
3. **zsv trailing blank row.** zsv emits one blank row per file for the trailing newline
   that zsift/rust suppress: +1 row, +1 empty cell, 0 bytes. `sumlen` is byte-identical
   across all three, so it's a counting convention, not a parsing difference.
4. **Single fenced pass** for the three-way + structured tables (spreads 2–32%); the
   zsift-vs-rust ratios are additionally backed by the 4-pass stability run above.
5. Single delimiter (`,`), ASCII, LF newlines, 16 MiB corpora, no embedded newlines
   (embedded commas inside quotes are present). zsv/zsift built with UTF-8 validation
   off, matching each other.

## Reproduce

All commands run from the repo root (`zig build` drives everything):

```sh
# build the three parsers
zig build -Doptimize=ReleaseFast                          # zsift
( cd bench/vs-csv-parsers/rustcsv && cargo build --release )  # rust-csv bench
#   zsv: see BUILD-zsv.md (clone + build + compile zsvbench)

# generate corpora (deterministic; regenerable — not committed). The default dirs are
# bench/vs-csv-parsers/{corpus,rcorpus}; override with $ZSIFT_CORPUS_DIR / $ZSIFT_RCORPUS_DIR.
zig build gen-structured -- bench/vs-csv-parsers/corpus     # clean / quoted / escapey
zig build gen-random     -- bench/vs-csv-parsers/rcorpus 4  # rand0..rand3 + meta.json

# fenced runs (at tag v0.3.1 only; the drivers were removed with benchfence)
zig build vs-all  -- --reps 12    # three-way (zsift/zsv/rust), structured + random
zig build vs-rust -- --reps 15    # zsift vs rust, structured
zig build random  -- --reps 12    # zsift vs rust, random
```

At v0.3.1 these were the `bench drive` subcommands (`src/bench/drive.zig`). Each built a
`[{name, argv}]` unit list and hands it to `bench/benchfence`, which owns the
gate → measure → retry loop and applies the fence itself (so the units carry no `taskset`).
The corpus path is each unit's trailing argv argument — there is no `$ZSIFT_CORPUS` to set.
Paths resolve as `$ENV override → repo-relative default → loud error`: a missing comparison
binary (`$RUSTCSV_BENCH`, `$ZSVBENCH`) or corpus fails loudly rather than silently skipping.

`results/*.json` are the raw recorded outputs (2026-07-07).

> **Note on the generators:** the corpus generators are now Zig (`zig build gen-*`,
> `src/bench/gen.zig`) — disposable data-gen only. The *measured* code is Zig (zsift),
> Rust (rust-csv), and C (zsv), fed identical bytes; corpora are deterministic, so the
> input is fixed across runs.
