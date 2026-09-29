// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! bench/verify.zig — differential check: every parser path over the same bytes.
//!
//!   bench verify [--out PATH] [file-or-dir ...]
//!
//! Each file goes through scalar `Parser` (the oracle), `SimdParser` (pull),
//! `forEachField` (push) and `streamReader` (64 KiB window). A path's outcome is its
//! field sequence digest or the name of the error it returned. A file PASSES when its
//! expectation holds: `agree` (all four outcomes identical) unless an EXPECT.tsv beside it
//! says `strict_error` (pull, push and stream each return an error). With no paths,
//! `$ZSIFT_TESTDATA` is used; if that is unset too, it says SKIPPED and checks nothing.
//! The report is rewritten after every file, so an interrupted run keeps its results.
//! Exit status: 0 all pass (or skipped), 1 any FAIL.

const std = @import("std");
const csv = @import("csv");
const cases = @import("cases.zig");
const MemReader = @import("memreader.zig").MemReader;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const print = std.debug.print;

const window_len = 64 * 1024;

pub const Outcome = struct {
    digest: u64 = 0,
    fields: u64 = 0,
    records: u64 = 0,
    err: ?[]const u8 = null,

    pub fn eql(a: Outcome, b: Outcome) bool {
        if (a.err != null or b.err != null) {
            return a.err != null and b.err != null and std.mem.eql(u8, a.err.?, b.err.?);
        }
        return a.digest == b.digest and a.fields == b.fields and a.records == b.records;
    }
};

/// Field-sequence digest: length-prefixed bytes plus the record-end flag, so no field
/// content can impersonate a separator.
const Digest = struct {
    h: std.hash.Wyhash = .init(0),
    fields: u64 = 0,
    records: u64 = 0,

    fn on(self: *Digest, bytes: []const u8, last: bool) void {
        const len: u64 = bytes.len;
        self.h.update(std.mem.asBytes(&len));
        self.h.update(bytes);
        self.h.update(if (last) "\x01" else "\x00");
        self.fields += 1;
        if (last) self.records += 1;
    }

    fn done(self: *Digest) Outcome {
        return .{ .digest = self.h.final(), .fields = self.fields, .records = self.records };
    }
};

pub const Path = enum { scalar, pull, push, stream };
const path_names = [_][]const u8{ "scalar", "pull", "push", "stream" };

fn runPull(comptime P: type, text: []const u8, scratch: []u8) Outcome {
    var d = Digest{};
    var p = P.init(text, scratch, .{}) catch |e| return .{ .err = @errorName(e) };
    while (p.next() catch |e| return .{ .err = @errorName(e) }) |f| {
        d.on(f.bytes, f.last_in_record);
        p.resetScratch();
    }
    return d.done();
}

fn runPush(text: []const u8, scratch: []u8) Outcome {
    var d = Digest{};
    csv.simd.forEachField(text, scratch, .{}, &d, Digest.on) catch |e| return .{ .err = @errorName(e) };
    return d.done();
}

fn runStream(text: []const u8, window: []u8, scratch: []u8) Outcome {
    var d = Digest{};
    var mr = MemReader.init(window, text);
    csv.streamReader(&mr.interface, scratch, .{}, &d, Digest.on) catch |e| return .{ .err = @errorName(e) };
    return d.done();
}

/// One path's outcome over `text`, with buffers of its own (for `bench compare`).
/// Single-threaded use only: the buffers are static.
pub fn outcome(p: Path, text: []const u8) Outcome {
    const B = struct {
        var scratch: [1 << 20]u8 = undefined;
        var window: [window_len]u8 = undefined;
        var stream_scratch: [window_len]u8 = undefined;
    };
    return switch (p) {
        .scalar => runPull(csv.Parser, text, &B.scratch),
        .pull => runPull(csv.SimdParser, text, &B.scratch),
        .push => runPush(text, &B.scratch),
        .stream => runStream(text, &B.window, &B.stream_scratch),
    };
}

pub const Verdict = struct { pass: bool, why: []const u8 };

fn judge(expect: cases.Expect, o: [4]Outcome) Verdict {
    switch (expect) {
        .agree => {
            for (o[1..], 1..) |x, i| if (!x.eql(o[0])) return .{ .pass = false, .why = path_names[i] };
            return .{ .pass = true, .why = "" };
        },
        .strict_error => {
            for (o[1..], 1..) |x, i| if (x.err == null) return .{ .pass = false, .why = path_names[i] };
            return .{ .pass = true, .why = "" };
        },
    }
}

