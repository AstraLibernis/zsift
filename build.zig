// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module for dependents: `@import("zsift")`.
    _ = b.addModule("zsift", .{
        .root_source_file = b.path("src/csv.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The parser library module used by this package's own tests and benchmark.
    const csv_mod = b.createModule(.{
        .root_source_file = b.path("src/csv.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test` — run unit tests.
    const tests = b.addTest(.{ .root_module = csv_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build bench` — run the throughput benchmark.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("csv", csv_mod);

    // `-Dbaseline=<path/to/other/zsift/src/csv.zig>`: a second zsift (e.g. a checkout of
    // an older tag) compiled into the same bench binary, so `compare` can alternate
    // `push` with `push@base` in one process. Without it, `@base` paths are refused.
    const baseline = b.option([]const u8, "baseline", "Another zsift's src/csv.zig to A/B against (`compare --paths push,push@base`)");
    const base_mod = if (baseline) |path| b.createModule(.{
        .root_source_file = .{ .cwd_relative = path },
        .target = target,
        .optimize = optimize,
    }) else csv_mod;
    bench_mod.addImport("csv_base", base_mod);
    const bench_opts = b.addOptions();
    bench_opts.addOption(?[]const u8, "baseline", baseline);
    bench_mod.addOptions("bench_options", bench_opts);

    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the throughput benchmark (human table)");
    bench_step.dependOn(&run_bench.step);

    // `zig build experiment` — the reproducible method-selection suite (see
    // EXPERIMENTS.md). Self-contained: generates its own corpora.
    const run_exp = b.addRunArtifact(bench);
    run_exp.addArg("experiment");
    const exp_step = b.step("experiment", "Run the method-selection experiment (why zsift chose its methods)");
    exp_step.dependOn(&run_exp.step);

    // Corpus generators (replace the former Python gen.py / genrand.py).
    addGenStep(b, bench, "structured", "gen-structured", "Generate the structured corpora: `zig build gen-structured -- <dir>`");
    addGenStep(b, bench, "random", "gen-random", "Generate randomized corpora + meta.json: `zig build gen-random -- <dir> [N]`");
    addGenStep(b, bench, "typed", "gen-typed", "Generate the typed corpus (header'd typed.csv): `zig build gen-typed -- <dir>`");
    addGenStep(b, bench, "adversarial", "gen-adversarial", "Generate the adversarial corpus + EXPECT.tsv: `zig build gen-adversarial -- <dir>`");

    // `zig build verify -- [paths]` — every parser path over the same bytes, judged
    // against the scalar oracle (default: $ZSIFT_TESTDATA; unset → SKIPPED).
    const run_verify = b.addRunArtifact(bench);
    run_verify.addArg("verify");
    if (b.args) |args| run_verify.addArgs(args);
    b.step("verify", "Differential check of every parser path: `zig build verify -- [files/dirs]`").dependOn(&run_verify.step);

    // `zig build compare -- [--rounds N] [--paths ..] [files]` — alternating comparison
    // of the parser paths (replaced the retired benchfence drivers). Build with
    // -Doptimize=ReleaseFast for meaningful numbers.
    const run_compare = b.addRunArtifact(bench);
    run_compare.addArg("compare");
    if (b.args) |args| run_compare.addArgs(args);
    b.step("compare", "Alternating comparison of parser paths: `zig build compare -Doptimize=ReleaseFast -- [files/dirs]`").dependOn(&run_compare.step);
}

/// A `bench gen <kind>` step. Forwards `-- <args>` (e.g. the output dir). Generators
/// are self-contained (they only write files), so no install dependency is needed.
fn addGenStep(b: *std.Build, bench: *std.Build.Step.Compile, kind: []const u8, step_name: []const u8, desc: []const u8) void {
    const run = b.addRunArtifact(bench);
    run.addArgs(&.{ "gen", kind });
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, desc).dependOn(&run.step);
}
