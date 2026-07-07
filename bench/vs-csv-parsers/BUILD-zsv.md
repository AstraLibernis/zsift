# Building the zsv comparison target

zsv (https://github.com/liquidaty/zsv) is an external dependency — cloned + built
here but gitignored (not vendored), the same way the rust bench fetches its crates.

Run from this directory (`bench/vs-csv-parsers/`):

```sh
git clone --depth 1 https://github.com/liquidaty/zsv.git
( cd zsv && ./configure && cd src && make build )      # -> build/<os>/rel/cc/lib/libzsv.a
LIB=$(find zsv -name libzsv.a | head -1)
gcc -O3 -march=native -std=gnu11 zsvbench.c -Izsv/include "$LIB" -fopenmp -lm -o zsvbench
```

`zsvbench` reads $CORPUS (or argv[1]), parses with zsv's per-row / pull-cell API,
sums every cell length (matched task), best-of-7, prints BENCHFENCE_METRIC=<MB/s>.
The recorded run built zsv `-O3 -march=native -mavx2`, UTF-8 check off (same
no-validation footing as zsift). zsv emits one trailing blank row per file that
zsift/rust suppress — immaterial (sumlen is byte-identical across all three parsers).