/// Every `.csv` under `root` (a file is returned as itself), sorted, as absolute-or-given paths.
pub fn listCsv(io: Io, alloc: Allocator, root: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => {
            try out.append(alloc, root);
            return out.toOwnedSlice(alloc);
        },
        else => return e,
    };
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".csv")) continue;
        try out.append(alloc, try std.fs.path.join(alloc, &.{ root, entry.path }));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(alloc);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Expectation for `file` from an EXPECT.tsv (`name<TAB>agree|strict_error`) in its
/// directory, keyed by basename without `.csv`. No manifest or no row → `agree`.
fn expectFor(io: Io, alloc: Allocator, file: []const u8) !cases.Expect {
    const dir = std.fs.path.dirname(file) orelse ".";
    const manifest = try std.fs.path.join(alloc, &.{ dir, "EXPECT.tsv" });
    const text = Io.Dir.cwd().readFileAlloc(io, manifest, alloc, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .agree,
        else => return e,
    };
    const base = std.fs.path.basename(file);
    const stem = if (std.mem.endsWith(u8, base, ".csv")) base[0 .. base.len - 4] else base;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse continue;
        const val = cols.next() orelse continue;
        if (!std.mem.eql(u8, name, stem)) continue;
        return std.meta.stringToEnum(cases.Expect, val) orelse {
            print("error: {s}: unknown expectation '{s}' for {s}\n", .{ manifest, val, name });
            return error.BadManifest;
        };
    }
    return .agree;
}

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    var out_path: ?[]const u8 = null;
    var roots: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            if (i >= args.len) {
                print("error: --out needs a path\n", .{});
                return error.BadArgs;
            }
            out_path = args[i];
        } else try roots.append(alloc, args[i]);
    }
    if (roots.items.len == 0) {
        const td = init.environ_map.get("ZSIFT_TESTDATA") orelse {
            print("SKIPPED: no paths given and $ZSIFT_TESTDATA is unset — nothing was verified.\n", .{});
            return;
        };
        try roots.append(alloc, td);
        // Results about private data stay beside it, never in the repo.
        if (out_path == null) out_path = try std.fs.path.join(alloc, &.{ td, "results", "verify.json" });
    }
    if (out_path) |p| if (std.fs.path.dirname(p)) |d| try Io.Dir.cwd().createDirPath(io, d);

    const scratch = try alloc.alloc(u8, 1 << 20);
    const window = try alloc.alloc(u8, window_len);
    const stream_scratch = try alloc.alloc(u8, window_len);

    var report: std.ArrayList(u8) = .empty;
    try report.appendSlice(alloc, "{\"files\":[");
    var n_files: usize = 0;
    var n_fail: usize = 0;

    for (roots.items) |root| {
        for (try listCsv(io, alloc, root)) |file| {
            const text = try Io.Dir.cwd().readFileAlloc(io, file, alloc, .unlimited);
            const expect = try expectFor(io, alloc, file);
            const o = [4]Outcome{
                runPull(csv.Parser, text, scratch),
                runPull(csv.SimdParser, text, scratch),
                runPush(text, scratch),
                runStream(text, window, stream_scratch),
            };
            const v = judge(expect, o);
            if (!v.pass) n_fail += 1;
            print("{s:<5} {s:<12} {s}", .{ if (v.pass) "PASS" else "FAIL", @tagName(expect), file });
            if (!v.pass) print("   ({s} differs)", .{v.why});
            print("\n", .{});
            if (!v.pass) for (o, path_names) |x, name| {
                if (x.err) |e| print("        {s:<7} error {s}\n", .{ name, e }) else print("        {s:<7} {d} records, {d} fields, digest {x:0>16}\n", .{ name, x.records, x.fields, x.digest });
            };

            if (n_files > 0) try report.append(alloc, ',');
            try report.print(alloc, "{{\"file\":\"{s}\",\"bytes\":{d},\"expect\":\"{s}\",\"pass\":{},\"paths\":{{", .{ file, text.len, @tagName(expect), v.pass });
            for (o, path_names, 0..) |x, name, k| {
                if (k > 0) try report.append(alloc, ',');
                if (x.err) |e| {
                    try report.print(alloc, "\"{s}\":{{\"error\":\"{s}\"}}", .{ name, e });
                } else try report.print(alloc, "\"{s}\":{{\"records\":{d},\"fields\":{d},\"digest\":\"{x:0>16}\"}}", .{ name, x.records, x.fields, x.digest });
            }
            try report.appendSlice(alloc, "}}");
            n_files += 1;
            if (out_path) |p| {
                try report.appendSlice(alloc, "]}");
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = report.items });
                report.shrinkRetainingCapacity(report.items.len - 2);
            }
        }
    }
    print("\n{d} files, {d} pass, {d} FAIL", .{ n_files, n_files - n_fail, n_fail });
    if (out_path) |p| print("  (report: {s})", .{p});
    print("\n", .{});
    if (n_fail > 0) std.process.exit(1);
}
