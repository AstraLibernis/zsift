#!/usr/bin/env nu
# benchfence level-2 driver for the DETECT × COLLAPSE method matrix.
# Each cell is gated (core proven at idle baseline before/after) and repeated, so
# the per-cell throughput is trust-filtered rather than a single raw run.
#
# Set ZSIFT_CORPUS to a CSV first, e.g.:
#   ZSIFT_CORPUS=/path/combined.csv benchfence --bound mem --run matrix-bench.nu --reps 10

use /home/astralibernis/projects/benchfence/lib/driver.nu *

def bench_bin [] {
    let b = (($env.FILE_PWD? | default (pwd)) | path join zig-out bin bench)
    if not ($b | path exists) {
        error make {msg: $"build first: `zig build -Doptimize=ReleaseFast` \(missing ($b)\)"}
    }
    $b
}

# The informative cells: baseline, each fix alone, both, a swar variant, and the
# skip-everything ceiling (wrong output, but the delivery-path upper bound).
def units [] {
    let bin = (bench_bin)
    let cells = [
        [detect collapse];
        [rescan byteloop]
        [accum  byteloop]
        [rescan memcpy]
        [accum  memcpy]
        [rescan swarcpy]
        [accum  swarcpy]
        [swar   swarcpy]
    ]
    $cells | each {|c|
        {name: $"($c.detect)/($c.collapse)", do: {|core| pinned $core [$bin cell $c.detect $c.collapse] }}
    }
}

def main [--reps: int = 10] {
    drive (units) --reps $reps --metric "MB/s" --direction higher | ignore
}
