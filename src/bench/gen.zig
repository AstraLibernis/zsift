// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! bench/gen.zig — deterministic CSV corpus generators, in Zig.
//!
//! Replaces the former Python generators (gen.py / genrand.py). Throwaway data-gen:
//! the measured code is Zig (zsift) vs the Rust/C baselines, all fed the *same*
//! generated files, so fairness comes from feeding identical bytes to every parser —
//! NOT from matching the old Python output. Generation is deterministic (fixed seeds
//! via `std.Random.DefaultPrng`), so a given command reproduces identical corpora.
//!
//! `bench gen structured <dir>`   — clean/quoted/escapey, 8 cols (mirrors bench.zig's
//!                                  in-memory `generate()` profiles, written to files).
//! `bench gen random <dir> [N]`   — N randomized workloads (varying cols/style/quote
//!                                  rates) + a `meta.json` describing them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const print = std.debug.print;

const target_bytes = 16 * 1024 * 1024;

pub const GenError = error{BadArgs};

/// `args` is everything after `bench gen` (so `args[0]` is the generator kind).
pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const alloc = init.arena.allocator();
    if (args.len == 0) {
        print("usage: bench gen <structured|random> <dir> [N]\n", .{});
        return GenError.BadArgs;
    }
    if (eql(u8, args[0], "structured")) return structured(init, alloc, args[1..]);
    if (eql(u8, args[0], "random")) return random(init, alloc, args[1..]);
    if (eql(u8, args[0], "typed")) return typed(init, alloc, args[1..]);
    print("unknown generator '{s}' (structured|random|typed)\n", .{args[0]});
    return GenError.BadArgs;
}

fn ensureDir(init: std.process.Init, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, dir); // mkdir -p; no error if it exists
}

fn writeCorpus(init: std.process.Init, alloc: Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
}

fn mib(n: usize) f64 {
    return @as(f64, @floatFromInt(n)) / (1024.0 * 1024.0);
}

// ---------------------------------------------------------------------------
// Structured corpora (clean / quoted / escapey), 8 columns
// ---------------------------------------------------------------------------

const words = [_][]const u8{
    "alpha", "bravo", "charlie", "delta",  "echo", "foxtrot",
    "golf",  "hotel", "india",   "juliet", "kilo", "lima",
    "1234",  "56.78", "true",    "",       "n/a",  "x",
};
const cols = 8;

fn structured(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    if (rest.len == 0) {
        print("usage: bench gen structured <dir>\n", .{});
        return GenError.BadArgs;
    }
    const dir = rest[0];
    try ensureDir(init, dir);
    const profs = [_]struct { name: []const u8, quote_pct: u8, escape_pct: u8 }{
        .{ .name = "clean", .quote_pct = 0, .escape_pct = 0 },
        .{ .name = "quoted", .quote_pct = 30, .escape_pct = 0 },
        .{ .name = "escapey", .quote_pct = 60, .escape_pct = 50 },
    };
    for (profs) |p| {
        const bytes = try genStructured(alloc, p.quote_pct, p.escape_pct);
        const name = try std.fmt.allocPrint(alloc, "{s}.csv", .{p.name});
        try writeCorpus(init, alloc, dir, name, bytes);
        print("{s}: {d:.2} MiB\n", .{ name, mib(bytes.len) });
    }
}

