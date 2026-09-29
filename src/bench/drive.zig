// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! bench/drive.zig — the benchfence UNITS drivers, in Zig.
//!
//! Replaces the former Nushell layer (bench.nu, matrix-bench.nu, bench/units.nu, and
//! the vs-csv-parsers drivers). Each `bench drive <name>` builds a `[{name, argv}]`
//! unit list and execs the vendored (Zig) benchfence binary, which owns the
//! gate→measure→retry loop. This module only DESCRIBES units — it applies no fence of
//! its own (benchfence pins the core, disables ASLR, and sets LC_ALL=C itself).
//!
//! Paths follow the repo convention: an env override wins, else the build-injected
//! default (see build.zig → the `build_paths` options module), else a LOUD error.
//! There are no fake absolute defaults; a missing external dependency (a comparison
//! binary or a corpus) fails loudly, never silently.
//!
//! The bench binary already prints `BENCHFENCE_METRIC=` for every single-shot mode
//! the units invoke (`bench <profile> <path>`, `bench x push|pull <file>`,
//! `bench cell <detect> <collapse> <file>`), so no measurement code lives here.

const std = @import("std");
const paths = @import("build_paths");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const print = std.debug.print;

const Unit = struct { name: []const u8, argv: []const []const u8 };

pub const DriveError = error{
    MissingDependency,
    NoUnits,
    UnitRunFailed,
    UnknownDriver,
    BadArgs,
};

/// Flags shared by every driver (benchfence's `run-units` surface). Per-driver
/// constructors set the sensible `reps` default the old Nushell drivers used.
const RunOptions = struct {
    reps: u32 = 15,
    metric: []const u8 = "MB/s",
    direction: []const u8 = "higher",
    bound: []const u8 = "mem", // zsift is memory-bound; gate on the mem referee
    wait: []const u8 = "normal",
    out: []const u8 = "", // empty → no results artifact
};

fn nanoTime() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// `args` is everything after `bench drive` (so `args[0]` is the driver name).
pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const alloc = init.arena.allocator(); // process-lifetime arena; freed on exit
    if (args.len == 0) {
        print("usage: bench drive <throughput|matrix|vs-rust|vs-all|vs-serde|random> [args]\n", .{});
        return DriveError.BadArgs;
    }
    const name = args[0];
    const rest = args[1..];
    if (eql(u8, name, "throughput")) return throughput(init, alloc, rest);
    if (eql(u8, name, "matrix")) return matrix(init, alloc, rest);
    if (eql(u8, name, "vs-rust")) return vsRust(init, alloc, rest);
    if (eql(u8, name, "vs-all")) return vsAll(init, alloc, rest);
    if (eql(u8, name, "vs-serde")) return vsSerde(init, alloc, rest);
    if (eql(u8, name, "random")) return random(init, alloc, rest);
    print("unknown driver '{s}' (throughput|matrix|vs-rust|vs-all|vs-serde|random)\n", .{name});
    return DriveError.UnknownDriver;
}

// ---------------------------------------------------------------------------
// Path resolution: env override → build-injected default → loud error
// ---------------------------------------------------------------------------

fn envOr(init: std.process.Init, name: []const u8, default: []const u8) []const u8 {
    return init.environ_map.get(name) orelse default;
}

fn fileExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn requireFile(io: Io, path: []const u8, what: []const u8, howto: []const u8) DriveError!void {
    if (!fileExists(io, path)) {
        print("error: {s} not found at:\n  {s}\n  {s}\n", .{ what, path, howto });
        return DriveError.MissingDependency;
    }
}

fn zsiftBin(init: std.process.Init) DriveError![]const u8 {
    const p = envOr(init, "ZSIFT_BENCH", paths.zsift_bench);
    try requireFile(init.io, p, "zsift bench binary", "build it: `zig build -Doptimize=ReleaseFast` (or set $ZSIFT_BENCH)");
    return p;
}

// ---------------------------------------------------------------------------
// Shared: serialize units, exec benchfence, write provenance
// ---------------------------------------------------------------------------

