# bench/units.nu — drive the VENDORED benchfence binary from a units list.
#
# The fencer is a single vendored binary at bench/benchfence (a built + stripped benchfence
# release — see bench/benchfence.version for which one). This module is the WHOLE consuming glue:
# a driver builds a [{name, argv}] list, hands it here, and benchfence owns the
# gate -> measure -> postcheck -> retry loop. Nothing here re-implements any of that — no pinning,
# no calibration, no gating. That was the old lib/driver.nu handshake; it is gone.
#
# No hardcoded path: $BENCHFENCE wins, else the repo-local bench/benchfence next to this file. If
# neither exists we FAIL LOUDLY rather than silently run the benchmark unfenced.

# This module's own directory (…/bench), resolved at PARSE TIME — that is where bench/benchfence sits.
const HERE = (path self | path dirname)

# Absolute path to the vendored benchfence binary, or a loud error.
export def benchfence-bin []: nothing -> string {
    let bf = ($env.BENCHFENCE? | default ($HERE | path join benchfence))
    if not ($bf | path exists) {
        error make {msg: $"benchfence binary not found at ($bf).
  Vendor bench/benchfence \(a built + stripped benchfence release\) or set $BENCHFENCE.
  See the benchfence repo's example/README.md for the consuming contract."}
    }
    $bf
}

# Run a units list through benchfence. units = [{name: string, argv: list<string>}].
# benchfence applies the fence (pin + ASLR-off + LC_ALL=C) itself, so argv must NOT re-pin.
# zsift is a CSV parser — MEMORY-bound — so the default referee is --bound mem.
export def run-units [
    units: list                        # the [{name, argv}] unit list
    --reps: int = 15                   # measurements per unit
    --metric: string = "MB/s"
    --direction: string = "higher"     # throughput; "lower" for latency
    --bound: string = "mem"            # gate on the memory referee (zsift is mem-bound)
    --wait: string = "normal"          # gate patience: quick|normal|patient|<sec>
    --out: string = ""                 # results artifact; also writes <out-stem>.units.json beside it
]: nothing -> nothing {
    let bf = (benchfence-bin)
    if ($units | is-empty) {
        error make {msg: "no units to run — nothing to measure (missing corpora? generate them first)"}
    }
    let uf = (mktemp --suffix .json)
    $units | to json | save --force $uf
    if ($out | is-empty) {
        ^$bf --units $uf --bound $bound --wait $wait --reps $reps --metric $metric --direction $direction
    } else {
        let dir = ($out | path dirname)
        if not ($dir | is-empty) { mkdir $dir }
        ^$bf --units $uf --bound $bound --wait $wait --reps $reps --metric $metric --direction $direction --out $out
        # Provenance — written ONLY after a successful run (a failing `^$bf` errors above, so no
        # orphan .units.json is left beside missing results): the exact units list beside the
        # results, version-controlling the tests you ran.
        $units | to json | save --force ($out | str replace --regex '\.json$' '.units.json')
    }
    rm --force $uf
}
