// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! bench/compare.zig — alternating comparison of parser paths (replaces benchfence).
//!
//!   bench compare [--rounds N] [--paths scalar,pull,push,stream] [--out PATH] [files/dirs]
//!
//! Each round times ONE full pass of every path over the file, in an order rotated per
//! round, so all contenders share whatever noise the machine has at that moment. The
//! paths' outputs are checked identical (bench verify's digests) before anything is
//! timed. Reported per path: median MB/s with min–max; and the per-round speed ratio
//! against the first path: median [min, max]. Ratios are the result; absolute MB/s are
//! machine- and moment-specific. With no files, `$ZSIFT_TESTDATA` is used (report
//! defaults beside it); unset → SKIPPED. The report is rewritten after every file.

const std = @import("std");
const csv = @import("csv");
const verify = @import("verify.zig");
const MemReader = @import("memreader.zig").MemReader;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const print = std.debug.print;

const Path = verify.Path;

const window_len = 64 * 1024;

fn nanoTime() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Sum = struct {
    sum: u64 = 0,
    fn on(self: *Sum, bytes: []const u8, last: bool) void {
        self.sum +%= bytes.len + @intFromBool(last);
    }
};

const Bufs = struct { scratch: []u8, window: []u8, stream_scratch: []u8 };

/// One full pass of `path` over `text`; returns a checksum so the work cannot be elided.
fn pass(path: Path, text: []const u8, b: Bufs) !u64 {
    var s = Sum{};
    switch (path) {
        inline .scalar, .pull => |p| {
            const P = if (p == .scalar) csv.Parser else csv.SimdParser;
            var it = try P.init(text, b.scratch, .{});
            while (try it.next()) |f| {
                s.on(f.bytes, f.last_in_record);
                it.resetScratch();
            }
        },
        .push => try csv.simd.forEachField(text, b.scratch, .{}, &s, Sum.on),
        .stream => {
            var mr = MemReader.init(b.window, text);
            try csv.streamReader(&mr.interface, b.stream_scratch, .{}, &s, Sum.on);
        },
    }
    return s.sum;
}

const Stat = struct { median: f64, min: f64, max: f64 };

fn stat(alloc: Allocator, xs: []const f64) !Stat {
    const v = try alloc.dupe(f64, xs);
    std.mem.sort(f64, v, {}, std.sort.asc(f64));
    return .{ .median = v[v.len / 2], .min = v[0], .max = v[v.len - 1] };
}

