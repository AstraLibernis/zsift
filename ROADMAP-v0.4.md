# zsift v0.4 — multi-core parsing (plan)

**Status: complete — released as v0.4.0 (2026-09-29).** All milestones M0–M7 done. v0.3.1 is the current release. This page is the plan for
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

> ✅ **Done 2026-09-29.** Each chunk that contains a quote is validated with mask
> operations (`classify.quoteViolation`): an opening quote must start a field or be the
> second quote of `""`; a closing quote must be followed by a separator, a quote or the
> end of input; a region still open at EOF is `UnterminatedQuote`. It reads neighbouring
> bytes only at chunk edges and carries no state, so chunks without quotes pay nothing.
> Adversarial corpus 27/27 (was 16/19); private corpus 7/7; 9 new unit tests over
> `next`, `nextInto`, `forEachField` and `streamReader`. Speed vs v0.3.1 (alternating,
> same process): parity on quote-free files; on a file where 70% of chunks hold quotes,
> median 0.93–0.97× push, 0.97× pull, 0.96× stream, ranges overlapping. A first design
> that counted quotes per field cost 5–14% on push and ~35% on pull, and was dropped.
- A stray quote inside an unquoted field is an error on the SIMD path (`InvalidQuote` or
  `UnterminatedQuote`), not a merged field. Same for an unterminated quote at EOF,
  wherever it opened.
- **Done when:** every adversarial file either parses identically to the scalar `Parser`
  or fails with a named error, on `SimdParser`, `forEachField` and `streamReader`; the
  raw scan speed on the corpus stays within the alternating comparison's range of v0.3.1.

### M2 — Exact record boundaries in parallel

> ✅ **Done 2026-09-29.** `zsift.parallel`: `countQuotes` (SIMD, per range) and
> `recordStartAfter` (first record start after a cut, from its prefix quote parity;
> CRLF never torn) are the two independent phases; `splitRecords` is their serial
> reference. Oracle: parsing the ranges in order with the scalar `Parser` reproduces
> the whole input's field sequence — checked for N = 1…16 over 40 random inputs
> (quoted `\n`/`\r\n`/`\r`, escapes, long quoted fields), from every cut point of 12
> more, and by `zig build verify` for N = 2, 3, 4, cores, 16, 64 on the adversarial and
> private corpora. An odd quote total is `UnterminatedQuote`. Running the phases on
> several cores is M3.
- Split the input into N byte ranges. Each worker counts the quote bytes in its range
  (the existing quote mask plus popcount). A running total gives each range's true
  starting quote state, with no speculation. Each worker then finds its first record
  boundary outside quotes.
- **Done when:** for N = 1…cores and randomised cut points (fuzzed), the boundaries equal
  the serial record boundaries on every corpus file, and a file whose total quote count
  is odd fails with `UnterminatedQuote`.

### M3 — Parallel push API

