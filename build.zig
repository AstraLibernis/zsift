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

    // The single "vars" source for the benchmark tooling's default paths, injected at
    // build time from the repo root (self-locating). Every path the `bench drive`
    // subcommands resolve is `$ENV override → this default → loud error`; there are no
    // hand-written absolute paths and no fake defaults. See src/bench/drive.zig.
    const build_paths = b.addOptions();
    build_paths.addOption([]const u8, "zsift_bench", b.pathFromRoot("zig-out/bin/bench"));
    build_paths.addOption([]const u8, "benchfence", b.pathFromRoot("bench/benchfence"));
    build_paths.addOption([]const u8, "corpus_dir", b.pathFromRoot("bench/vs-csv-parsers/corpus"));
    build_paths.addOption([]const u8, "rcorpus_dir", b.pathFromRoot("bench/vs-csv-parsers/rcorpus"));
    build_paths.addOption([]const u8, "rust_bench", b.pathFromRoot("bench/vs-csv-parsers/rustcsv/target/release/rustcsv-bench"));
    build_paths.addOption([]const u8, "zsv_bench", b.pathFromRoot("bench/vs-csv-parsers/zsvbench"));
    build_paths.addOption([]const u8, "results_structured", b.pathFromRoot("bench/vs-csv-parsers/results/structured.json"));
    build_paths.addOption([]const u8, "results_comparison", b.pathFromRoot("bench/vs-csv-parsers/results/comparison-zsift-zsv-rust.json"));
    build_paths.addOption([]const u8, "results_random", b.pathFromRoot("bench/vs-csv-parsers/results/random.json"));
    bench_mod.addOptions("build_paths", build_paths);

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

    // benchfence UNITS drivers (replace the former Nushell drivers). Each execs the
    // vendored benchfence binary over `zig-out/bin/bench`, so they depend on the install.
    addDriveStep(b, bench, "throughput", "throughput", "Benchmark every profile × parser path via benchfence");
    addDriveStep(b, bench, "matrix", "matrix", "DETECT×COLLAPSE matrix over a corpus: `zig build matrix -- <corpus.csv>`");
    addDriveStep(b, bench, "vs-rust", "vs-rust", "Compare zsift vs rust-csv over the structured corpora");
    addDriveStep(b, bench, "vs-all", "vs-all", "Compare zsift vs zsv vs rust over structured + random corpora");
    addDriveStep(b, bench, "random", "random", "Compare zsift vs rust-csv over the randomized corpora");
}

/// A `bench gen <kind>` step. Forwards `-- <args>` (e.g. the output dir). Generators
/// are self-contained (they only write files), so no install dependency is needed.
fn addGenStep(b: *std.Build, bench: *std.Build.Step.Compile, kind: []const u8, step_name: []const u8, desc: []const u8) void {
    const run = b.addRunArtifact(bench);
    run.addArgs(&.{ "gen", kind });
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, desc).dependOn(&run.step);
}

/// A `bench drive <driver>` step. The units reference the INSTALLED `zig-out/bin/bench`
/// (via build_paths.zsift_bench), so the run depends on the install step existing.
fn addDriveStep(b: *std.Build, bench: *std.Build.Step.Compile, driver: []const u8, step_name: []const u8, desc: []const u8) void {
    const run = b.addRunArtifact(bench);
    run.addArgs(&.{ "drive", driver });
    if (b.args) |args| run.addArgs(args);
    run.step.dependOn(b.getInstallStep());
    b.step(step_name, desc).dependOn(&run.step);
}
