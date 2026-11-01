# Shared settings for setup.sh / run.sh / sweep.sh. Override any of these in the environment.
#
# The benchmark box is 8 vCPUs shared by the app and Postgres, with the load generators on other machines.
# Defaults mirror that on one big Linux host: app + Postgres share CPUs 0-7, loadgen gets 8-15.
# On a smaller host, shrink these (e.g. APP_CPUS=0-3 PG_CPUS=0-3 LG_CPUS=4-7) and expect lower numbers.
: "${APP_CPUS:=0-7}"          # cpuset of the app server container
: "${PG_CPUS:=$APP_CPUS}"     # cpuset of Postgres (default: shares the app's CPUs, like the real box)
: "${LG_CPUS:=8-15}"          # cpuset of the load generator container (keep it disjoint from the two above)
: "${SEED:=full}"             # full (500k articles, ~2.4 GB, what the benchmark uses) or dev (2%, quick)
: "${PGPORT:=5433}"           # Postgres listens here on the host network (5433 to stay clear of a local Postgres)
: "${THINK_SCALE:=1}"         # 1 = the real workload; <1 = more requests per user (testing only, fewer sockets)
: "${RAMP:=60}" ; : "${MEASURE:=60}" ; : "${TAIL:=15}"   # seconds; same as the scorer's 2-minute probes
: "${SUBMISSIONS:=ruby-rails-bottrall ruby-rage-cloetzi ruby-rage-sequel-cloetzi}"
: "${IMAGE:=msc-compare}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PGHOST=127.0.0.1 PGPORT PGUSER=postgres PGPASSWORD=postgres
if [ "$SEED" = full ]; then TEMPLATE=conduit_seed ARTICLES=500000; else TEMPLATE=conduit_dev ARTICLES=10000; fi
# number of CPUs in a cpuset list like "0-7" or "0-3,8-11"
ncpus() { python3 -c 'import sys; print(sum((lambda a: int(a[-1]) - int(a[0]) + 1)(p.split("-")) for p in sys.argv[1].split(",")))' "$1"; }
WORKERS="${WORKERS:-$(ncpus "$APP_CPUS")}"
