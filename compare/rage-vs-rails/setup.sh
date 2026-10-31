#!/usr/bin/env bash
# One-time setup on a Linux host with Docker: builds the tools image, starts Postgres 18 (tuned by box/pg-conf.sh
# for an 8-core/16 GB box), the app container and the loadgen container (all on the host network), builds the seed
# and both submissions, and runs the conformance suite on each.
#
#   bash compare/rage-vs-rails/setup.sh            # SEED=full by default; SEED=dev for a quick try
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$REPO"

echo "== host: $(nproc) CPUs, $(awk '/MemTotal/{printf "%.0f GB", $2/1048576}' /proc/meminfo); app=$APP_CPUS pg=$PG_CPUS lg=$LG_CPUS seed=$SEED"
if [ "$(id -u)" = 0 ]; then sysctl -q -p box/sysctl.conf || true
else echo "(not root: apply box/sysctl.conf yourself if tens of thousands of connections fail: sudo sysctl -p box/sysctl.conf)"; fi

docker build -t "$IMAGE" -f compare/rage-vs-rails/Dockerfile submissions/ruby-rage-cloetzi

docker rm -f msc-pg msc-app msc-lg >/dev/null 2>&1 || true
# Postgres settings the box uses, computed for 8 cores (pg-conf.sh reads nproc, which honours the cpuset)
PG_ARGS=$(docker run --rm --cpuset-cpus 0-7 -v "$REPO/box:/box:ro" "$IMAGE" bash /box/pg-conf.sh --print \
  | grep -v '^#' | grep '=' | sed 's/ *= */=/' | sed 's/^/-c /' | tr '\n' ' ')
# huge_pages=try is fine; the container just won't get them
docker run -d --name msc-pg --network host --cpuset-cpus "$PG_CPUS" --shm-size 4g \
  -e POSTGRES_PASSWORD=postgres postgres:18 -c port="$PGPORT" $PG_ARGS >/dev/null
for c in msc-app:"$APP_CPUS" msc-lg:"$LG_CPUS"; do
  docker run -d --name "${c%%:*}" --network host --cpuset-cpus "${c#*:}" --ulimit nofile=200000:200000 \
    -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -v "$REPO:/src:ro" "$IMAGE" sleep infinity >/dev/null
done
until docker exec msc-pg pg_isready -q -p "$PGPORT"; do sleep 1; done

sync_repo='rsync -a --exclude vendor --exclude .bundle --exclude "seed/data-*" /src/ /work/'
docker exec msc-lg bash -c "$sync_repo && cd /work/bench && go build -o /usr/local/bin/loadgen ./cmd/loadgen"
echo "== seed ($SEED)"
docker exec msc-lg bash -c "cd /work && bash seed/make-seed.sh $([ "$SEED" = dev ] && echo --dev)"

for s in $SUBMISSIONS; do
  echo "== build + conformance: $s"
  docker exec msc-app bash -c "$sync_repo && cd /work && TEMPLATE=$TEMPLATE bash test/run.sh submissions/$s 2>&1 | tail -3"
done
echo "== ready: bash compare/rage-vs-rails/sweep.sh"
