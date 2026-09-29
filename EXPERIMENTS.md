# How zsift's parser methods were chosen — and how to reproduce it

zsift's SIMD parser is an assembly line. Every field goes through the same stations:

```
SCAN (classify 64 bytes at once) -> CUT (slice fields at separators)
     -> CHECK (does this field have an escaped "") -> FIX (collapse "" -> ")
     -> DELIVER (hand the field to the caller)
```

At each station there were several candidate techniques. Rather than guess, we ran
a bake-off at every station, on data of different escape densities, and kept the
winner. This file records the method, the results, and how to run it yourself.

## Reproduce it

```
zig build experiment -Doptimize=ReleaseFast
```

Self-contained: it generates two deterministic corpora — **light** (~5% of fields
carry an escaped `""`) and **heavy** (~60%) — with realistic varied field lengths,
some quoted fields crossing 64-byte chunk boundaries, and prints a bake-off at each
station. No external data file is needed. To run a single station on a **real** CSV
instead, set `ZSIFT_CORPUS=/path/file.csv` and use `bench matrix | width | delivery
| project`.

**Trust caveat.** Raw throughput on a shared/VM box wanders with host contention, so
the *absolute* MB/s are machine-specific and only the *relative* ordering is
meaningful. The method choices recorded here were confirmed at the time with the (now
retired) benchfence gate; see the README's "Measuring" section for how zsift measures now.

## What each station tests, and what won

Directions below are relative to the current parser; absolute figures are from a
Hyper-V VM (i7-1365U, AVX2, no AVX-512), 2026-07-01, and will differ elsewhere.
(The tool prints four stations, `STATION 1/4`…`4/4`: it fuses CHECK + FIX below
into one `DETECT × COLLAPSE` matrix — the two dimensions are measured together.)

### 1. CHECK — detect an escaped `""` (`detect`)
Candidates: `rescan` (re-scan the field bytes with `indexOfScalar`), `swar`
(word-at-a-time byte scan), `accum` (count quotes from the SIMD mask the classifier
already produced — no byte re-scan).

**Winner: `accum`.** It is nearly free (the quote positions are a by-product of
finding field boundaries) and beats `rescan`/`swar` at every escape density. A
`none` diagnostic column (skip detection) shows the ceiling; `accum` sits close to
it, so there is little left to win here.

### 2. FIX — collapse `""` to `"` (`collapse`)
Candidates: `byteloop` (byte-by-byte with a per-byte branch), `memcpy` (copy clean
runs, `std.mem.indexOfScalarPos` finds runs), `swarcpy` (copy clean runs, a SWAR
scan finds runs), `mask` (copy clean runs, the classifier's quote mask finds runs).

**Winner: `swarcpy`** (`mask` ties it). `byteloop` is catastrophic — its cost
explodes with escape density (the per-byte branch mispredicts). The run-based
copies are far better; among them the `@memcpy` dominates, so *how* the run
boundaries are found barely matters (`swarcpy ≈ mask > memcpy`). `swarcpy` ships as
the simplest of the top group. **This was the biggest single win** and, at first,
the overlooked one — `byteloop`->`swarcpy` alone is worth far more than the
detection change on escape-heavy data.

### 3. SCAN — classifier chunk width
Candidates: 32 / 64 / 128-byte SIMD vectors.

**Winner: 64 (as a safe default).** 32 is clearly worst — too much per-chunk fixed
cost (movemask/popcount/loop). 64 and 128 are close and the ordering flips with data
and contention, so this is **not** a robust win for either; 64 ships because 128
relies on emulated `u128` masks on AVX2 (a codegen/portability risk) for no reliable
gain. Resolve 64-vs-128 with a gated run if it ever matters.

### 4. DELIVER — API shape (`delivery`)
Candidates: `pull` (`next()`, one field per call), `pull-batch` (`nextInto`, a batch
per call), `push` (`forEachField`, a callback per field).

**Fastest: `push`** (the consumer is fully inlined). `pull` pays a "tax" for
round-tripping iterator state through memory each call; **`nextInto` recovers
~13–17% of that** by holding the state in registers across a batch. All three are
correct (proven by the differential fuzz); pick by ergonomics.

### 5. CONSUME — eager vs lazy materialization
Not a parser knob but a caller choice, measured under a *projection* workload (read
1 of every N fields). Eager collapses every field; lazy collapses only fields the
caller keeps.

**Result:** identical when you read everything; lazy is up to **~1.7×** faster when
you project a few of many columns, and the gain grows with escape density. Lazy is
therefore worth a dedicated API (return raw + a "needs-collapse" flag) but is not a
sensible default.

## The shipped parser
`accum` detection + `swarcpy` collapse, 64-byte chunks, `push`/`pull`/`nextInto`
delivery, eager by default. Net vs the pre-optimization parser (paired, gated):
clean data at parity, ~1.8× on light-quoted real CSV, ~3× on escape-heavy — with no
regression on the common unquoted case.

## Method notes (why it looks the way it does)
- **Bake-off, not one-at-a-time.** Laying every candidate in a grid per station is
  what surfaced that the *collapse* step (not detection) held most of the headroom —
  tweaking one axis at a time had hidden it.
- **Density sweep.** Testing light vs heavy escape density showed the winners hold,
  and that the collapse lever *scales* with density (so a single datapoint understates it).
- **Gate for trust.** A proxy that skipped *necessary* work once suggested a ~2.5×
  that wasn't achievable; only gated, paired measurements told the real story.
- **Correctness first.** Every "correct" cell is checked byte-for-byte against the
  scalar parser over the whole corpus, and the fast paths carry a 400-case
  differential fuzz (`src/simd_test.zig`).

## v0.4: when multi-core pays (2026-09-29)
`zig build sweep -- <file>` races serial push against 2–12 workers on record-aligned
prefixes of a real file, alternating within rounds. With a cheap sink, every worker
count lost below 1 MiB; at 2 MiB ~340 KiB per worker won on both files tried
(1.39–1.43×); at 4 MiB ~512 KiB beat ~340 KiB — hence `parallel.forEachField`'s
2 MiB / 384 KiB rule. A sink doing real work per field moves the crossover far down:
zarbor's loader wins at 64 KiB per worker (swept 32–256 KiB). One measurement trap:
per-worker sinks packed in one array made 12 workers *slower* than one (false
sharing); aligned to cache lines, the same run was 2.6–3.4× faster than serial.
