#!/usr/bin/env python3
"""GC and YJIT per Rage worker over each run's measured window, from the RAGE_STATS=1 dump.

  sudo docker exec msc-app bash -c 'cat /tmp/rage-stats-*.jsonl' > stats.jsonl
  python3 compare/rage-vs-rails/stats.py stats.jsonl compare/rage-vs-rails/results-linux.jsonl

Each run's window is taken from its result line: it ends TAIL (15 s) + a few seconds before the result's timestamp
and lasts measure_s. Only results whose app_env has RAGE_STATS=1 are matched.
"""
import collections, datetime, json, sys

samples = collections.defaultdict(list)  # pid -> samples
for line in open(sys.argv[1]):
    if line.startswith("{"):
        s = json.loads(line)
        samples[s["pid"]].append(s)

results = [json.loads(l) for l in open(sys.argv[2]) if l.startswith("{")]
results = [r for r in results if "RAGE_STATS=1" in r.get("app_env", "") and "ts" in r]

print("| users | run | variant | workers | GC % of worker CPU | minor GC/s | major GC/s | GC ms/s | live slots (M) | malloc limit MB | YJIT code MB | code GCs | last major by |")
print("|--:|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")
for r in results:
    end = datetime.datetime.strptime(r["ts"], "%Y-%m-%dT%H:%M:%S").timestamp() - 18
    start = end - r["measure_s"]
    rows = []
    for pid, ss in samples.items():
        w = [s for s in ss if start <= s["t"] <= end]
        if len(w) < 2:
            continue
        a, b = w[0], w[-1]
        secs, cpu = b["t"] - a["t"], b["cpu"] - a["cpu"]
        if cpu < 0.05 * secs:  # the master
            continue
        g = lambda k: b["gc"][k] - a["gc"][k]
        rows.append(dict(gc_pct=100 * g("time") / 1000 / cpu, minor=g("minor_gc_count") / secs, major=g("major_gc_count") / secs,
                         gc_ms=g("time") / secs, live=b["gc"]["heap_live_slots"] / 1e6,
                         malloc=b["gc"]["malloc_increase_bytes_limit"] / 2**20,
                         code=b["yjit"].get("code_region_size", 0) / 2**20, code_gc=b["yjit"].get("code_gc_count", 0),
                         major_by=b.get("last_major_by")))
    if not rows:
        print(f'| {r["users"]} | {r["phase"]} | {r.get("variant")} | 0 | (no samples in the window) |||||||||')
        continue
    avg = lambda k: sum(x[k] for x in rows) / len(rows)
    rng = lambda k, f: f"{f.format(avg(k))} ({f.format(min(x[k] for x in rows))}-{f.format(max(x[k] for x in rows))})"
    print(f'| {r["users"]} | {r["phase"]} | {r.get("variant")} | {len(rows)} | {rng("gc_pct", "{:.1f}")} | {avg("minor"):.2f} | '
          f'{avg("major"):.3f} | {avg("gc_ms"):.1f} | {avg("live"):.2f} | {avg("malloc"):.0f} | {avg("code"):.1f} | '
          f'{max(x["code_gc"] for x in rows)} | {",".join(sorted({str(x["major_by"]) for x in rows}))} |')
