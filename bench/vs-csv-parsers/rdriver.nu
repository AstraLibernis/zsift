#!/usr/bin/env nu
# zsift vs rust-csv over randomized CSV workloads (all *.csv in ./rcorpus, made by genrand.py).
# Same gating as driver.nu. benchfence UNITS driver: each unit's corpus is a trailing argv arg.

use ../units.nu *

const HERE = (path self | path dirname)
def zsift-bin [] { $HERE | path dirname | path dirname | path join zig-out bin bench }
def rust-bin  [] { $HERE | path join rustcsv target release rustcsv-bench }

def units []: nothing -> list {
    let zsift = (zsift-bin)
    let rust = (rust-bin)
    let dir = ($HERE | path join rcorpus)
    let files = (glob $"($dir)/*.csv" | each {|p| $p | path basename | str replace ".csv" "" } | sort)
    $files | each {|c|
        let f = ($dir | path join $"($c).csv")
        [
            {name: $"zsift/push/($c)",      argv: [$zsift x push $f]}
            {name: $"zsift/pull/($c)",      argv: [$zsift x pull $f]}
            {name: $"rust/byterecord/($c)", argv: [$rust byterecord $f]}
            {name: $"rust/core/($c)",       argv: [$rust core $f]}
        ]
    } | flatten
}

def main [--reps: int = 12, --wait: string = "normal", --out: string = ""] {
    let o = (if ($out | is-empty) { $HERE | path join results random.json } else { $out })
    run-units (units) --reps $reps --wait $wait --out $o
}
