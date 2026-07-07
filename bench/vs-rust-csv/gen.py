# Deterministic CSV corpus generator mirroring zsift's src/bench.zig generate():
# 8 cols, same word list, profiles clean/quoted/escapey. Throwaway data-gen only;
# the benchmarked code is Zig (zsift) and Rust (rust-csv). Identical bytes feed both.
import os, random, sys

WORDS = ["alpha","bravo","charlie","delta","echo","foxtrot",
         "golf","hotel","india","juliet","kilo","lima",
         "1234","56.78","true","","n/a","x"]
COLS = 8
TARGET = 16*1024*1024

def gen(path, quote_pct, escape_pct, seed):
    rnd = random.Random(seed)
    buf = []
    size = 0
    while size < TARGET:
        row = []
        for c in range(COLS):
            w = WORDS[rnd.randrange(len(WORDS))]
            if rnd.randrange(100) < quote_pct:
                s = '"' + w
                if rnd.random() < 0.5:
                    s += ',more'
                if rnd.randrange(100) < escape_pct:
                    s += '""q""'
                s += '"'
            else:
                s = w
            row.append(s)
        line = ",".join(row) + "\n"
        buf.append(line)
        size += len(line)
    data = "".join(buf).encode()
    with open(path, "wb") as f:
        f.write(data)
    return len(data)

base = sys.argv[1]
os.makedirs(base, exist_ok=True)
for name, q, e in [("clean",0,0),("quoted",30,0),("escapey",60,50)]:
    n = gen(f"{base}/{name}.csv", q, e, 0xC57ABE11)
    print(f"{name}.csv: {n/1024/1024:.2f} MiB")
