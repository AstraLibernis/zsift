# zsift

Fast, zero-allocation parsing of delimited/tabular text in Zig (0.16) — CSV is the
default, but the delimiter and quote are configurable, so TSV, pipe-delimited, and
friends work too. A benchmark harness is built in from day one, so every design
choice is measured, not guessed. zsift offers a lenient scalar parser, a vectorized
(SIMD) fast path, a streaming reader with bounded memory, and an auto-selecting
facade that picks slurp-vs-stream by size.

## Status — complete (v0.3.1)

zsift set out to answer one question: **can you build a faster CSV parser in Zig?**
The answer is yes. On a parse-every-field task it measured ~2.1–2.85× a purpose-built SIMD
C parser (`zsv`) and ~3.0–5.2× the common full-featured library (`rust-csv`); with the
opt-in [typed layers](#typed-layers) it still beats `rust-csv`'s serde path (~1.4×
fenced) on the same deserialize-into-structs task — and it stays correct and fast on
real messy data (validated against the Titanic dataset: exact survivor/missing-value
counts through quoted commas and blank cells). That question is answered, so this is
**feature-complete and parked** — not abandoned, done. **Next: v0.4 multi-core parsing is planned** — see [ROADMAP-v0.4.md](ROADMAP-v0.4.md), which also records a silent-misparse bug on the SIMD path (a stray mid-field quote) that it fixes first. It is deliberately not chasing
feature-parity with full CSV toolkits (writers, dialects, a CLI); mature options
already fill that space. Bug fixes welcome; scope expansion is out of scope by design.

## What it is — a speedster, not an all-purpose library

zsift does **one job, fast**: turn delimited bytes into fields. That narrow focus
*is* the value — on this VM it measured ~2.1–2.85× a purpose-built SIMD C parser
(`zsv`) and ~3.0–5.2× the common full-featured library (`rust-csv`) on a parse-every-field
task (see [bench/vs-csv-parsers/](bench/vs-csv-parsers/); numbers are VM-specific,
ratios are the point).

It is deliberately **not** a full-featured CSV library. It does not:

- **write** CSV — it is read-only;
- support rich dialects beyond a configurable delimiter + quote (no comment chars,
  per-column rules; whitespace trimming is available per-field via `Field.trimmed`);
- validate UTF-8 or detect encodings;
- hand you an owned, durable record — a `Field` is a byte-slice that *borrows* the
  input (zero-copy), valid only as long as the input (or scratch) lives.