fn runUnits(init: std.process.Init, alloc: Allocator, units: []const Unit, opts: RunOptions) !void {
    const io = init.io;
    if (units.len == 0) {
        print("error: no units to run — nothing to measure (missing corpora? generate them first)\n", .{});
        return DriveError.NoUnits;
    }

    const bf = envOr(init, "BENCHFENCE", paths.benchfence);
    try requireFile(io, bf, "benchfence binary", "vendor bench/benchfence (a stripped benchfence release) or set $BENCHFENCE");

    // Ensure the results directory exists before benchfence's `--out` and our
    // provenance write (units.nu did `mkdir $dir`). Best-effort: a genuine failure
    // surfaces loudly at the write below.
    if (opts.out.len != 0) {
        // createDirPath is mkdir -p: it succeeds if the dir already exists and only
        // errors on a genuine failure (permissions), which we want surfaced.
        if (std.fs.path.dirname(opts.out)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    }

    // Serialize the unit list to JSON (benchfence's `--units` contract).
    var aw = std.Io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(units, .{}, &aw.writer);
    const units_json = aw.written();

    // Write it to a temp file; benchfence reads it by path.
    const uf = try std.fmt.allocPrint(alloc, "{s}/zsift-units-{d}.json", .{ envOr(init, "TMPDIR", "/tmp"), nanoTime() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = uf, .data = units_json });
    defer std.Io.Dir.cwd().deleteFile(io, uf) catch |e|
        print("note: could not remove temp units file {s}: {s}\n", .{ uf, @errorName(e) });

    // benchfence argv. benchfence applies the fence + owns the rep loop; we only pass config.
    const reps_s = try std.fmt.allocPrint(alloc, "{d}", .{opts.reps});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{
        bf,          "--units",     uf,             "--bound", opts.bound,
        "--wait",    opts.wait,     "--reps",       reps_s,    "--metric",
        opts.metric, "--direction", opts.direction,
    });
    if (opts.out.len != 0) try argv.appendSlice(alloc, &.{ "--out", opts.out });

    // Inherit stdio (benchfence's gated table flows to the terminal) and the parent
    // environment (PATH for its referee tools, XDG for its state file).
    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return DriveError.UnitRunFailed,
        else => return DriveError.UnitRunFailed,
    }

    // Provenance — only after a successful run: the exact unit list beside the results,
    // version-controlling which tests produced them (mirrors units.nu's .units.json).
    if (opts.out.len != 0) {
        const stem = if (std.mem.endsWith(u8, opts.out, ".json")) opts.out[0 .. opts.out.len - 5] else opts.out;
        const prov = try std.fmt.allocPrint(alloc, "{s}.units.json", .{stem});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = prov, .data = units_json });
    }
}

fn mkUnit(alloc: Allocator, name: []const u8, argv: []const []const u8) !Unit {
    return .{ .name = name, .argv = try alloc.dupe([]const u8, argv) };
}

// ---------------------------------------------------------------------------
// Flag parsing (shared): --reps N, --wait W, --out PATH; the rest are positionals
// ---------------------------------------------------------------------------

fn parseFlags(alloc: Allocator, rest: []const []const u8, opts: *RunOptions, positionals: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eql(u8, a, "--reps") or eql(u8, a, "--wait") or eql(u8, a, "--out")) {
            if (i + 1 >= rest.len) {
                print("error: {s} needs a value\n", .{a});
                return DriveError.BadArgs;
            }
            i += 1;
            if (eql(u8, a, "--reps")) {
                opts.reps = std.fmt.parseInt(u32, rest[i], 10) catch {
                    print("error: --reps must be a non-negative integer, got '{s}'\n", .{rest[i]});
                    return DriveError.BadArgs;
                };
            } else if (eql(u8, a, "--wait")) {
                opts.wait = rest[i];
            } else {
                opts.out = rest[i];
            }
        } else {
            try positionals.append(alloc, a);
        }
    }
}

// ---------------------------------------------------------------------------
// Drivers
// ---------------------------------------------------------------------------

/// Throughput: every profile × every parser path is one single-shot measurement over
/// the bench binary's own synthetic corpus (no corpus files). Replaces bench.nu.
fn throughput(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    var opts = RunOptions{ .reps = 20 };
    var pos: std.ArrayList([]const u8) = .empty;
    try parseFlags(alloc, rest, &opts, &pos);

    const zsift = try zsiftBin(init);
    const profs = [_][]const u8{ "clean", "quoted", "escapey" };
    const pths = [_][]const u8{ "scalar", "pull", "push", "stream" };

    var units: std.ArrayList(Unit) = .empty;
    for (profs) |p| {
        for (pths) |path| {
            const name = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ p, path });
            try units.append(alloc, try mkUnit(alloc, name, &.{ zsift, p, path }));
        }
    }
    try runUnits(init, alloc, units.items, opts);
}

