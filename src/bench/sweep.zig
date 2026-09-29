// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! bench/sweep.zig — where does the parallel path start to pay?
//!
//!   bench sweep [--rounds N] [--out PATH] <file.csv>
//!
//! Cuts record-aligned prefixes of the file at doubling sizes (32 KiB up to the whole
//! file) and, for each, races serial push against `parallel.forEachFieldExact` with
//! 2, 3, 4, 6, 8 and all-CPU workers, alternating within every round like `compare`.
//! Each worker count's output is checked against push first. Reported: the per-round
//! speed ratio vs push, median [min, max], and the bytes each worker got. The report
//! (every sample) is rewritten after every size. `parallel.min_bytes_per_worker` is
//! chosen from this: the smallest per-worker share at which `par` stops losing.

const std = @import("std");
const csv = @import("csv");
const verify = @import("verify.zig");

const Io = std.Io;
const print = std.debug.print;

fn nanoTime() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Sum = struct {
    sum: u64 align(std.atomic.cache_line) = 0,
    fn on(self: *Sum, bytes: []const u8, last: bool) void {
        self.sum +%= bytes.len + @intFromBool(last);
    }
};

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    var rounds: usize = 11;
    var out_path: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--rounds") or std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            if (std.mem.eql(u8, args[i - 1], "--rounds")) {
                rounds = try std.fmt.parseInt(usize, args[i], 10);
            } else out_path = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            print("error: unknown flag {s}\n", .{args[i]});
            return error.BadArgs;
        } else file = args[i];
    }
    const path = file orelse {
        print("usage: bench sweep [--rounds N] [--out PATH] <file.csv>\n", .{});
        return error.BadArgs;
    };
    const text = try Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    const cpus = @min(std.Thread.getCpuCount() catch 4, csv.parallel.max_workers);

    var ks: std.ArrayList(usize) = .empty;
    for ([_]usize{ 2, 3, 4, 6, 8 }) |k| if (k < cpus) try ks.append(alloc, k);
    try ks.append(alloc, cpus);

    const scratch = try alloc.alloc(u8, 1 << 16);
    const sinks = try alloc.alloc(Sum, cpus);
    const ptrs = try alloc.alloc(*Sum, cpus);
    const scratches = try alloc.alloc([]u8, cpus);
    for (sinks, ptrs, scratches) |*s, *p, *sc| {
        p.* = s;
        sc.* = try alloc.alloc(u8, 1 << 16);
    }

    print("parallel sweep: {s}, {d} rounds (+1 warm-up), {d} CPUs; ratio = push time / par time\n\n", .{ std.fs.path.basename(path), rounds, cpus });
    print("{s:>10}", .{"size"});
    for (ks.items) |k| print("   par{d:<2} med [min,max]  ", .{k});
    print("\n", .{});

    var report: std.ArrayList(u8) = .empty;
    try report.print(alloc, "{{\"file\":\"{s}\",\"cpus\":{d},\"rounds\":{d},\"sizes\":[", .{ std.fs.path.basename(path), cpus, rounds });
    var size: usize = 32 * 1024;
    var first = true;
    while (true) : (size *= 2) {
        const cut = if (size >= text.len) text.len else csv.parallel.recordStartAfter(text, size, csv.parallel.countQuotes(text[0..size], '"') % 2 == 1, .{});
        const part = text[0..cut];
        const want = verify.runPush(csv, part, scratch);
        if (want.err != null) return error.FileDoesNotParse;
        for (ks.items) |k| if (!verify.runPar(csv, io, part, k).eql(want)) {
            print("error: par with {d} workers disagrees with push at {d} bytes\n", .{ k, part.len });
            return error.ParallelMismatch;
        };

        // samples[0] = push, samples[1 + j] = par with ks[j] workers.
        const n = ks.items.len + 1;
        const samples = try alloc.alloc([]f64, n);
        for (samples) |*row| row.* = try alloc.alloc(f64, rounds);
        for (0..rounds + 1) |r| {
            for (0..n) |step| {
                const c = (step + r) % n;
                const t0 = nanoTime();
                if (c == 0) {
                    var s = Sum{};
                    try csv.simd.forEachField(part, scratch, .{}, &s, Sum.on);
                    std.mem.doNotOptimizeAway(s.sum);
                } else {
                    const k = ks.items[c - 1];
                    try csv.parallel.forEachFieldExact(io, part, .{}, scratches[0..k], ptrs[0..k], Sum.on);
                    std.mem.doNotOptimizeAway(sinks[0].sum);
                }
                if (r > 0) samples[c][r - 1] = @floatFromInt(nanoTime() - t0);
            }
        }

        if (!first) try report.append(alloc, ',');
        first = false;
        try report.print(alloc, "{{\"bytes\":{d},\"push_ns\":[", .{part.len});
        for (samples[0], 0..) |x, r| try report.print(alloc, "{s}{d:.0}", .{ if (r > 0) "," else "", x });
        try report.appendSlice(alloc, "],\"par\":[");
        print("{d:>9}K", .{part.len / 1024});
        for (ks.items, 1..) |k, c| {
            const ratio = try alloc.alloc(f64, rounds);
            for (ratio, samples[0], samples[c]) |*q, a, b| q.* = a / b;
            std.mem.sort(f64, ratio, {}, std.sort.asc(f64));
            const med = ratio[rounds / 2];
            print("   {d:>5.2} [{d:.2},{d:.2}]    ", .{ med, ratio[0], ratio[rounds - 1] });
            try report.print(alloc, "{s}{{\"workers\":{d},\"bytes_per_worker\":{d},\"ratio_median\":{d:.3},\"ratio_min\":{d:.3},\"ratio_max\":{d:.3},\"ns\":[", .{ if (c > 1) "," else "", k, part.len / k, med, ratio[0], ratio[rounds - 1] });
            for (samples[c], 0..) |x, r| try report.print(alloc, "{s}{d:.0}", .{ if (r > 0) "," else "", x });
            try report.appendSlice(alloc, "]}");
        }
        print("\n", .{});
        try report.appendSlice(alloc, "]}");
        if (out_path) |op| {
            try report.appendSlice(alloc, "]}");
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = report.items });
            report.shrinkRetainingCapacity(report.items.len - 2);
        }
        if (cut >= text.len) break;
    }
    if (out_path) |op| print("\n(report: {s})\n", .{op});
}
