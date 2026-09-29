# zsift v0.4 — multi-core parsing (plan)

**Status: M0 done (2026-09-29); M1 next.** v0.3.1 is the current release. This page is the plan for
the one piece of further work the README named: "multi-core parsing at safe record
boundaries … done until a real workload asks for one." A real workload has asked:
**zarbor**'s model training, the largest consumer of CSV data in these projects.

## Why

Measured 2026-09-29 (i7-1365U under WSL2, best of 5–7, **not fenced**: directions, not
headline numbers), zsift against zarbor's own CSV loader, on a synthetic 65 MB training
table and a private real-world corpus (see [Test data](#test-data)):

| What | Result |
|---|---|
| Splitting fields only | zsift **3.6–5.3×** faster (2.4–3.5 GB/s vs 0.5–1.0 GB/s) |
| Full load (type sniff, NA rule, dictionaries, f32 columns), both 1 thread | zsift **1.2–1.4×** faster |
| Full load, zarbor on all 12 threads vs zsift on 1 | zarbor **1.3–1.4×** faster on the large files |

Both loaders produced byte-identical tables on every file, so the comparison is fair. The
split alone runs at about a third of zsift's own scan ceiling (~9 GB/s), so it is limited
by field delivery, not memory bandwidth: more cores have room to help. For a model
loader, most of the time is spent converting fields (float parsing, dictionary lookups),
so the bigger win is running the *caller's* per-field work on every core.

**Target:** a zsift-based load that is byte-identical to zarbor's and beats zarbor's
all-core load in an alternating comparison (median ratio with its min–max, over many
rounds). If it does not beat it, it does not ship.

## Accuracy first: a bug found while planning

On `id,item,v` / `1,3" pipe,1.5` / `2,plain,2.5` / `3,other,3.5`, the SIMD path
(`SimdParser`, `forEachField`) returns **one** record whose second field swallows the rest
of the file, with **no error**. The stray `"` opens a quoted region that never closes,
and the `UnterminatedQuote` check only runs for fields that *begin* with a quote. The
README promises that an unclosed quote is an error. A parallel version built on the same
quote mask would scramble data the same way, silently, so this is fixed before anything
else (milestone 1).

## Milestones

Each milestone has a done-when that is checked by a test or a saved run, never by reading
the code. The oracle for every correctness claim is the serial path (the scalar `Parser`
for lenient input, serial `forEachField` for strict input), not a re-derivation of the new
code.

### M0 — Corpus and baseline

> ✅ **Done 2026-09-29.** Adversarial corpus: 19 cases, 16 pass; the 3 failures are M1's
> bugs (stray quotes merge records silently on every strict path; text after a closing
> quote reports `UnterminatedQuote` instead of `InvalidQuote`). Private corpus: all 4
> paths agree on every file. Alternating comparison saved for every file: push runs
> 2.5–2.9× the scalar parser (median per file), stream 2.0–2.2×.
- `$ZSIFT_TESTDATA` points at a private real-world corpus. No default: unset means those
  tests and benches **skip loudly**, never pass silently. The data never enters the repo.
- A generated adversarial corpus, committed as a generator (not data): quoted newlines,
  escaped quotes, quoted delimiters, CRLF, no trailing newline, blank lines, 600+ columns,
  a stray mid-field quote, an unterminated quote at EOF, one huge record, empty input.
- A comparison bench (serial zsift vs the zarbor-equivalent load) that verifies
  identical output before timing and saves every sample to JSON after each mode.
- **Done when:** `verify` and `compare` results for every corpus file are saved.
- **Measurement:** benchfence was tried for the baseline and retired (no source to fix;
  on WSL it rejected most samples). Every speed claim in v0.4 is a ratio from
  `zig build compare`: paths alternate within each round, so they share the noise.

### M1 — Strict path never misparses silently
- A stray quote inside an unquoted field is an error on the SIMD path (`InvalidQuote` or
  `UnterminatedQuote`), not a merged field. Same for an unterminated quote at EOF,
  wherever it opened.
- **Done when:** every adversarial file either parses identically to the scalar `Parser`
  or fails with a named error, on `SimdParser`, `forEachField` and `streamReader`; the
  raw scan speed on the corpus stays within the alternating comparison's range of v0.3.1.

### M2 — Exact record boundaries in parallel
- Split the input into N byte ranges. Each worker counts the quote bytes in its range
  (the existing quote mask plus popcount). A running total gives each range's true
  starting quote state, with no speculation. Each worker then finds its first record
  boundary outside quotes.
- **Done when:** for N = 1…cores and randomised cut points (fuzzed), the boundaries equal
  the serial record boundaries on every corpus file, and a file whose total quote count
  is odd fails with `UnterminatedQuote`.

### M3 — Parallel push API
- `zsift.parallel.forEachField(io, input, opts, scratches, sinks)`: one sink and one
  scratch buffer per worker, provided by the caller, so zsift still never allocates.
  Concurrency comes from the caller's `std.Io` (`Io.Group.concurrent`), so the worker
  count follows the machine and zsift starts no threads of its own.
- Each sink receives its range index and its fields in order; the caller merges ranges
  in index order. Errors report the earliest failing byte position, so a parallel run
  reports the same error as a serial one.
- **Done when:** concatenating the sinks' output in range order equals the serial field
  sequence exactly, on every corpus file and every N from 1 to the core count.

### M4 — Auto-selection
- Parallel is on by default above a size threshold; below it the thread start-up costs
  more than it saves. The threshold is measured (a size sweep), not guessed. A serial
  switch stays available as the control arm.
- `parseReader`'s slurp path uses it; streaming stays serial in v0.4.
- **Done when:** the sweep is saved, and the chosen threshold is never slower than
  serial on the corpus (alternating comparison).

### M5 — Typed layers in parallel
- `reader(T)` and `Record` per range, with the `Header` captured once from range 0.
- **Done when:** typed rows equal the serial `reader(T)` rows on the corpus.

### M6 — The real workload: zarbor
- zarbor loads through zsift in parallel, keeping its own sniff, NA rule and
  dictionaries. This also fixes three zarbor loader bugs measured on 2026-09-29: a
  quoted newline splits a row (and can flip a numeric column to categorical), escaped
  `""` stays doubled in category labels, and columns past 512 are dropped without an
  error.
- zarbor tolerates stray mid-field quotes today, so it keeps a lenient fallback to the
  scalar `Parser` when M1's error fires.
- **Done when:** zarbor's tables are byte-identical to today's on every corpus file
  without those bugs, and its load time beats today's all-core `readCsv` (median ratio
  and its min above 1.0 in an alternating comparison).
  (This milestone lands in the zarbor repo.)

### M7 — Release v0.4.0
- README Status, EXPERIMENTS.md and bench tables updated with `compare` ratios; tag v0.4.0.

## Out of scope for v0.4

- Parallel streaming (records straddling reader windows across workers).
- Lenient quoting on the SIMD path: the scalar `Parser` remains the lenient option.
- Writing CSV, encodings, dialects: unchanged from v0.3 (see README, "What it is").

## Test data

The real-world corpus is private: Kaggle-derived CSV files kept outside every repository
and never published. Only aggregate results (ratios, as above) appear in this repo.