fn genStructured(alloc: Allocator, quote_pct: u8, escape_pct: u8) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0xC5_7A_BE_11);
    const r = prng.random();
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(alloc, target_bytes + 4096);
    while (out.items.len < target_bytes) {
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            if (c != 0) try out.append(alloc, ',');
            const w = words[r.uintLessThan(usize, words.len)];
            if (r.uintLessThan(u8, 100) < quote_pct) {
                try out.append(alloc, '"');
                try out.appendSlice(alloc, w);
                if (r.boolean()) try out.appendSlice(alloc, ",more"); // forces quoting
                if (r.uintLessThan(u8, 100) < escape_pct) try out.appendSlice(alloc, "\"\"q\"\"");
                try out.append(alloc, '"');
            } else {
                try out.appendSlice(alloc, w);
            }
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Typed corpus (for the honest reader(T) vs rust-csv serde benchmark)
// ---------------------------------------------------------------------------

/// The header + column types match `bench.zig`'s `TypedRow` and the rust `serde` mode:
/// id (i64), price (f64), flag (bool), name ([]const u8), category (enum tag). Every
/// cell is clean (no quoting/escaping needed) so all three parsers deserialize it.
pub const typed_header = "id,price,flag,name,category\n";
const typed_names = [_][]const u8{
    "alpha", "bravo", "charlie", "delta", "echo",  "foxtrot",
    "golf",  "hotel", "india",   "juliet", "kilo", "lima",
};
const typed_cats = [_][]const u8{ "alpha", "bravo", "charlie", "delta" };

/// Deterministic ~16 MiB typed CSV with a header row. Reused by `bench <p> typed`
/// (standalone) and written to `typed.csv` by `bench gen typed`.
pub fn genTypedBytes(alloc: Allocator) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0x7D_9E_D0_0C);
    const r = prng.random();
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(alloc, target_bytes + 4096);
    try out.appendSlice(alloc, typed_header);
    var line: [128]u8 = undefined;
    while (out.items.len < target_bytes) {
        const id = r.intRangeAtMost(i64, -1_000_000, 1_000_000_000);
        const price = r.float(f64) * 10_000.0;
        const flag = r.boolean();
        const name = typed_names[r.uintLessThan(usize, typed_names.len)];
        const cat = typed_cats[r.uintLessThan(usize, typed_cats.len)];
        const row = try std.fmt.bufPrint(&line, "{d},{d:.2},{s},{s},{s}\n", .{
            id, price, if (flag) "true" else "false", name, cat,
        });
        try out.appendSlice(alloc, row);
    }
    return out.toOwnedSlice(alloc);
}

fn typed(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    if (rest.len == 0) {
        print("usage: bench gen typed <dir>\n", .{});
        return GenError.BadArgs;
    }
    const dir = rest[0];
    try ensureDir(init, dir);
    const bytes = try genTypedBytes(alloc);
    try writeCorpus(init, alloc, dir, "typed.csv", bytes);
    print("typed.csv: {d:.2} MiB (header: {s})\n", .{ mib(bytes.len), std.mem.trimEnd(u8, typed_header, "\n") });
}

// ---------------------------------------------------------------------------
// Randomized workloads + meta.json
// ---------------------------------------------------------------------------

const short_vocab = [_][]const u8{
    "alpha", "bravo", "charlie", "delta", "echo",  "golf",
    "hotel", "x",     "",        "n/a",   "true",  "false",
};
const styles = [_][]const u8{ "short", "numeric", "long", "mixed" };
const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

const Meta = struct {
    name: []const u8,
    cols: usize,
    style: []const u8,
    quote_pct: u8,
    escape_pct: u8,
    comma_pct: u8,
    MiB: f64,
};

