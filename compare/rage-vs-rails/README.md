# Rage vs Rails comparison harness

Not a submission. These scripts benchmark `submissions/ruby-rails-bottrall` (Rails 8.1 + Falcon) against
`submissions/ruby-rage-cloetzi` (the same app on Rage + Iodine) under identical conditions on one Linux host
with Docker. The results are summarized in `submissions/ruby-rage-cloetzi/README.md` ("Local comparison").

```bash
sudo bash compare/rage-vs-rails/setup.sh     # once: image, Postgres 18, seed, build + conformance for both (~6 min on a fast box)
sudo python3 compare/rage-vs-rails/search.py # the scorer's limit search for both servers, alternating; appends to results-linux.jsonl
sudo bash compare/rage-vs-rails/run.sh ruby-rage-cloetzi 20000   # one run, prints a JSON line
python3 compare/rage-vs-rails/table.py compare/rage-vs-rails/results-linux.jsonl
```

Three containers, all on the host network:

| container | what | cpuset (default) |
|---|---|---|
| `msc-pg` | `postgres:18`, configured with `box/pg-conf.sh` values for 8 cores / 16 GB, port `PGPORT` (5433) | `PG_CPUS` = `APP_CPUS` |
| `msc-app` | the server under test, one worker per app CPU | `APP_CPUS` = `0-7` |
| `msc-lg` | `loadgen`, `psql`, the seed | `LG_CPUS` = `8-15` |

By default the app and Postgres share 8 CPUs, as on the benchmark box. On a host with SMT, give the load generator
CPUs that aren't the app cores' siblings (on a 16-core / 32-thread box: `LG_CPUS=8-15,24-31`, leaving 16-23 idle).
Set the cpusets when running `setup.sh`: they are fixed when the containers are created.

The containers work on a copy of the repo (`/work`, rsynced from the read-only `/src` mount by `setup.sh`). After
changing a submission, copy it in again and rerun conformance:

```bash
sudo docker exec msc-app bash -c 'rsync -a --exclude vendor --exclude .bundle --exclude "seed/data-*" /src/ /work/ && cd /work && TEMPLATE=conduit_seed bash test/run.sh submissions/ruby-rage-cloetzi'
```

rsync doesn't delete, so remove files you deleted from `/work` by hand.

## Scripts

| script | what |
|---|---|
| `setup.sh` | builds the image, starts the containers, builds the seed and both submissions, runs conformance |
| `run.sh <sub> <users>` | one measured run: fresh database copy, server start, short warm-up, then ramp + measure + tail. Prints throughput, latency, verdict, app/Postgres/loadgen CPU from each container's cgroup, app memory, and each app process's CPU over the window (`worker_cores`) |
| `search.py` | the scorer's procedure (`bench/cmd/loadgen/search.go`): probes doubling on the 500·2ⁿ grid until one fails, bisecting to 5% with the same rounding, then holds stepping down 5%, then repeats of the key runs. The servers run in lockstep, alternating. Runs already in the results file are reused, so an interrupted search resumes |
| `ab.sh <sub> name:ENV ...` | A/B runs of one server at one load, alternating the variants each round |
| `sweep.sh` | a fixed list of loads for both servers, alternating |
| `table.py <results>` | the results as a markdown table |
| `stats.py <dump> <results>` | GC and YJIT per worker over each run's window, from the `RAGE_STATS=1` dump (below) |
| `json_bench.rb` | Active Support's `to_json` against `JSON.generate` on payloads shaped like the API's |

Settings (environment, see `config.sh` and the top of each script): `APP_CPUS`, `PG_CPUS`, `LG_CPUS`, `WORKERS`,
`SEED=full|dev`, `THINK_SCALE` (1 = real workload), `RAMP`/`MEASURE`/`TAIL`, `SUBMISSIONS`. `search.py` also takes
`START`, `STEP` (climb by N users instead of doubling), `PROBE_MEASURE`, `HOLD_MEASURE`, `HOLD` (servers to hold,
`none` for probes only) and `REPEATS`. `APP_ENV="K=V ..."` is passed to the server, and `VARIANT` labels the
results so runs of different code or settings don't mix. Run them as root (or with sudo) for Docker access.

## Measuring inside Rage

`initializers/` holds initializers for the Rage submission, used for the measurements. Copy one into its
`config/initializers/` to use it:

- `stats.rb`, `RAGE_STATS=1`: every 10 s each worker appends `GC.stat` and YJIT runtime counters to
  `/tmp/rage-stats-<pid>.jsonl`. Copy them out with `docker exec msc-app bash -c 'cat /tmp/rage-stats-*.jsonl'`
  and summarize with `stats.py`.
- `reuseport.rb` (on unless `RAGE_REUSEPORT=0`): the `SO_REUSEPORT` experiment. Each Iodine worker swaps the shared
  listening socket for its own, so the kernel spreads connections evenly. It balanced the workers but cost CPU per
  request and didn't raise the limit (see the submission README), so the submission doesn't use it.
- `profile.rb`, `RAGE_PROFILE=1`: one worker runs stackprof in CPU mode for `RAGE_PROFILE_SECS` from
  `RAGE_PROFILE_DELAY` seconds after it starts, and writes a text report and collapsed stacks to `/tmp`. stackprof
  is installed apart from the bundle:
  `docker exec msc-app bash -c 'PATH=/opt/ruby-4.0.9/bin:$PATH gem install stackprof --install-dir /opt/profgems'`.

```bash
sudo VARIANT=profile APP_ENV="RAGE_PROFILE=1 RAGE_PROFILE_DELAY=110 RAGE_PROFILE_SECS=60" bash compare/rage-vs-rails/run.sh ruby-rage-cloetzi 40000
```

## Notes

- Apply `box/sysctl.conf` on the host (`setup.sh` does it when run as root; it lasts until reboot). Tens of
  thousands of connections need it. Users are spread over several 127.0.0.x addresses to avoid running out of
  ephemeral ports.
- The host needs Docker, python3 and bash. The containers bring everything else.
- `lg_limited` in a result means the load generator, not the server, was the limit. Give `LG_CPUS` more cores.
  Besides loadgen's own checks (which read the whole host's `/proc/stat`, so they can't see the container's
  cpuset), `run.sh` flags a run whose loadgen container used more than 75% of its CPUs.
- Don't edit `run.sh` while a run is going: bash reads scripts as it runs them.
- `results-linux.jsonl`: the runs behind the README's Linux table (variant `baseline`), the `SO_REUSEPORT`
  experiment (`reuseport+json`), the profiling run and the final 5-minute hold (`final`).
  `results-mac.jsonl`: the first, noisy runs from Docker Desktop on an arm64 Mac (4 app cores, dev seed,
  think-scale 0.1).
