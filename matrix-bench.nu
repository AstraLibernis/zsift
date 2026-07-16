#!/usr/bin/env nu
# benchfence UNITS driver for the DETECT × COLLAPSE method matrix.
# Each cell is one single-shot run over a corpus CSV; benchfence gates + repeats each.
#
#   zig build -Doptimize=ReleaseFast
#   nu matrix-bench.nu /path/to/corpus.csv --reps 10
#
# The corpus path is a POSITIONAL argument (it becomes each unit's trailing argv arg — benchfence
# execs argv directly, so there is no $ZSIFT_CORPUS env to set). Fencer: vendored bench/benchfence
# (override with $BENCHFENCE); zsift is mem-bound, so units.nu gates on the mem referee.

use bench/units.nu *

const HERE = (path self | path dirname)

def bench-bin []: nothing -> string {
    let b = ($HERE | path join zig-out bin bench)
    if not ($b | path exists) {
        error make {msg: $"build first: `zig build -Doptimize=ReleaseFast` \(missing ($b)\)"}
    }
    $b
}

# The informative cells: baseline, each fix alone, both, a swar variant, and the swar-detect combo.
def units [corpus: string]: nothing -> list {
    let bin = (bench-bin)
    let cpath = ($corpus | path expand)
    if not ($cpath | path exists) { error make {msg: $"corpus not found: ($cpath)"} }
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
        {name: $"($c.detect)/($c.collapse)", argv: [$bin cell $c.detect $c.collapse $cpath]}
    }
}

def main [corpus: string, --reps: int = 10] {
    run-units (units $corpus) --reps $reps
}
