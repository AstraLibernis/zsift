#!/usr/bin/env nu
# zsift vs zsv (racecar peer) vs rust byterecord (full-library baseline), over the
# structured (./corpus) and randomized (./rcorpus) corpora. Build zsvbench first
# (see BUILD-zsv.md) and the rust bench (see README). Edit the benchfence path below.
use /home/astralibernis/projects/benchfence/lib/driver.nu *
const HERE = path self | path dirname
def zsift [] { $HERE | path dirname | path dirname | path join zig-out bin bench }
def rust  [] { $HERE | path join rustcsv target release rustcsv-bench }
def zsv   [] { $HERE | path join zsvbench }

def units [] {
    let jobs = ([clean quoted escapey] | each {|c| {c: $c, f: ($HERE | path join corpus $"($c).csv")}})
        | append ([rand0 rand1 rand2 rand3] | each {|c| {c: $c, f: ($HERE | path join rcorpus $"($c).csv")}})
    $jobs | where {|j| $j.f | path exists } | each {|j|
        [
            {name: $"zsift/push/($j.c)", do: {|core| with-env {ZSIFT_CORPUS: $j.f} { pinned $core [(zsift) x push] }}}
            {name: $"zsift/pull/($j.c)", do: {|core| with-env {ZSIFT_CORPUS: $j.f} { pinned $core [(zsift) x pull] }}}
            {name: $"zsv/($j.c)",        do: {|core| pinned $core [(zsv) $j.f] }}
            {name: $"rust/byte/($j.c)",  do: {|core| pinned $core [(rust) byterecord $j.f] }}
        ]
    } | flatten
}
def main [--reps: int = 12, --out: string = "results/comparison-zsift-zsv-rust.json"] {
    drive (units) --reps $reps --metric "MB/s" --direction higher --out $out | ignore
}