fn random(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    if (rest.len == 0) {
        print("usage: bench gen random <dir> [N]\n", .{});
        return GenError.BadArgs;
    }
    const dir = rest[0];
    const n: usize = if (rest.len >= 2)
        std.fmt.parseInt(usize, rest[1], 10) catch {
            print("error: N must be a non-negative integer, got '{s}'\n", .{rest[1]});
            return GenError.BadArgs;
        }
    else
        4;
    try ensureDir(init, dir);

    var master = std.Random.DefaultPrng.init(0xF0_0D_CA_FE);
    const mr = master.random();
    var meta: std.ArrayList(Meta) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ncols = mr.intRangeAtMost(usize, 3, 22);
        const style = styles[mr.uintLessThan(usize, styles.len)];
        const qp = mr.intRangeAtMost(u8, 0, 70);
        const ep = mr.intRangeAtMost(u8, 0, 60);
        const cp = mr.intRangeAtMost(u8, 0, 60);
        const seed = mr.intRangeAtMost(u64, 1, 1 << 31);

        const bytes = try genRandom(alloc, ncols, style, qp, ep, cp, seed);
        const name = try std.fmt.allocPrint(alloc, "rand{d}.csv", .{i});
        try writeCorpus(init, alloc, dir, name, bytes);

        const m = mib(bytes.len);
        print("rand{d}: cols={d:>2} style={s:<7} quote={d:>2}% escape={d:>2}% comma={d:>2}%  {d:.2} MiB\n", .{ i, ncols, style, qp, ep, cp, m });
        try meta.append(alloc, .{
            .name = try std.fmt.allocPrint(alloc, "rand{d}", .{i}),
            .cols = ncols,
            .style = style,
            .quote_pct = qp,
            .escape_pct = ep,
            .comma_pct = cp,
            .MiB = @round(m * 100.0) / 100.0,
        });
    }

    // meta.json describing every workload.
    var aw = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(meta.items, .{ .whitespace = .indent_1 }, &aw.writer);
    try writeCorpus(init, alloc, dir, "meta.json", aw.written());
}

fn genRandom(alloc: Allocator, ncols: usize, style: []const u8, qp: u8, ep: u8, cp: u8, seed: u64) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const vocab = try makeVocab(alloc, style, r);
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(alloc, target_bytes + 4096);
    while (out.items.len < target_bytes) {
        var c: usize = 0;
        while (c < ncols) : (c += 1) {
            if (c != 0) try out.append(alloc, ',');
            const w = vocab[r.uintLessThan(usize, vocab.len)];
            if (r.uintLessThan(u8, 100) < qp) {
                try out.append(alloc, '"');
                try out.appendSlice(alloc, w);
                if (r.uintLessThan(u8, 100) < cp) try out.appendSlice(alloc, ",more");
                if (r.uintLessThan(u8, 100) < ep) try out.appendSlice(alloc, "\"\"q\"\"");
                try out.append(alloc, '"');
            } else {
                try out.appendSlice(alloc, w);
            }
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Vocabulary for a workload style. `short` returns the static list; the others draw
/// from the SAME per-workload PRNG that then generates rows (so the whole workload is
/// reproducible from its seed).
fn makeVocab(alloc: Allocator, style: []const u8, r: std.Random) ![]const []const u8 {
    if (eql(u8, style, "short")) return &short_vocab;

    var v: std.ArrayList([]const u8) = .empty;
    if (eql(u8, style, "numeric")) {
        var k: usize = 0;
        while (k < 40) : (k += 1) try v.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{r.intRangeAtMost(u64, 0, 1_000_000_000)}));
        k = 0;
        while (k < 40) : (k += 1) try v.append(alloc, try std.fmt.allocPrint(alloc, "{d:.4}", .{r.float(f64) * 1_000_000.0}));
        try v.append(alloc, "");
        try v.append(alloc, "0");
    } else if (eql(u8, style, "long")) {
        var k: usize = 0;
        while (k < 60) : (k += 1) try v.append(alloc, try randWord(alloc, r, r.intRangeAtMost(usize, 15, 45), true));
        try v.append(alloc, "");
    } else { // mixed
        try v.appendSlice(alloc, &short_vocab);
        var k: usize = 0;
        while (k < 20) : (k += 1) try v.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{r.intRangeAtMost(u64, 0, 1_000_000)}));
        k = 0;
        while (k < 20) : (k += 1) try v.append(alloc, try randWord(alloc, r, r.intRangeAtMost(usize, 8, 25), false));
    }
    return v.items;
}

fn randWord(alloc: Allocator, r: std.Random, len: usize, with_space: bool) ![]const u8 {
    const alphabet_len: usize = if (with_space) letters.len + 1 else letters.len;
    const s = try alloc.alloc(u8, len);
    for (s) |*ch| {
        const idx = r.uintLessThan(usize, alphabet_len);
        ch.* = if (idx == letters.len) ' ' else letters[idx];
    }
    return s;
}