> ✅ **Done 2026-09-29.** `zsift.parallel.forEachField(io, input, opts, scratches, sinks,
> onField)`: quote counts, record starts and range parses each run as one `Io.Group`
> task per worker; bookkeeping on the stack (≤ 256 workers, `BadWorkerCount` beyond).
> Concatenated sink output equals the serial output for N = 1…16 over 46 random inputs,
> under `std.testing.io` and a real `Io.Threaded` pool; invalid quoting returns the
> serial error (fixed cases + random stray quotes). `verify` runs it as a fifth path
> (N = CPUs, 2, 3, 4, 16, 64): adversarial 27/27, private 7/7. Speed vs serial push,
> 12 workers: **2.6–3.4×** on 18–45 MB files (5–6.8 GB/s); 0.6–1.2× on ≤ 1.7 MB files,
> where task start-up dominates (M4's threshold). Found on the way: sinks packed side by
> side (false sharing) made par *slower* than serial; the API doc now says to keep each
> sink on its own cache line.
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

> ✅ **Done 2026-09-29.** `zig build sweep -- <file>` races push against 2–12 workers on
> record-aligned prefixes from 32 KiB up (results saved beside the private corpus). On
> two real files every worker count lost below 1 MiB (0.03–0.96×); at 2 MiB ~340 KiB
> per worker won on both (1.39–1.43×, worst round ≥ 1.08×) while ~170 KiB broke even on
> one; at 4 MiB ~512 KiB beat ~340 KiB. Hence `parallel.forEachField` is serial below
> `min_parallel_bytes` = 2 MiB and uses one worker per `min_bytes_per_worker` = 384 KiB
> above it; `forEachFieldExact` is the manual control arm. Checked with `compare
> --paths push,auto`: 0.99–1.01× on the four files under 2 MiB (serial), 2.9–3.6× on
> the three over (worst round ≥ 2.35×). `parallel.parseReader` loads known-size input
> (≤ 1 GiB by default) and parses it this way; unknown size streams serially.
- Parallel is on by default above a size threshold; below it the thread start-up costs
  more than it saves. The threshold is measured (a size sweep), not guessed. A serial
  switch stays available as the control arm.
- `parseReader`'s slurp path uses it; streaming stays serial in v0.4.
- **Done when:** the sweep is saved, and the chosen threshold is never slower than
  serial on the corpus (alternating comparison).

### M5 — Typed layers in parallel

> ✅ **Done 2026-09-29.** `parallel.forEachRow(R, …)` (`R` = `reader(T)` or
> `readerWide(T, n)`): with `header`, the first record is read once, serially, and its
> struct-field→column map is shared by every worker. `parallel.forEachRecord` gives a
> `Record` per record; `parallel.splitHeader` captures a `Header` once so `get(name)`
> works in every worker. Both share the split and size-based worker count. Tests over a
> 2.9 MB input (reordered header, an extra column, quoted names with commas, newlines
> and escapes, optional fields): rows and records equal the serial `reader(T)` /
> record loop for 1, 2, 5 and 12 workers, and a bad bool early plus a bad int late
> returns the serial reader's error (the bool). 96 tests.
- `reader(T)` and `Record` per range, with the `Header` captured once from range 0.
- **Done when:** typed rows equal the serial `reader(T)` rows on the corpus.

### M6 — The real workload: zarbor

> ✅ **Done 2026-09-29** (zarbor `e48666f`). zsift is vendored under zarbor's
> `src/vendor/zsift/` (zarbor stays dependency-free). zarbor's `readCsv` splits rows
> with zsift on up to one range per pool thread; each range keeps its own columns and
> dictionaries, merged in file order so level ids stay first-appearance. The three
> loader bugs are fixed, each with a test; a stray quote falls back to the lenient
> scalar parser. Against the previous loader (same process, alternating): the 7
> private files load **byte-identically** and **1.52–1.70×** faster than its all-core
> load (worst round 1.29×); the public csv-spectrum + W3C CSVW suites load identically
> except the 6 files that hit the old bugs, which now match the suites' expected
> output; a real training run gives the same AUC/logloss. Lesson for zsift: M4's
> 2 MiB rule is right for a cheap sink, but zarbor's sink (float parsing, dictionaries)
> was *slower* than the old loader under it (0.78–0.83× on files < 2 MiB); sized with
> `forEachFieldExact` at 64 KiB per worker (swept 32–256 KiB) it won on every file.

**Public test suites (added 2026-09-29).** Hand-built corpora only contain the cases
their author thought of, so `zig build verify` was also run on two public suites
cloned outside the repo: csv-spectrum (12 cases with expected JSON) and the W3C CSVW
test suite (202 CSVs). 213 of 214 agree on every path; the exception is a real
stray quote (a seconds mark in GPS coordinates), which the strict paths now reject as
designed and the lenient scalar parser reads as the suite expects. That shape is now
an adversarial case (`seconds_mark_in_coordinates`).
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

> ✅ **Done 2026-09-29.** README Status, Numbers, layout and roadmap updated with
> `compare`/`sweep` ratios; `build.zig.zon` 0.4.0; tag `v0.4.0`. Final check: 96 tests
> (Debug; ReleaseSafe skips one Windows-only test), `verify` on 28 adversarial, 7
> private and 214 public files — all pass except the public file with a real stray
> quote, which the strict paths reject by design.
- README Status, EXPERIMENTS.md and bench tables updated with `compare` ratios; tag v0.4.0.

## Out of scope for v0.4

- Parallel streaming (records straddling reader windows across workers).
- Lenient quoting on the SIMD path: the scalar `Parser` remains the lenient option.
- Writing CSV, encodings, dialects: unchanged from v0.3 (see README, "What it is").

## Test data

The real-world corpus is private: Kaggle-derived CSV files kept outside every repository
and never published. Only aggregate results (ratios, as above) appear in this repo.