/// DETECT × COLLAPSE method matrix over one corpus CSV. Replaces matrix-bench.nu.
/// Usage: `bench drive matrix <corpus.csv> [--reps N] [--wait W]`.
fn matrix(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    var opts = RunOptions{ .reps = 10 };
    var pos: std.ArrayList([]const u8) = .empty;
    try parseFlags(alloc, rest, &opts, &pos);
    if (pos.items.len == 0) {
        print("usage: bench drive matrix <corpus.csv> [--reps N] [--wait W]\n", .{});
        return DriveError.BadArgs;
    }
    const corpus = pos.items[0];
    try requireFile(init.io, corpus, "corpus", "pass a real CSV path, or generate one with `zig build gen-structured`");
    const zsift = try zsiftBin(init);

    // The informative cells: baseline, each fix alone, both, a swar variant, swar-detect.
    const cells = [_][2][]const u8{
        .{ "rescan", "byteloop" }, .{ "accum", "byteloop" },
        .{ "rescan", "memcpy" },   .{ "accum", "memcpy" },
        .{ "rescan", "swarcpy" },  .{ "accum", "swarcpy" },
        .{ "swar", "swarcpy" },
    };
    var units: std.ArrayList(Unit) = .empty;
    for (cells) |c| {
        const name = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ c[0], c[1] });
        try units.append(alloc, try mkUnit(alloc, name, &.{ zsift, "cell", c[0], c[1], corpus }));
    }
    try runUnits(init, alloc, units.items, opts);
}

/// zsift vs rust-csv over the structured corpora (clean/quoted/escapey). Replaces
/// driver.nu. Default results artifact: <corpus_dir>/../results/structured.json.
fn vsRust(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    var opts = RunOptions{ .reps = 15 };
    var pos: std.ArrayList([]const u8) = .empty;
    try parseFlags(alloc, rest, &opts, &pos);

    const zsift = try zsiftBin(init);
    const rust = try rustBin(init);
    const cdir = envOr(init, "ZSIFT_CORPUS_DIR", paths.corpus_dir);
    if (opts.out.len == 0) opts.out = paths.results_structured;

    var units: std.ArrayList(Unit) = .empty;
    for ([_][]const u8{ "clean", "quoted", "escapey" }) |c| {
        const f = try std.fmt.allocPrint(alloc, "{s}/{s}.csv", .{ cdir, c });
        try requireFile(init.io, f, "structured corpus", "generate it: `zig build gen-structured`");
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "zsift/push/{s}", .{c}), &.{ zsift, "x", "push", f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "zsift/pull/{s}", .{c}), &.{ zsift, "x", "pull", f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "rust/byterecord/{s}", .{c}), &.{ rust, "byterecord", f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "rust/core/{s}", .{c}), &.{ rust, "core", f }));
    }
    try runUnits(init, alloc, units.items, opts);
}

/// The honest end-to-end typed comparison: zsift `reader(TypedRow)` vs rust-csv's serde
/// `deserialize::<Row>()`, both parsing the same header'd `typed.csv` INTO a struct (the
/// apples-to-apples task the untyped byterecord/core modes don't measure). Replaces
/// nothing — this is a new comparison. Default artifact: <corpus_dir>/../results/typed.json.
fn vsSerde(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    var opts = RunOptions{ .reps = 12 };
    var pos: std.ArrayList([]const u8) = .empty;
    try parseFlags(alloc, rest, &opts, &pos);

    const zsift = try zsiftBin(init);
    const rust = try rustBin(init);
    const cdir = envOr(init, "ZSIFT_CORPUS_DIR", paths.corpus_dir);
    if (opts.out.len == 0) opts.out = paths.results_typed;

    const f = try std.fmt.allocPrint(alloc, "{s}/typed.csv", .{cdir});
    try requireFile(init.io, f, "typed corpus", "generate it: `zig build gen-typed -- <corpus_dir>`");

    var units: std.ArrayList(Unit) = .empty;
    // `x` is a throwaway profile name; argv form is `bench <profile> typed <corpus>`.
    try units.append(alloc, try mkUnit(alloc, "zsift/typed", &.{ zsift, "x", "typed", f }));
    try units.append(alloc, try mkUnit(alloc, "rust/serde", &.{ rust, "serde", f }));
    try runUnits(init, alloc, units.items, opts);
}

const Job = struct { c: []const u8, f: []const u8 };

