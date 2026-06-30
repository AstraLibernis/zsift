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
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("csv", csv_mod);
    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the throughput benchmark");
    bench_step.dependOn(&run_bench.step);
}
