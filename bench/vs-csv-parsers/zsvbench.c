/* zsv side of the zsift-vs-zsv racecar comparison. Matched task: parse the whole
   corpus, sum every cell's byte length, count rows+cells. Reads $CORPUS (or argv[1]);
   best-of-7; prints BENCHFENCE_METRIC=<MB/s> on stdout, "rows cells sumlen" on stderr. */
#include <zsv.h>
#include <zsv/common.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct st { zsv_parser p; unsigned long long rows, cells, sumlen; };

static void row(void *ctx) {
    struct st *s = ctx;
    size_t n = zsv_cell_count(s->p);
    s->rows++;
    for (size_t i = 0; i < n; i++) { struct zsv_cell c = zsv_get_cell(s->p, i); s->cells++; s->sumlen += c.len; }
}

static unsigned long long parse_once(const unsigned char *data, size_t len,
                                     unsigned long long *rows, unsigned long long *cells) {
    struct st s; memset(&s, 0, sizeof s);
    struct zsv_opts opts; memset(&opts, 0, sizeof opts);
    opts.row_handler = row; opts.ctx = &s;
    s.p = zsv_new(&opts);
    zsv_parse_bytes(s.p, data, len);
    zsv_finish(s.p);
    zsv_delete(s.p);
    *rows = s.rows; *cells = s.cells;
    return s.sumlen;
}

static unsigned long long now_ns(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (unsigned long long)t.tv_sec*1000000000ull + t.tv_nsec; }

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : getenv("CORPUS");
    if (!path) { fprintf(stderr, "need corpus path (argv[1] or $CORPUS)\n"); return 2; }
    FILE *f = fopen(path, "rb"); if (!f) { perror("open"); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *data = malloc(len);
    if (fread(data, 1, len, f) != (size_t)len) { perror("read"); return 2; }
    fclose(f);

    unsigned long long rows, cells, sumlen = parse_once(data, len, &rows, &cells);
    unsigned long long best = ~0ull;
    for (int i = 0; i < 7; i++) {
        unsigned long long r, c, t0 = now_ns();
        volatile unsigned long long s = parse_once(data, len, &r, &c);
        unsigned long long dt = now_ns() - t0; (void)s;
        if (dt < best) best = dt;
    }
    double secs = best / 1e9, mib = (double)len / (1024.0*1024.0);
    printf("BENCHFENCE_METRIC=%.1f\n", mib / secs);
    fprintf(stderr, "rows=%llu cells=%llu sumlen=%llu\n", rows, cells, sumlen);
    free(data);
    return 0;
}
