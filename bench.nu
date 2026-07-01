#!/usr/bin/env nu
# Trust-gated benchmark for zsift — a benchfence level-2 DRIVER script.
#
# Each (profile, path) pair is a "unit". benchfence's driver (`lib/driver.nu`
# `drive`) GATES and repeats each unit's measurement: before every measurement it
# proves the pinned core is back at its idle speed, takes the measurement, then
# post-checks that the core stayed idle — discarding and re-measuring a sample the
# machine spoiled mid-flight. That is per-sample trust ("level 2"), not the old
# wrap-the-whole-binary-and-check-pre/post-drift approximation ("level 1") this
# file used to hand-roll. The benchmark binary's single-shot mode
# (`bench <profile> <path>` → `BENCHFENCE_METRIC=…`) is what lets the driver own
# the iteration; the human table (`bench` with no args) is unchanged.
#
# benchfence is an external dependency (https://codeberg.org/AstraLibernis/benchfence).
# The `use` path below is hardcoded to ~/projects/benchfence; edit it if yours differs
# (nushell `use` needs a literal path, so it can't read an env var).
#
# Usage (two steps — building is NOT done inside the fenced run, on purpose):
#   zig build -Doptimize=ReleaseFast
#   benchfence --bound mem --run bench.nu --reps 20    # RECOMMENDED
#
# Use `--bound mem`: zsift is a CSV parser — it streams MBs sequentially, so it is
# MEMORY-bound. The default awk/CPU referee is structurally blind to DRAM-bandwidth
# contention (it would call a run "clean" while another tenant starved the parser on
# memory); the mem referee gates on the contention that actually affects zsift. Plain
# `benchfence --run bench.nu` works too but gates on CPU steadiness only.
#
# Run it WITHOUT benchfence and it still measures — ungated and loudly flagged.

use /home/astralibernis/projects/benchfence/lib/driver.nu *

def bench_bin [] {
    let b = (($env.FILE_PWD? | default (pwd)) | path join zig-out bin bench)
    if not ($b | path exists) {
        error make {msg: $"build first: `zig build -Doptimize=ReleaseFast` \(missing ($b)\)"}
    }
    $b
}

# units = every profile × every parser path. Each unit's closure runs ONE
# single-shot measurement of the bench binary; `pinned` runs it (pinning/ASLR are
# inherited from the benchfence wrap) and reads back its BENCHFENCE_METRIC.
def units [] {
    let bin = (bench_bin)
    let profiles = [clean quoted escapey]
    let paths = [scalar pull push stream]   # ceil is a structural scan ceiling, not a parser path
    $profiles | each {|p|
        $paths | each {|path|
            {name: $"($p)/($path)", do: {|core| pinned $core [$bin $p $path] }}
        }
    } | flatten
}

def main [--reps: int = 20] {
    drive (units) --reps $reps --metric "MB/s" --direction higher | ignore
}
