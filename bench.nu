#!/usr/bin/env nu
# zsift throughput benchmark — a benchfence UNITS driver.
#
# Each (profile, path) pair is a unit: a single-shot run of the bench binary that prints
# BENCHFENCE_METRIC=<MB/s>. benchfence owns the gate -> measure -> retry loop (it pins the core,
# disables ASLR, sets LC_ALL=C, and proves the core idle before/after each sample); this script
# only DESCRIBES the units. That is "level 2": per-sample trust, not wrap-the-whole-binary drift.
#
# Two steps (building is NOT done inside the fenced run, on purpose):
#   zig build -Doptimize=ReleaseFast
#   nu bench.nu --reps 20
#
# The fencer is the vendored bench/benchfence binary (override with $BENCHFENCE). zsift is a CSV
# parser — memory-bound — so units.nu gates on the mem referee (--bound mem) by default: the CPU
# referee is structurally blind to the DRAM-bandwidth contention that actually slows the parser.

use bench/units.nu *

const HERE = (path self | path dirname)

def bench-bin []: nothing -> string {
    let b = ($HERE | path join zig-out bin bench)
    if not ($b | path exists) {
        error make {msg: $"build first: `zig build -Doptimize=ReleaseFast` \(missing ($b)\)"}
    }
    $b
}

# units = every profile × every parser path; each is one single-shot measurement. argv is exec'd
# DIRECTLY by benchfence — no shell, no pinning here (the fence is inherited from the wrap).
def units []: nothing -> list {
    let bin = (bench-bin)
    let profiles = [clean quoted escapey]
    let paths = [scalar pull push stream]   # ceil is a structural scan ceiling, not a parser path
    $profiles | each {|p|
        $paths | each {|path| {name: $"($p)/($path)", argv: [$bin $p $path]} }
    } | flatten
}

def main [--reps: int = 20, --wait: string = "normal"] {
    run-units (units) --reps $reps --wait $wait
}