/// zsift vs zsv vs rust byterecord over structured + randomized corpora. Replaces
/// driver-all.nu. Missing corpora are skipped LOUDLY (not silently); if nothing is
/// runnable it fails loud.
fn vsAll(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    var opts = RunOptions{ .reps = 12 };
    var pos: std.ArrayList([]const u8) = .empty;
    try parseFlags(alloc, rest, &opts, &pos);

    const cdir = envOr(init, "ZSIFT_CORPUS_DIR", paths.corpus_dir);
    const rdir = envOr(init, "ZSIFT_RCORPUS_DIR", paths.rcorpus_dir);
    if (opts.out.len == 0) opts.out = paths.results_comparison;

    var jobs: std.ArrayList(Job) = .empty;
    for ([_][]const u8{ "clean", "quoted", "escapey" }) |c|
        try jobs.append(alloc, .{ .c = c, .f = try std.fmt.allocPrint(alloc, "{s}/{s}.csv", .{ cdir, c }) });
    for ([_][]const u8{ "rand0", "rand1", "rand2", "rand3" }) |c|
        try jobs.append(alloc, .{ .c = c, .f = try std.fmt.allocPrint(alloc, "{s}/{s}.csv", .{ rdir, c }) });

    var present: std.ArrayList(Job) = .empty;
    var absent: std.ArrayList([]const u8) = .empty;
    for (jobs.items) |j| {
        if (fileExists(init.io, j.f)) try present.append(alloc, j) else try absent.append(alloc, j.c);
    }
    if (absent.items.len != 0) {
        print("note: skipping {d} missing corpora: ", .{absent.items.len});
        for (absent.items, 0..) |c, i| print("{s}{s}", .{ if (i == 0) "" else ", ", c });
        print("\n  (generate them: `zig build gen-structured` / `zig build gen-random`)\n", .{});
    }
    if (present.items.len == 0) {
        print("error: no corpora found — generate them first (`zig build gen-structured` / `zig build gen-random`)\n", .{});
        return DriveError.NoUnits;
    }

    const zsift = try zsiftBin(init);
    const rust = try rustBin(init);
    const zsv = try zsvBin(init);

    var units: std.ArrayList(Unit) = .empty;
    for (present.items) |j| {
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "zsift/push/{s}", .{j.c}), &.{ zsift, "x", "push", j.f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "zsift/pull/{s}", .{j.c}), &.{ zsift, "x", "pull", j.f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "zsv/{s}", .{j.c}), &.{ zsv, j.f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "rust/byte/{s}", .{j.c}), &.{ rust, "byterecord", j.f }));
    }
    try runUnits(init, alloc, units.items, opts);
}

/// zsift vs rust-csv over every *.csv in the randomized corpus dir. Replaces rdriver.nu.
fn random(init: std.process.Init, alloc: Allocator, rest: []const []const u8) !void {
    var opts = RunOptions{ .reps = 12 };
    var pos: std.ArrayList([]const u8) = .empty;
    try parseFlags(alloc, rest, &opts, &pos);

    const zsift = try zsiftBin(init);
    const rust = try rustBin(init);
    const rdir = envOr(init, "ZSIFT_RCORPUS_DIR", paths.rcorpus_dir);
    if (opts.out.len == 0) opts.out = paths.results_random;

    // Discover every rand*.csv (basename without extension), sorted for stable output.
    var dir = std.Io.Dir.cwd().openDir(init.io, rdir, .{ .iterate = true }) catch {
        print("error: randomized corpus dir not found at:\n  {s}\n  generate it: `zig build gen-random`\n", .{rdir});
        return DriveError.MissingDependency;
    };
    defer dir.close(init.io);
    var stems: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(init.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".csv"))
            try stems.append(alloc, try alloc.dupe(u8, entry.name[0 .. entry.name.len - 4]));
    }
    std.mem.sort([]const u8, stems.items, {}, lessThanStr);

    var units: std.ArrayList(Unit) = .empty;
    for (stems.items) |c| {
        const f = try std.fmt.allocPrint(alloc, "{s}/{s}.csv", .{ rdir, c });
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "zsift/push/{s}", .{c}), &.{ zsift, "x", "push", f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "zsift/pull/{s}", .{c}), &.{ zsift, "x", "pull", f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "rust/byterecord/{s}", .{c}), &.{ rust, "byterecord", f }));
        try units.append(alloc, try mkUnit(alloc, try std.fmt.allocPrint(alloc, "rust/core/{s}", .{c}), &.{ rust, "core", f }));
    }
    try runUnits(init, alloc, units.items, opts);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// External comparison baselines: an env var wins, else the conventional build-output
// location; a missing binary fails loud (with how to build it).
fn rustBin(init: std.process.Init) DriveError![]const u8 {
    const p = envOr(init, "RUSTCSV_BENCH", paths.rust_bench);
    try requireFile(init.io, p, "rust-csv bench binary", "build it: `cd bench/vs-csv-parsers/rustcsv && cargo build --release` (or set $RUSTCSV_BENCH)");
    return p;
}

fn zsvBin(init: std.process.Init) DriveError![]const u8 {
    const p = envOr(init, "ZSVBENCH", paths.zsv_bench);
    try requireFile(init.io, p, "zsv bench binary", "build it per bench/vs-csv-parsers/BUILD-zsv.md (or set $ZSVBENCH)");
    return p;
}