fn parsePaths(alloc: Allocator, spec: []const u8) ![]Path {
    var out: std.ArrayList(Path) = .empty;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |name| {
        const p = std.meta.stringToEnum(Path, name) orelse {
            print("error: unknown path '{s}' (scalar|pull|push|stream)\n", .{name});
            return error.BadArgs;
        };
        try out.append(alloc, p);
    }
    if (out.items.len == 0) return error.BadArgs;
    return out.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    var rounds: usize = 15;
    var paths: []const Path = &.{ .scalar, .pull, .push, .stream };
    var out_path: ?[]const u8 = null;
    var roots: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--rounds") or std.mem.eql(u8, a, "--paths") or std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) {
                print("error: {s} needs a value\n", .{a});
                return error.BadArgs;
            }
            if (std.mem.eql(u8, a, "--rounds")) {
                rounds = std.fmt.parseInt(usize, args[i], 10) catch {
                    print("error: --rounds must be a positive integer, got '{s}'\n", .{args[i]});
                    return error.BadArgs;
                };
                if (rounds == 0) return error.BadArgs;
            } else if (std.mem.eql(u8, a, "--paths")) {
                paths = try parsePaths(alloc, args[i]);
            } else out_path = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            print("error: unknown flag {s}\n", .{a});
            return error.BadArgs;
        } else try roots.append(alloc, a);
    }
    if (roots.items.len == 0) {
        const td = init.environ_map.get("ZSIFT_TESTDATA") orelse {
            print("SKIPPED: no files given and $ZSIFT_TESTDATA is unset — nothing was compared.\n", .{});
            return;
        };
        try roots.append(alloc, td);
        if (out_path == null) out_path = try std.fs.path.join(alloc, &.{ td, "results", "compare.json" });
    }
    if (out_path) |p| if (std.fs.path.dirname(p)) |d| try Io.Dir.cwd().createDirPath(io, d);

    const bufs = Bufs{
        .scratch = try alloc.alloc(u8, 1 << 20),
        .window = try alloc.alloc(u8, window_len),
        .stream_scratch = try alloc.alloc(u8, window_len),
    };
    const n = paths.len;
    const cpus = std.Thread.getCpuCount() catch 0;
    print("alternating comparison: {d} rounds (+1 warm-up), {d} logical CPUs, not fenced — read the ratios\n\n", .{ rounds, cpus });

    var report: std.ArrayList(u8) = .empty;
    try report.print(alloc, "{{\"rounds\":{d},\"cpus\":{d},\"files\":[", .{ rounds, cpus });
    var n_files: usize = 0;
    var n_skipped: usize = 0;

    for (roots.items) |root| {
        for (try verify.listCsv(io, alloc, root)) |file| {
            const text = try Io.Dir.cwd().readFileAlloc(io, file, alloc, .unlimited);

            // Identical output first, or the timings compare different work.
            const ref = verify.outcome(paths[0], text);
            var agree = ref.err == null;
            for (paths[1..]) |p| agree = agree and verify.outcome(p, text).eql(ref);
            if (!agree) {
                print("SKIP  {s}: paths disagree or error — run `bench verify` on it\n", .{file});
                n_skipped += 1;
                continue;
            }

            const ns = try alloc.alloc([]f64, n);
            for (ns) |*row| row.* = try alloc.alloc(f64, rounds);
            for (0..rounds + 1) |r| {
                for (0..n) |k| {
                    const j = (k + r) % n; // rotate who goes first
                    const t0 = nanoTime();
                    std.mem.doNotOptimizeAway(try pass(paths[j], text, bufs));
                    const dt = nanoTime() - t0;
                    if (r > 0) ns[j][r - 1] = @floatFromInt(dt);
                }
            }

            const mb = @as(f64, @floatFromInt(text.len)) / 1e6;
            print("{s}  ({d:.1} MB)\n", .{ file, mb });
            print("  {s:<8} {s:>10} {s:>21} {s:>28}\n", .{ "path", "MB/s med", "MB/s min–max", "vs first: median [min, max]" });
            if (n_files > 0) try report.append(alloc, ',');
            try report.print(alloc, "{{\"file\":\"{s}\",\"bytes\":{d},\"first\":\"{s}\",\"paths\":{{", .{ file, text.len, @tagName(paths[0]) });
            for (paths, 0..) |p, j| {
                const mbs = try alloc.alloc(f64, rounds);
                const ratio = try alloc.alloc(f64, rounds);
                for (0..rounds) |r| {
                    mbs[r] = mb / (ns[j][r] / 1e9);
                    ratio[r] = ns[0][r] / ns[j][r];
                }
                const m = try stat(alloc, mbs);
                const q = try stat(alloc, ratio);
                print("  {s:<8} {d:>10.0} {d:>10.0}–{d:<10.0} {d:>10.2}x [{d:.2}, {d:.2}]\n", .{ @tagName(p), m.median, m.min, m.max, q.median, q.min, q.max });
                if (j > 0) try report.append(alloc, ',');
                try report.print(alloc, "\"{s}\":{{\"mbs_median\":{d:.1},\"mbs_min\":{d:.1},\"mbs_max\":{d:.1},\"ratio_median\":{d:.3},\"ratio_min\":{d:.3},\"ratio_max\":{d:.3},\"samples_ns\":[", .{ @tagName(p), m.median, m.min, m.max, q.median, q.min, q.max });
                for (ns[j], 0..) |x, r| {
                    if (r > 0) try report.append(alloc, ',');
                    try report.print(alloc, "{d:.0}", .{x});
                }
                try report.appendSlice(alloc, "]}");
            }
            try report.appendSlice(alloc, "}}");
            n_files += 1;
            if (out_path) |op| {
                try report.appendSlice(alloc, "]}");
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = report.items });
                report.shrinkRetainingCapacity(report.items.len - 2);
            }
        }
    }
    print("\n{d} files compared, {d} skipped", .{ n_files, n_skipped });
    if (out_path) |p| print("  (report: {s})", .{p});
    print("\n", .{});
    if (n_skipped > 0) std.process.exit(1);
}