The missing features and the speed are the **same decision**: zsift hands back
borrowed bytes and gets out of the way, so owning and validating them is the caller's
job. If you need owned records, a writer, or UTF-8 validation more than raw
throughput, reach for a full parser like
[`rust-csv`](https://github.com/BurntSushi/rust-csv) — zsift is the racecar you bolt
onto a pipeline that already knows what it wants from each field.

**Typing, though, is now built in — without taxing the raw path.** An *opt-in* layer
sits over the borrowed fields: convert a field with `field.as(T)`, reach columns by
name with a `Header`, or deserialize whole records into a struct with `reader(T)`
(see [Typed layers](#typed-layers)). It costs nothing when unused (Zig compiles only
what you call) and, when used, you pay only for the fields you actually type — the
same conversion cost *any* parser pays. The raw `forEachField`/`SimdParser` scan is
byte-for-byte untouched. This is the opposite of `rust-csv`'s serde path, which types
on the hot path; a fenced end-to-end comparison (both deserializing into the same
struct) still put zsift ahead — by a smaller, honest margin than the untyped scan.

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
| Typed rows | `zsift.reader(T)` | slice | RFC-4180 strict | opt-in struct deserialize over `SimdParser` (see [Typed layers](#typed-layers)) |

```zig
const zsift = @import("zsift");

var scratch: [4096]u8 = undefined;          // only touched for "" unescaping

// Scalar, field at a time. `init` validates Options and is fallible:
var p = try zsift.Parser.init(input, &scratch, .{ .delimiter = ',', .quote = '"' });
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
`ScratchTooSmall`, `TooManyFields`, `InvalidOptions` (delimiter equals quote, or
either is a `\n`/`\r`; returned by `init` and the push/stream entry points);
streaming adds `RecordTooLong`, `ReadFailed`.

## Typed layers

Everything above hands back a borrowed `Field` (`bytes` + `last_in_record`). On top
of that sit three **opt-in** layers that make the fields *usable* — named columns,
typed values, whole-struct rows — without touching the scanner. They cost nothing
when unused (Zig compiles only reachable code) and, when used, convert only the
fields you ask for. All three preserve the borrow: a `[]const u8` a layer hands back
still points into the input (or scratch), valid only until the next read.

```zig
// 1. Field converters — parse a borrowed field on demand (fail loud on bad input).
const age: u32 = try field.as(u32);        // int / float / bool / enum / []const u8
const note: ?[]const u8 = try field.asOptional([]const u8); // empty cell -> null
const clean = field.trimmed();             // zero-copy sub-slice, still borrowed

// 2. Header — reach columns by name (zero-alloc view over the first record).
var slots: [32][]const u8 = undefined;
const header = zsift.Header.capture(first_record, &slots); // survives later reads
if (header.col(record, "email")) |f| use(f.bytes);

// 3. reader(T) — deserialize each record straight into your struct.
const Row = struct { id: i64, price: f64, active: bool, name: []const u8 };
var rdr = try zsift.reader(Row).init(input, &scratch, .{});
try rdr.withHeader();                        // opt-in: match struct names to columns
while (try rdr.next()) |row| use(row.id, row.name); // row borrows until the next next()
```

`reader(T)` maps struct field *i* to column *i* by default; `withHeader` instead
matches struct field **names** against the first record (any column order). It
monomorphizes per struct — the per-record fill is an `inline for` that lowers to
exactly the converters your fields need. Supported field types: ints, floats, `bool`,
enums (exact tag match), `[]const u8`, and optionals of those (an empty cell →
`null`); any other type is a **compile error** naming the type. A record wider than a
strict `reader(T)` is a `TooManyFields` error — use `readerWide(T, max_cols)` for
headered CSVs with columns your struct doesn't name. There's also a `Record` view
(`rec.at(i)`, `rec.get("name")`, `rec.as(i, T)`) for ad-hoc access without a struct.

Converters return real errors (`ConvertError.{InvalidInt,InvalidFloat,InvalidBool,
InvalidEnum}`), never a silent default; `reader` adds `MissingColumn`,
`MissingHeaderColumn`, `EmptyHeader`. **Lifetime:** a returned `T` (or `Field`) with
`[]const u8` fields borrows the input/scratch and is valid only until the next
`next()`; copy the bytes to keep them. Value fields (ints/floats/bools/enums) are
independent copies and always safe. The quoted-empty `""` and a truly-empty cell are
indistinguishable (both `len == 0`), so an optional treats both as `null`; use
`[]const u8` if you need the empty string.

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
(convert → types → simd(classify) → {scalar, stream} → {header, record, reader} →
facade). Source is grouped into `src/core/` (the parser + typed layers),
`src/bench/` (benchmark + drivers), and `src/test/`:

| File | Lines | Role |
|------|-------|------|
| `core/convert.zig` | ~75  | `[]const u8 → T` field converters (`as`/`asInt`/…) + `ConvertError` — the bottom layer |
| `core/types.zig`  | ~95  | `Options` (+ `validate`) / `Field` (+ typed methods) / `Error`, shared by every parser |
| `core/scalar.zig` | ~195 | `Parser` — lenient byte-at-a-time, in-memory |
| `core/simd.zig`   | ~520 | `SimdParser` (pull / `nextInto`) + `forEachField` (push) + the `classify` chunk primitives (folded in); mask-based escape detect + run-based `""` collapse |
| `core/stream.zig` | ~210 | `streamReader` + auto-selecting `parseReader` |
| `core/header.zig` | ~55  | zero-alloc name→column view over a header record |
| `core/reader.zig` | ~120 | `reader(T)` / `readerWide(T, n)` — opt-in typed struct rows over `SimdParser` |
| `core/record.zig` | ~50  | ergonomic borrowed `Record` view (`.at` / `.get` / `.as` / `.count`) |
| `csv.zig`         | ~70  | public API facade — re-exports only |

Tests live in `src/test/` (`csv_test.zig` / `simd_test.zig` / `stream_test.zig` /
`options_test.zig` / `convert_test.zig` / `header_test.zig` (+ `Record`) /
`reader_test.zig`; the leaf modules `types` / `scalar` are covered by `csv_test.zig`
and `options_test.zig`) and are pulled into `zig build test` from `csv.zig`.

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
specialist SIMD-C `liquidaty/zsv` (same bytes, matched task, fenced with the now-retired
benchfence; reproducible at tag v0.3.1) — see [bench/vs-csv-parsers/](bench/vs-csv-parsers/).

## Measuring

This is a shared VM (WSL2 / Hyper-V); the host steals CPU unpredictably, so a single
absolute MB/s swings 30%+ between identical runs. zsift therefore measures **ratios under
shared noise**, and checks correctness before it times anything:

```sh
zig build verify -- <files or dirs>                           # every path agrees with the scalar oracle
zig build compare -Doptimize=ReleaseFast -- <files or dirs>   # alternating comparison
```

`compare` (`src/bench/compare.zig`) times one full pass of every parser path per round,
rotating which goes first, for N rounds (`--rounds`, default 15, after one warm-up). All
contenders see the same moment's contention, so the per-round speed ratio is stable even
when absolute MB/s is not. It reports each path's median MB/s with its range, and the
median ratio against the first path with its min–max; every sample is saved as JSON. It
refuses to time paths whose output differs. `verify` (`src/bench/verify.zig`) runs the
scalar parser (the oracle), pull, push and stream over the same bytes and judges each
file; `zig build gen-adversarial -- <dir>` writes the edge-case corpus it is designed for.
With no paths, both use `$ZSIFT_TESTDATA` (a private real-world corpus kept outside the
repo) and write their reports beside it; unset, they say SKIPPED rather than pass.

**benchfence is retired** (2026-09-29). Numbers up to v0.3.1 were gated with it; it is no
longer used by anything here. Its source was lost when this project moved from Codeberg
to GitHub because of Codeberg's anti-AI rules; the stripped binary is kept at
[`bench/benchfence`](bench/benchfence) only as the record of how those numbers were made,
and [`bench/BENCHFENCE.md`](bench/BENCHFENCE.md) documents what it did.

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

## Roadmap — all done

Everything the design set out to do is built and measured (see [Status](#status--complete-v031)):

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
- [x] Opt-in typed layers (v0.3.0): `Field.as(T)` / `trimmed`, `Header`, `reader(T)`,
      `Record` — zero cost when unused, raw scan untouched

**Scope is intentionally closed** (see [What it is](#what-it-is--a-speedster-not-an-all-purpose-library)):
dialect features — comment lines, per-column rules, encodings, writing — are *out of
scope*, not backlog. (Trimming and typed deserialization shipped in v0.3.0 as opt-in
layers over the borrowed fields, precisely because they cost nothing on the raw path.) The only conceivable
further work is speed, not surface — trimming field-delivery overhead (the remaining
gap to the scan ceiling) and multi-core parsing at safe record boundaries — and
neither is planned. zsift is done until a real workload asks for one.

## License

LGPL-3.0-or-later · Copyright (C) 2026 AstraLibernis

zsift is free software: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See `COPYING.LESSER`, which builds on the GNU General Public License in `COPYING`.

In short: any program, open or closed, may use this library, but the library itself and every change to it stay free.

**Exception: `bench/benchfence`.** The benchmark-fencing binary bundled under `bench/` is a separate tool by the same author, released under the MIT License. It is not part of the library.

Versions up to and including commit `31ce1c9` were released under the MIT License; copies obtained under those terms keep them.

Contributions are welcome under the [Developer Certificate of Origin](https://developercertificate.org/): sign off each commit with `git commit -s`. You keep the copyright on your contribution.
