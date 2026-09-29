# benchfence — what the vendored binary does

> **An apology.** benchfence was my own tool, and its source code was lost when I migrated
> my projects off Codeberg (because of Codeberg's anti-AI rules) on 2026-09-29. I'm sorry: it
> was a real project, and the stripped binary in this folder is now the only copy. It still
> works, but it can no longer be fixed, rebuilt, or ported. This page records what it does,
> so the design survives even though the code did not. — AstraLibernis

**Retired 2026-09-29.** zsift no longer runs benchfence. Without source it can't be
debugged or fixed, and on WSL it rejected most samples (the cores rarely read as idle), so
v0.4 measures with an in-repo alternating comparison instead (`zig build compare`, see the
README's "Measuring" section). The binary stays here as the record of how the v0.1–v0.3.1
numbers were made.

Everything below was read from the binary itself (`--help`, `--probe`, its embedded strings,
and one short gated run on 2026-09-29), plus how zsift drives it (`src/bench/drive.zig`).
The exact build is in [`benchfence.version`](benchfence.version): 0.4.0-dev, commit `497fce0`,
static musl x86_64. Nothing here is from the lost source; where a detail could not be
observed, it says so.

## What it is

A **benchmark fence**: it runs a benchmark command and keeps only the samples it can show
the machine did not spoil. It is built for noisy machines (a shared Hyper-V VM, WSL), where
the host steals CPU and identical runs swing 30% or more.

## A gated run (`--units`, "level 2")

```sh
benchfence --units units.json --reps 50 --metric MB/s --bound mem
```

1. **Know the venue.** Identify the machine: CPU model, core/thread count, and whether it
   runs under a hypervisor (it calls `systemd-detect-virt` and reads `/proc/cpuinfo` and
   `/sys/devices/system/cpu`). An embedded chip table gives a modelled peak (cores, clock,
   SIMD width), marked unverified where it is. It then says what is achievable here, e.g.
   on WSL: turbo unreachable, so the base clock, and "host may preempt".
   The per-venue profile lives in `$XDG_STATE_HOME/benchfence/<venue>.json` (by default
   `~/.local/state/benchfence/`).
2. **Pick fence cores.** One logical CPU per physical core, keeping some back for the
   desktop (`--reserve N`, `-1` = auto). The benchmark is pinned with `taskset`, run under
   `setarch` with ASLR disabled, and wrapped in `env LC_ALL=C`.
3. **Quiet the desktop.** For the run, it caps `session.slice` and `background.slice` with
   `systemctl --user set-property` (`CPUQuota=100%`, `CPUWeight=20`) and may switch the
   power profile. It writes an undo record first; `benchfence --restore` reverts a desktop
   left quieted by a crash. With no desktop session (WSL) it reports "quieted nothing".
4. **Gate every sample.** A *referee* (a fixed probe workload) is timed on the fence core
   before and after each sample and compared with the venue's idle floor. If the core is
   not at its idle speed, the sample is discarded and retaken, up to the `--wait` budget
   (`quick` 3 s, `normal` 60 s, `patient` 180 s, capped at 180 s). Referees:
   - `zig-compute` (default): CPU-bound.
   - `zig-mem`: memory-bound. `--bound mem` selects it; the compute referee cannot see DRAM
     bandwidth contention.
   - `awk`: a legacy yardstick (`BEGIN{s=0; for(i=0;i<20000000;i++) s+=i%7}`).
   - `--referee-cmd CMD`: any pinned probe; its wall time becomes the calibration.
5. **Report.** Per unit: `best_trusted` (the best of only the gate-passed samples), `best`
   (all samples, which can be a contended outlier), `median`, `spread_pct`, how many
   samples were `trusted`, and how many were `hot` or `degraded`. `--out PATH` writes a
   results artifact (`--out ""` writes none). `--direction higher|lower` says whether
   bigger is better (throughput) or smaller is (latency).

It refuses to substitute defaults for values you asked for, and flags are long-only: the
first non-flag argument ends its parsing, so a short flag inside a wrapped command is
never misread.

## The units contract

```json
[ {"name": "gather8", "argv": ["./zig-out/bin/bench", "gather8"]} ]
```

Each unit needs exactly `name` and `argv`. Its command runs once per sample and must print
`BENCHFENCE_METRIC=<number>` (stdout or stderr, a bare number) and exit.
Up to v0.3.1, zsift's `bench drive <name>` built this list and called benchfence with
`--units`, `--bound`, `--wait`, `--reps`, `--metric` and `--direction` (`src/bench/drive.zig`,
removed at retirement; see tag v0.3.1).

## Other modes

| Command | What it does |
|---|---|
| `--probe` | Venue and capability report: chip, modelled vs achievable peak, fence cores, a per-core calibration (evenness check). Writes the venue profile. |
| `--characterize` | Once per machine: the noise class and the idle floor per referee. Uncharacterized venues fall back to a 3% tolerance and no seeded floor. |
| `--retol` | Re-derive the current referee's gate tolerance from its idle spread. |
| `--restore` | Revert a desktop left quieted by a crash, from the undo record. |
| `--sweep` | Diagnostic L1 → L2 → L3 → DRAM table. |
| `--ab --units u.json` | Interleaved A/B of two referees (`--a`, `--b`, `--rounds`, defaults 4 × 30 reps), with a statistical verdict on whether one referee senses contention the other misses. The slowest mode by far. |
| `benchfence ./cmd` | "Level 1": wrap a single command and report drift only, no per-sample gate. |

Environment: `BENCHFENCE_CORES`, `BENCHFENCE_FLOOR_FILE`, `BENCHFENCE_FLOOR_MS`,
`BENCHFENCE_MAX_WAIT`, `BENCHFENCE_TOLERANCE`, `BENCHFENCE_VENUE`, `BENCHFENCE_TAG`,
`BENCHFENCE_REFEREE_ID` appear in the binary. Their exact semantics were not observed.

## What was lost with the source

- The referee workloads and how their timings become a floor, a tolerance and a noise class.
- The embedded chip table (modelled clocks, core counts, SIMD widths, venue notes).
- The `--ab` statistics and the `--sweep` implementation.
- Its tests, docs and history.

Rebuilding it means re-deriving those from this page and the binary's behaviour; the binary
can serve as the oracle for a rewrite.

## Observed on this repo's current machine (2026-09-29)

`--probe` on an i7-1365U under WSL2: venue `…_wsl_6c12t`, fence cores `[2,4,6,8,10]`,
modelled 2 cores at 5.2 GHz but achievable 1.8 GHz (no turbo under WSL), per-core
calibration 145–160 ms. A 3-sample gated demo took under 5 s: 2 of 3 samples passed the
gate, one was flagged hot, and `systemctl --user` slice settings were unchanged afterwards.
