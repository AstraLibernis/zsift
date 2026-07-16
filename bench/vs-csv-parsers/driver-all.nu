#!/usr/bin/env nu
# zsift vs zsv (racecar peer) vs rust byterecord (full-library baseline), over the structured
# (./corpus) and randomized (./rcorpus) corpora. Build zsvbench first (see BUILD-zsv.md) and the
# rust bench (see README). benchfence UNITS driver: each unit's corpus is a trailing argv arg.

use ../units.nu *

const HERE = (path self | path dirname)
def zsift-bin [] { $HERE | path dirname | path dirname | path join zig-out bin bench }
def rust-bin  [] { $HERE | path join rustcsv target release rustcsv-bench }
def zsv-bin   [] { $HERE | path join zsvbench }

def units []: nothing -> list {
    let zsift = (zsift-bin)
    let rust = (rust-bin)
    let zsv = (zsv-bin)
    let jobs = ([clean quoted escapey] | each {|c| {c: $c, f: ($HERE | path join corpus $"($c).csv")}})
        | append ([rand0 rand1 rand2 rand3] | each {|c| {c: $c, f: ($HERE | path join rcorpus $"($c).csv")}})
    $jobs | where {|j| $j.f | path exists } | each {|j|
        [
            {name: $"zsift/push/($j.c)", argv: [$zsift x push $j.f]}
            {name: $"zsift/pull/($j.c)", argv: [$zsift x pull $j.f]}
            {name: $"zsv/($j.c)",        argv: [$zsv $j.f]}
            {name: $"rust/byte/($j.c)",  argv: [$rust byterecord $j.f]}
        ]
    } | flatten
}

def main [--reps: int = 12, --wait: string = "normal", --out: string = ""] {
    let o = (if ($out | is-empty) { $HERE | path join results comparison-zsift-zsv-rust.json } else { $out })
    run-units (units) --reps $reps --wait $wait --out $o
}
