#!/usr/bin/env bash
# A/B runs of one submission at one load, alternating the variants each round so drift hits them alike. Appends
# run.sh's JSON (with phase "ab", the round as rep, a timestamp) to OUT.
#   USERS=42000 ROUNDS=2 bash compare/rage-vs-rails/ab.sh ruby-rage-cloetzi "noreuseport:RAGE_REUSEPORT=0" "reuseport:RAGE_REUSEPORT=1"
# Each variant is name:ENV (ENV = space-separated K=V passed to the server). RAMP/MEASURE as in run.sh (default 60/90).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S=$1; shift
: "${USERS:=42000}" ; : "${ROUNDS:=2}" ; : "${OUT:=$HERE/results-linux.jsonl}"
export RAMP="${RAMP:-60}" MEASURE="${MEASURE:-90}"
for round in $(seq "$ROUNDS"); do
  if [ $((round % 2)) = 1 ]; then order=("$@"); else mapfile -t order < <(printf "%s\n" "$@" | tac); fi
  for v in "${order[@]}"; do
    line=$(VARIANT="${v%%:*}" APP_ENV="${v#*:}" bash "$HERE/run.sh" "$S" "$USERS" 2>/dev/null | tail -1)
    python3 -c 'import json, sys, time; r = json.loads(sys.argv[1]); r.update(phase="ab", rep=int(sys.argv[2]), ts=time.strftime("%Y-%m-%dT%H:%M:%S")); print(json.dumps(r))' \
      "$line" "$round" | tee -a "$OUT"
  done
done
