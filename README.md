# zsift

Fast, zero-allocation parsing of delimited/tabular text in Zig (0.16) — CSV is the
default, but the delimiter and quote are configurable, so TSV, pipe-delimited, and
friends work too. A benchmark harness is built in from day one, so every design
choice is measured, not guessed. zsift offers a lenient scalar parser, a vectorized
(SIMD) fast path, a streaming reader with bounded memory, and an auto-selecting
facade that picks slurp-vs-stream by size.

## What it is — a speedster, not an all-purpose library

zsift does **one job, fast**: turn delimited bytes into fields. That narrow focus
*is* the value — on this VM it measured ~2–2.85× a purpose-built SIMD C parser
(`zsv`) and ~3–5× the common full-featured library (`rust-csv`) on a parse-every-field
task (see [bench/vs-csv-parsers/](bench/vs-csv-parsers/); numbers are VM-specific,
ratios are the point).

It is deliberately **not** a full-featured CSV library. It does not:

- deserialize rows into typed structs (no serde-style mapping);
- **write** CSV — it is read-only;
- support rich dialects beyond a configurable delimiter + quote (no comment chars,
  trimming, per-column rules);
- validate UTF-8 or detect encodings;
- hand you an owned, durable record — a `Field` is a byte-slice that *borrows* the
  input (zero-copy), valid only as long as the input (or scratch) lives.

