#!/usr/bin/env nu
# Trust-gated benchmark for zsift.
#
# Builds the bench (ReleaseFast) and runs it under *benchfence*, which pins the
# run to a quiet physical core (ASLR off, perf governor where available) and takes
# a calibration before and after. We accept a run's numbers ONLY when both
# calibrations sit within tolerance of the venue floor — i.e. the whole run
# happened at the machine's idle speed. On a contended shared VM that may take a
# few tries; if no quiet window appears, we still print the best-effort run but
# banner it UNTRUSTWORTHY rather than pretending VM noise is signal.
#
# benchfence is an external dependency (https://codeberg.org/AstraLibernis/benchfence).
# Point ZSIFT_BENCHFENCE at the executable, or keep it at ~/projects/benchfence.
#
#   nu bench.nu                 # up to 6 attempts to catch a quiet window
#   nu bench.nu --attempts 12

def main [--attempts: int = 6] {
    let repo = $env.FILE_PWD
    let bf = ($env.ZSIFT_BENCHFENCE? | default $"($env.HOME)/projects/benchfence/benchfence")
    if not ($bf | path exists) {
        error make {msg: $"benchfence not found at ($bf); clone it or set ZSIFT_BENCHFENCE"}
    }

    cd $repo
    print "building bench (ReleaseFast)…"
    ^zig build -Doptimize=ReleaseFast
    let bin = ($repo | path join zig-out bin bench)

    mut runs = []
    for attempt in 1..$attempts {
        let work = (mktemp -d)
        cd $work
        ^$bf $bin
        cd $repo
        let fj = (glob ($work | path join "out/**/*.fence.json") | first)
        let v = (open $fj)
        let bar = ($v.floor_ms * (1.0 + ($v.tolerance / 100.0)))
        let quiet = ($v.pre_ms <= $bar and $v.post_ms <= $bar)
        let logpath = ($work | path join $v.log) # v.log is relative to the run cwd
        let table = (open $logpath | lines | where ($it =~ '(?i)profile|MB/s|clean|quoted|escapey') | str join "\n")

        if $quiet {
            print $"\n✅ TRUSTWORTHY — both cals at idle: pre ($v.pre_ms) ms, post ($v.post_ms) ms ≤ bar (($bar | math round)) ms \(floor ($v.floor_ms), tol ($v.tolerance)%, drift ($v.drift_pct)%\)"
            print $table
            return
        }

        print $"attempt ($attempt)/($attempts): contended — pre ($v.pre_ms) / post ($v.post_ms) ms vs floor ($v.floor_ms) ms \(drift ($v.drift_pct)%\); retrying"
        $runs = ($runs | append {v: $v, table: $table})
    }

    let best = ($runs | sort-by v.drift_pct | first)
    print $"\n⚠️  UNTRUSTWORTHY — no quiet window in ($attempts) attempts; the VM is contended."
    print $"   best-effort run: pre ($best.v.pre_ms) / post ($best.v.post_ms) ms vs floor ($best.v.floor_ms) ms \(drift ($best.v.drift_pct)%\)"
    print "   relative ordering across parsers is still meaningful; absolutes are not."
    print $best.table
}
