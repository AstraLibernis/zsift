#!/usr/bin/env nu
# zsift vs rust-csv over randomized CSV workloads (all *.csv in ./rcorpus, made by
# genrand.py). Same gating as driver.nu. Edit the benchfence path below if needed.
use /home/astralibernis/projects/benchfence/lib/driver.nu *

const HERE  = path self | path dirname
def zsift [] { $HERE | path dirname | path dirname | path join zig-out bin bench }
def rust  [] { $HERE | path join rustcsv target release rustcsv-bench }

def units [] {
    let dir = ($HERE | path join rcorpus)
    let files = (glob $"($dir)/*.csv" | each {|p| $p | path basename | str replace ".csv" "" } | sort)
    $files | each {|c|
        let f = ($dir | path join $"($c).csv")
        [
            {name: $"zsift/push/($c)",      do: {|core| with-env {ZSIFT_CORPUS: $f} { pinned $core [(zsift) x push] }}}
            {name: $"zsift/pull/($c)",      do: {|core| with-env {ZSIFT_CORPUS: $f} { pinned $core [(zsift) x pull] }}}
            {name: $"rust/byterecord/($c)", do: {|core| pinned $core [(rust) byterecord $f] }}
            {name: $"rust/core/($c)",       do: {|core| pinned $core [(rust) core $f] }}
        ]
    } | flatten
}
def main [--reps: int = 12, --out: string = "results/random.json"] {
    drive (units) --reps $reps --metric "MB/s" --direction higher --out $out | ignore
}
