#!/usr/bin/env bash
# One measured run: run.sh <submission> <users>. Fresh database copy, server started in msc-app with one worker per
# app CPU, a short unmeasured warm-up, then loadgen in msc-lg (ramp + measure + tail). Prints one JSON line:
# throughput, latency, verdict, and app/Postgres CPU over the measured window from each container's cgroup.
# APP_ENV="K=V ..." is passed to the server; VARIANT labels the result (default "baseline").
set -euo pipefail
source "$(dirname "$0")/config.sh"
S=$1 U=$2
SECRET=multicore-server-challenge
docker exec msc-app bash -c 'pkill -f "bin/[r]age|bin/[f]alcon"; true'; sleep 2
docker exec msc-lg psql -X -q -d postgres -c "DROP DATABASE IF EXISTS benchrun WITH (FORCE)" \
  -c "CREATE DATABASE benchrun TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
docker exec -d msc-app bash -c "cd /work/submissions/$S && DATABASE_URL=postgres://conduit:conduit@127.0.0.1:$PGPORT/benchrun \
  JWT_SECRET=$SECRET HOST=0.0.0.0 PORT=3000 WEB_CONCURRENCY=$WORKERS ${APP_ENV:-} exec bash start.sh > /tmp/server.log 2>&1"
for _ in $(seq 60); do docker exec msc-lg curl -sf -o /dev/null http://127.0.0.1:3000/api/tags && break; sleep 1; done

# More users than one source IP has ephemeral ports: spread them over several loopback addresses.
TARGETS=$(python3 -c "import sys; n=-(-int(sys.argv[1])//20000); print(','.join(f'http://127.0.0.{i+1}:3000' for i in range(n)))" "$U")
lg() { docker exec msc-lg loadgen run -target "$TARGETS" -articles "$ARTICLES" -secret "$SECRET" "$@"; }
lg -users 500 -think-scale 0.1 -ramp 10s -measure 30s -tail 2s -run-id "warm$RANDOM" -out /dev/null -q   # YJIT + plan warm-up

usage() { docker exec "$1" awk '/^usage_usec/{print $2}' /sys/fs/cgroup/cpu.stat; }
# every process in the app container: "pid (comm) state ... utime stime ...", for per-worker CPU over the window
procs() { docker exec msc-app bash -c 'for d in /proc/[0-9]*; do read -r l < $d/stat 2>/dev/null && echo "$l"; done'; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RUN=r$RANDOM$RANDOM
lg -users "$U" -think-scale "$THINK_SCALE" -ramp "${RAMP}s" -measure "${MEASURE}s" -tail "${TAIL}s" -run-id "$RUN" -out /tmp/$RUN.json -q &
LG=$!
sleep "$((RAMP + 2))"; A1=$(usage msc-app); P1=$(usage msc-pg); L1=$(usage msc-lg); procs > "$TMP/p1"; T1=$(date +%s.%N)
sleep "$((MEASURE - 2))"; A2=$(usage msc-app); P2=$(usage msc-pg); L2=$(usage msc-lg); procs > "$TMP/p2"; T2=$(date +%s.%N)
MEM=$(docker exec msc-app awk '/^anon /{print int($2/1048576)}' /sys/fs/cgroup/memory.stat)
wait $LG
docker exec msc-app bash -c 'pkill -f "bin/[r]age|bin/[f]alcon"; true'
docker exec msc-lg loadgen merge -o /tmp/$RUN.merged.json /tmp/$RUN.json >/dev/null || true
docker exec msc-lg cat /tmp/$RUN.merged.json | python3 -c '
import json, sys
m = json.load(sys.stdin); o = m["overall"]
s, u, a1, a2, p1, p2, t1, t2, mem, l1, l2, lgn, f1, f2 = sys.argv[1:15]
secs = float(t2) - float(t1)
app = (int(a2) - int(a1)) / 1e6 / secs; pg = (int(p2) - int(p1)) / 1e6 / secs; lg = (int(l2) - int(l1)) / 1e6 / secs
def ticks(f):  # pid -> (comm, utime + stime in clock ticks)
    d = {}
    for l in open(f):
        head, _, rest = l.rpartition(")"); pid, _, comm = head.partition(" (")
        x = rest.split(); d[pid] = (comm, int(x[11]) + int(x[12]))
    return d
b1, b2 = ticks(f1), ticks(f2)
# processes busy over the window (> 0.01 cores): the workers, plus the master if it does any work. The balance
# figure compares the busiest worker with the mean of the WORKERS busiest processes (leaving out the master).
w = sorted(((b2[p][1] - b1[p][1]) / 100 / secs for p in b2 if p in b1 and (b2[p][1] - b1[p][1]) / 100 / secs > 0.01), reverse=True)
nw = int(sys.argv[19]); top = w[:nw]
mean = sum(top) / len(top) if top else 0
lg_busy = lg / int(lgn) > 0.75   # loadgen checks the whole host /proc/stat, so measure its cgroup instead
print(json.dumps({"sub": s, "users": int(u), "rps": round(o["rps"]), "p50": round(o["p50_ms"], 1), "p95": round(o["p95_ms"], 1),
  "p99": round(o["p99_ms"], 1), "err%": round(o["error_rate"] * 100, 2), "pass": m["verdict"]["pass"],
  "lg_limited": m["verdict"]["lg_limited"] or lg_busy, "app_cores": round(app, 2), "pg_cores": round(pg, 2),
  "app_us_per_req": round(app / o["rps"] * 1e6), "pg_us_per_req": round(pg / o["rps"] * 1e6), "app_anon_mb": int(mem),
  "lg_cores": round(lg, 2), "worker_cores": [round(x, 2) for x in w], "worker_max_over_mean": round(w[0] / mean, 2) if w else None,
  "fail_reasons": m["verdict"].get("fail_reasons", []), "lg_reasons": m["verdict"].get("lg_reasons", []),
  "think_scale": float(sys.argv[15]), "measure_s": int(sys.argv[16]), "variant": sys.argv[17], "app_env": sys.argv[18], "workers": nw}))
' "$S" "$U" "$A1" "$A2" "$P1" "$P2" "$T1" "$T2" "$MEM" "$L1" "$L2" "$(ncpus "$(docker inspect -f '{{.HostConfig.CpusetCpus}}' msc-lg)")" "$TMP/p1" "$TMP/p2" "$THINK_SCALE" "$MEASURE" "${VARIANT:-baseline}" "${APP_ENV:-}" "$WORKERS"
