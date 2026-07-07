# Randomized-but-deterministic CSV workloads. Each workload draws its own params
# (cols, field style, quote/escape rates) from a master seed, then generates
# deterministically. Still valid RFC4180 CSV. Throwaway data-gen; measured code
# is Zig (zsift) vs Rust (rust-csv), fed identical bytes.
import os, random, string, sys, json

TARGET = 16*1024*1024
master = random.Random(0xF00DCAFE)

SHORT = ["alpha","bravo","charlie","delta","echo","golf","hotel","x","","n/a","true","false"]

def make_vocab(style, rnd):
    if style == "short":
        return SHORT
    if style == "numeric":
        return [str(rnd.randint(0,10**9)) for _ in range(40)] + \
               [f"{rnd.uniform(0,1e6):.4f}" for _ in range(40)] + ["", "0"]
    if style == "long":
        return ["".join(rnd.choice(string.ascii_letters+" ")
                        for _ in range(rnd.randint(15,45))) for _ in range(60)] + [""]
    # mixed
    v = list(SHORT)
    v += [str(rnd.randint(0,10**6)) for _ in range(20)]
    v += ["".join(rnd.choice(string.ascii_letters) for _ in range(rnd.randint(8,25))) for _ in range(20)]
    return v

def gen(path, cols, style, quote_pct, escape_pct, comma_pct, seed):
    rnd = random.Random(seed)
    vocab = make_vocab(style, rnd)
    buf, size = [], 0
    while size < TARGET:
        row = []
        for _ in range(cols):
            w = vocab[rnd.randrange(len(vocab))]
            if rnd.randrange(100) < quote_pct:
                s = '"' + w
                if rnd.randrange(100) < comma_pct: s += ",more"
                if rnd.randrange(100) < escape_pct: s += '""q""'
                s += '"'
            else:
                s = w
            row.append(s)
        line = ",".join(row) + "\n"
        buf.append(line); size += len(line)
    data = "".join(buf).encode()
    open(path,"wb").write(data)
    return len(data)

N = int(sys.argv[2]) if len(sys.argv) > 2 else 4
styles = ["short","numeric","long","mixed"]
os.makedirs(sys.argv[1], exist_ok=True)
meta = []
for i in range(N):
    cols   = master.randint(3, 22)
    style  = master.choice(styles)
    qp     = master.randint(0, 70)
    ep     = master.randint(0, 60)
    cp     = master.randint(0, 60)
    seed   = master.randint(1, 2**31)
    n = gen(f"{sys.argv[1]}/rand{i}.csv", cols, style, qp, ep, cp, seed)
    m = {"name":f"rand{i}","cols":cols,"style":style,"quote_pct":qp,
         "escape_pct":ep,"comma_pct":cp,"MiB":round(n/1024/1024,2)}
    meta.append(m)
    print(f"rand{i}: cols={cols:2d} style={style:<7} quote={qp:2d}% escape={ep:2d}% comma={cp:2d}%  {m['MiB']} MiB")
json.dump(meta, open(f"{sys.argv[1]}/meta.json","w"), indent=1)
