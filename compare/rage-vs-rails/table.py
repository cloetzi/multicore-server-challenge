# Prints results*.jsonl as a markdown table: python3 table.py results-linux.jsonl
# run = probe (2-minute) or hold (5-minute); rep 2 = a repeat. workers = busiest worker's CPU / mean worker CPU.
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
print("| users | server | run | req/s | p50 ms | p95 ms | p99 ms | err% | app µs/req | pg µs/req | app cores | pg cores | app MB | workers max/mean | lg cores | result |")
print("|--:|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")
def balance(r):  # busiest worker / mean of the WORKERS busiest processes (leaves out the master)
    w = r.get("worker_cores") or []
    top = w[:r.get("workers", 8)]
    return round(top[0] / (sum(top) / len(top)), 2) if top else ""
for r in sorted(rows, key=lambda r: (r["users"], r["sub"], r.get("phase", ""), r.get("rep", 1))):
    res = "pass" if r.get("pass") else "FAIL"
    if r.get("lg_limited"): res += " (loadgen-limited)"
    run = r.get("phase", "") + (" (repeat)" if r.get("rep", 1) > 1 else "") + (f" [{r['variant']}]" if r.get("variant", "baseline") != "baseline" else "")
    print(f'| {r["users"]} | {r["sub"]} | {run} | {r["rps"]} | {r["p50"]} | {r["p95"]} | {r["p99"]} | {r["err%"]} | '
          f'{r["app_us_per_req"]} | {r["pg_us_per_req"]} | {r["app_cores"]} | {r["pg_cores"]} | {r.get("app_anon_mb", r.get("rss_mb", ""))} | '
          f'{balance(r)} | {r.get("lg_cores", "")} | {res} |')