The missing features and the speed are the **same decision**: zsift hands back
borrowed bytes and gets out of the way, so owning, typing, and validating them is
the caller's job. If you need those conveniences more than raw throughput, reach for
a full parser like [`rust-csv`](https://github.com/BurntSushi/rust-csv) — zsift is
the racecar you bolt onto a pipeline that already knows what it wants from each field.

## Design

Three decisions define a CSV parser; we picked the column that is idiomatic Zig
and leaves the fast path open:

1. **Zero-allocation, pull-based.** `Parser` works over a `[]const u8` and never
   allocates. You pull one `Field` at a time, or one record at a time into a
   buffer you own.
2. **Eager-unescape into a caller scratch buffer.** A field's bytes are normally
   a slice pointing *straight into the input* (zero-copy). The single exception
   is a quoted field containing an escaped quote (`""`), which must be rewritten
   — that goes into a caller-provided scratch buffer, still without allocating.
   This is the middle ground BurntSushi's `csv-core` settled on: a copy, but no
   alloc. True zero-copy would force *lazy* unescaping and a very different API.
3. **Scalar DFA first, SIMD later.** A tight byte loop now; Zig's `@Vector` makes
   a simdjson-style structural-index pass a clean, cross-platform phase 2.

### Lifetime contract

`Field.bytes` that point into the input live as long as the input. Fields that
were unescaped point into `scratch` and stay valid until `resetScratch()`.
`nextRecord` resets scratch at each record boundary, so collecting a whole record
is always safe.

### RFC 4180 + two documented relaxations

- A quote opens a quoted field only as a field's **first** byte; a quote
  elsewhere in an unquoted field is literal (`3" pipe` → `3" pipe`, not an error).
- `\n`, `\r\n`, and a lone `\r` all terminate a record.

A trailing newline does **not** produce a phantom empty record; a genuine blank
line **does** parse as one empty field. A trailing delimiter yields a final empty
field (`"a,"` → `["a", ""]`), matching RFC 4180 / Go / Python.

## Entry points

The in-memory parsers are zero-allocation and share `Options` / `Field` / `Error`.

| Use | Type / fn | Source | Quoting | Notes |
|-----|-----------|--------|---------|-------|
| Lenient, byte-exact | `zsift.Parser` | slice | relaxed (bare quote = literal) | scalar DFA |
| Fast, pull | `zsift.SimdParser` | slice | RFC-4180 strict | vectorized, `next()` API |
| Fast, pull (batched) | `zsift.SimdParser.nextInto` | slice | RFC-4180 strict | a batch of fields per call; amortizes the per-`next()` cost |
| Fastest, push | `zsift.simd.forEachField` | slice | RFC-4180 strict | inlined callback, no per-field call |
| Streaming | `zsift.streamReader` | `*std.Io.Reader` | RFC-4180 strict | bounded memory, push callback |
| Auto | `zsift.parseReader` | `*std.Io.Reader` | RFC-4180 strict | picks slurp vs stream by size |

```zig
const zsift = @import("zsift");

var scratch: [4096]u8 = undefined;          // only touched for "" unescaping

// Scalar, field at a time:
var p = zsift.Parser.init(input, &scratch, .{ .delimiter = ',', .quote = '"' });
while (try p.next()) |f| {
    use(f.bytes);
    if (f.last_in_record) endRow();
}

// Record at a time into a buffer you own (scalar or SIMD):
var fields: [32][]const u8 = undefined;
while (try p.nextRecord(&fields)) |record| {
    for (record) |field| use(field);
}

// Fastest in-memory: push every field to an inlined callback.
const Sink = struct {
    fn onField(self: *@This(), bytes: []const u8, last_in_record: bool) void { ... }
};
var sink = Sink{};
try zsift.simd.forEachField(input, &scratch, .{}, &sink, Sink.onField);

// Streaming from any reader, bounded memory (window = the reader's buffer):
try zsift.streamReader(&reader, &scratch, .{}, &sink, Sink.onField);

// Auto: slurp small inputs into memory (fast), stream large/unknown ones.
const strategy = try zsift.parseReader(gpa, &reader, size_hint, .{}, &sink, Sink.onField);
```

Errors: `UnterminatedQuote`, `InvalidQuote` (text after a closing quote),
`ScratchTooSmall`, `TooManyFields`; streaming adds `RecordTooLong`, `ReadFailed`.

### Streaming + auto-selection

`streamReader` processes the largest whole-records prefix of each reader window in
one batched SIMD pass, then `toss`es it and lets the reader refill. Because it only
ever consumes up to a record boundary, every refill starts outside any quote — so
no quote state crosses a refill. Fields are valid only for the duration of the
callback (the window is reused on refill). A record must fit the window, else
`RecordTooLong`.

`parseReader` is the allocating convenience layer (the `csv`-over-`csv-core`
split): it reads `decide(size_hint, threshold)` and either slurps the whole input
and runs `forEachField` (fastest, for small/known sizes) or streams with bounded
memory (large or unknown size). Both paths feed the same callback, and it returns
which `Strategy` it chose. Size is the selection axis because it decides memory
footprint; quote-density "complexity" doesn't change which path is *correct*, only
the materialization cost, which neither path avoids.

### Why a SIMD path and a separate strict contract

`zsift.Parser` relaxes RFC 4180: a quote that is not the first byte of a field is
literal data (`3" pipe` parses fine). The SIMD path *cannot* honor that cheaply —
it finds quoted regions with a parallel prefix-XOR over the quote bitmask, so a
stray quote would mask the rest of the input as "in string". Every production
SIMD CSV parser (simdcsv, zsv, Sep) makes the same strict-quoting assumption, so
`SimdParser` / `forEachField` are for well-formed RFC 4180 input. A differential
test parses a generated corpus through the scalar and SIMD parsers and asserts
they agree on every field.

## Build

```sh
zig build test                             # unit tests
zig build bench -Doptimize=ReleaseFast     # throughput benchmark
zig build experiment -Doptimize=ReleaseFast # method-selection bake-off (EXPERIMENTS.md)
```

## Source layout

Layered so each concern is one small, independently testable module
(types → classify → {scalar, simd, stream} → facade):

| File | Lines | Role |
|------|-------|------|
| `types.zig`    | ~30  | `Options` / `Field` / `Error`, shared by every parser |
| `classify.zig` | ~100 | SIMD chunk-classification primitives (the vector layer) |
| `scalar.zig`   | ~190 | `Parser` — lenient byte-at-a-time, in-memory |
| `simd.zig`     | ~395 | `SimdParser` (pull / `nextInto`) + `forEachField` (push); mask-based escape detect + run-based `""` collapse |
| `stream.zig`   | ~175 | `streamReader` + auto-selecting `parseReader` |
| `csv.zig`      | ~40  | public API facade — re-exports only |

Tests live in `csv_test.zig` / `simd_test.zig` / `stream_test.zig` (the small
leaf modules `types`/`classify`/`scalar` are covered by `csv_test.zig`) and are
pulled into `zig build
test` from `csv.zig`.

## How the SIMD path works

Per 64-byte chunk (`@Vector(64, u8)`):

1. Compare against `"`, the delimiter, `\n`, `\r` in parallel; `@bitCast` each
   `@Vector(64, bool)` to a `u64` (lowers to movemask on x86).
2. `inside = prefixXor(quote_bits) ^ carry` — a parallel prefix-XOR turns the
   quote bitmask into an "inside a quoted region" mask. We use the portable
   6× shift-XOR doubling, **not** `PCLMULQDQ` (Zig has no carry-less-multiply
   builtin, and shift-XOR is branchless and cross-arch). `carry` propagates the
   in-quote state across chunk boundaries by broadcasting the high bit.
3. `structural = (delim | lf | cr) & ~inside` — real separators only. Pop them
   lowest-first with `@ctz`; each bit is a field boundary. No structural-index
   array, so it stays allocation-free.

Escaped `""` needs no special case for *structure*: in the prefix-XOR it toggles
the region off then on again, exposing no separator between the pair. We collapse
`""` only when materializing a quoted field.

## Numbers

Absolute throughput is machine-specific and, on a shared VM, swings ±30% with host
contention — so the durable facts here are *ratios* and the *method choices*, not a
frozen table. Run `zig build experiment` for current numbers on your own box (see
[EXPERIMENTS.md](EXPERIMENTS.md)). Measured 2026-07-01 on a Hyper-V VM (no GPU;
i7-1365U, AVX2), relative to zsift's own scalar parser on the same data:

- The **push (callback) fast path runs ~2.5–3.5× the scalar parser** on real CSV, and
  reaches roughly **40% of the structural-scan ceiling** (the classifier alone, no
  field extraction). The remaining gap is the unavoidable cost of *delivering* each
  field — slicing it out, the per-field loop — not the escape handling.
- **Escaped `""` is no longer a bottleneck.** The escape decision is read from the
  SIMD quote mask (no per-field byte re-scan), and the collapse copies clean runs
  with `@memcpy` (SWAR-found run boundaries) rather than a byte-at-a-time loop — so
  escape-heavy CSV stays fast instead of dropping toward scalar speed.
- **Pull delivery** has two shapes: `next()` (one field per call) and `nextInto()`
  (a batch per call, holding scan state in registers to amortize the per-call cost).
  **Streaming** runs close to in-memory push at bounded memory (any file in 64 KiB),
  since record framing is vectorized too (`classify.terminatorsAt`).

Which technique wins at each stage — detect an escape, collapse it, chunk width,
delivery shape — was chosen by a reproducible bake-off, not by guessing: `zig build
experiment` runs the whole grid on generated light/heavy corpora, and
[EXPERIMENTS.md](EXPERIMENTS.md) records the method and what won.

For cross-library comparisons — against Rust's common `BurntSushi/rust-csv` and the
specialist SIMD-C `liquidaty/zsv` (same bytes, matched task, fenced) — see
[bench/vs-csv-parsers/](bench/vs-csv-parsers/).

## Trustworthy benchmarking

This is a shared Hyper-V VM; the host steals CPU unpredictably, so `zig build
bench` swings 30%+ between identical runs. Gate each sample through benchfence:

```sh
zig build -Doptimize=ReleaseFast
nu bench.nu --reps 20
```

`bench.nu` is a benchfence **units** driver: it builds a `[{name, argv}]` unit list and hands
it to the vendored `bench/benchfence` binary, which OWNS the gate → measure → postcheck → retry
loop. benchfence pins each unit to a quiet physical core, disables ASLR, sets `LC_ALL=C`, quiets
the desktop, and — before AND after every sample — proves the core is back at its idle speed,
discarding and re-measuring any sample the machine spoiled mid-flight. That is *per-sample* trust
("level 2"). A unit's `best_trusted` is the best of only the gate-passed samples; a uniformly-busy
machine reads stable-but-slow, so the gate compares against the venue's measured floor, not just
pre-vs-post. zsift is a CSV parser — memory-bound — so the driver gates on the **mem referee**
(`--bound mem`): the CPU referee is blind to the DRAM-bandwidth contention that actually slows it.

benchfence is vendored as a single static binary at [`bench/benchfence`](bench/benchfence)
(~900 KB; see [`bench/benchfence.version`](bench/benchfence.version) for the exact build). Nothing
to install or build — it ships with the repo. Override it with `$BENCHFENCE` if you want a
different one; if neither the override nor the vendored binary exists, the driver fails loudly
rather than running unfenced.

## Prior art surveyed (2026-06-30)

- **Zig** — [beho/zig-csv](https://github.com/beho/zig-csv) (low-level, no alloc,
  caller buffer); [matthewtolman/zig_csv](https://github.com/matthewtolman/zig_csv)
  (splits allocating vs zero-allocation parsers);
  [DISTREAT/zig-csv](https://github.com/DISTREAT/zig-csv) (fail-fast).
- **Rust** — [BurntSushi/rust-csv](https://github.com/BurntSushi/rust-csv): a
  DFA core in `csv-core` (`no_std`), eager-unescape, deliberately not zero-copy.
- **Go** — [`encoding/csv`](https://pkg.go.dev/encoding/csv): pull `Reader`,
  `ReuseRecord` to avoid per-row allocation, `LazyQuotes` for lenient input.
- **C / Python** — Python's `_csv` is a hand-written character-at-a-time C state
  machine; pandas ships its own faster C parser (the same allocating-vs-fast
  split recurs everywhere).
- **SIMD frontier** — [geofflangdale/simdcsv](https://github.com/geofflangdale/simdcsv),
  [liquidaty/zsv](https://github.com/liquidaty/zsv): simdjson-style. Find all
  structural bytes (quotes, commas, newlines) per 64-byte chunk with vector
  compares, then a branchless prefix-XOR carry masks separators inside quotes —
  the same approach zsift re-derived here.

> **Raced (2026-07-07).** zsift has now been benchmarked head-to-head against two of
> the above — same corpus bytes, a matched parse-and-sum-every-field task,
> cross-validated counts, fenced. On a Hyper-V VM (i7-1365U, AVX2), across
> clean/quoted/escapey and four randomized shapes:
> - vs **`BurntSushi/rust-csv`** (the common, full-featured library): zsift `push`
>   **3.0–5.2×**, `pull` **2.1–3.3×** — reproducible to ~1% CV over four fenced passes.
> - vs **`liquidaty/zsv`** (the specialist SIMD-C "fastest CSV parser" — the true peer):
>   zsift `push` **2.1–2.85×**, `pull` **1.0–1.6×**. zsv itself beat rust-csv 1.1–2.6×,
>   which is why zsv, not rust-csv, is the honest speed yardstick.
>
> Absolute MB/s are VM-specific — treat the ratios as the finding. Full method, tables,
> tool versions, and the re-runnable harness (both peers):
> [bench/vs-csv-parsers/](bench/vs-csv-parsers/). The remaining libraries above are
> surveyed, not raced.

## Status — settled

Stable and feature-complete for its scope (Zig 0.16). Everything the design set out
to do is built and measured:

- [x] SIMD structural-scan fast path (`@Vector`, portable prefix-XOR)
- [x] Inlined push/callback API to cut per-field dispatch overhead
- [x] Streaming over a `std.Io.Reader` (records straddling buffer boundaries)
- [x] Auto-selecting facade (slurp vs stream by size) — the allocating
      convenience layer over the zero-alloc core
- [x] SIMD record framing for streaming (`classify.terminatorsAt` — no separate
      scalar pass)
- [x] Direct chunk loads (no per-chunk memcpy) + single `classify`/`unescape`
      helpers
- [x] Mask-based escape detection + run-based (`@memcpy` / SWAR) `""` collapse —
      escape-heavy CSV is no longer materialization-bound
- [x] Batched pull (`nextInto`) to amortize the per-call iterator cost
- [x] Reproducible method-selection experiment (`zig build experiment`) + write-up;
      benchmarked head-to-head against rust-csv and zsv (`bench/vs-csv-parsers/`)

**Scope is intentionally closed** (see [What it is](#what-it-is--a-speedster-not-an-all-purpose-library)):
dialect and convenience features — comment lines, trimming, per-column rules, typed
deserialization, writing — are *out of scope*, not backlog. The only conceivable
further work is speed, not surface — trimming field-delivery overhead (the remaining
gap to the scan ceiling) and multi-core parsing at safe record boundaries — and
neither is planned. zsift is done until a real workload asks for one.
