#!/usr/bin/env bash
# Runs every submission at each user count, alternating so slow drift on the host hits both alike, appending JSON
# lines to results.jsonl, then prints a table.
#   USERS="5000 10000 15000 20000 25000" REPEAT=2 bash compare/rage-vs-rails/sweep.sh
set -euo pipefail
source "$(dirname "$0")/config.sh"
: "${USERS:=5000 10000 15000 20000 25000 30000}" ; : "${REPEAT:=1}"
OUT="${OUT:-$(dirname "$0")/results.jsonl}"
for _ in $(seq "$REPEAT"); do for u in $USERS; do for s in $SUBMISSIONS; do
  bash "$(dirname "$0")/run.sh" "$s" "$u" 2>/dev/null | tail -1 | tee -a "$OUT"
done; done; done
python3 "$(dirname "$0")/table.py" "$OUT"
