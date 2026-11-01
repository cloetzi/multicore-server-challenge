#!/usr/bin/env python3
"""Finds each server's limit the way the scorer does (bench/cmd/loadgen/search.go), running the two servers in
lockstep so slow drift on the host hits both alike:

  1. 2-minute probes (RAMP=60 MEASURE=60), doubling the users on the scorer's grid (500 * 2^n, from START) until one
     fails, then bisecting to within 5% (rounded to 2 significant digits, like the scorer).
  2. 5-minute holds (MEASURE=300) from the highest passing probe, stepping down 5% until one passes = the limit.
  3. Repeats: the highest passing and lowest failing probe once more, and the passing hold once more.

Every run appends one JSON line (run.sh's output plus "phase") to OUT. Runs already in OUT are reused, so an
interrupted search picks up where it stopped. A loadgen-limited run stops that server's search (give it more CPUs).

  sudo python3 compare/rage-vs-rails/search.py          # START=4000 OUT=compare/rage-vs-rails/results-linux.jsonl

Settings (environment): START, STEP (0 = double like the scorer; N = climb by N users instead), PROBE_RAMP (60), PROBE_MEASURE (60), HOLD_MEASURE (300), HOLD (servers to hold:
default all, "none" = probes only), REPEATS (1 = repeat the key runs, 0 = don't), SUBMISSIONS, VARIANT (a label for
the code or settings under test; results of other variants are ignored) and APP_ENV (passed to the server by run.sh).
  PROBE_MEASURE=90 HOLD=ruby-rage-cloetzi REPEATS=0 sudo -E python3 compare/rage-vs-rails/search.py
"""
import json, math, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("OUT", os.path.join(HERE, "results-linux.jsonl"))
START = int(os.environ.get("START", "4000"))
STEP = int(os.environ.get("STEP", "0"))  # 0 = double (the scorer); else climb from START by STEP until a fail
SUBS = os.environ.get("SUBMISSIONS", "ruby-rails-bottrall ruby-rage-cloetzi ruby-rage-sequel-cloetzi").split()
RES = 0.05
PROBE_RAMP = int(os.environ.get("PROBE_RAMP", "60"))
PROBE_MEASURE = int(os.environ.get("PROBE_MEASURE", "60"))
HOLD_MEASURE = int(os.environ.get("HOLD_MEASURE", "300"))
HOLD = os.environ.get("HOLD", " ".join(SUBS)).replace("none", "").split()
REPEATS = os.environ.get("REPEATS", "1") == "1"


def nice(x):  # search.go nice(): 2 significant digits, at least 10s
    if x < 10:
        return max(1, round(x))
    step = max(10 ** (math.floor(math.log10(x)) - 1), 10)
    return int(round(x / step) * step)


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


VARIANT = os.environ.get("VARIANT", "baseline")  # run.sh labels results with it; APP_ENV reaches the server
done = {}  # (phase, sub, users, measure_s, rep, variant) -> result
if os.path.exists(OUT):
    for line in open(OUT):
        if line.startswith("{"):
            r = json.loads(line)
            if "phase" in r:
                done[(r["phase"], r["sub"], r["users"], r.get("measure_s"), r.get("rep", 1), r.get("variant", "baseline"))] = r


def run(phase, sub, users, rep=1):
    measure = HOLD_MEASURE if phase == "hold" else PROBE_MEASURE
    key = (phase, sub, users, measure, rep, VARIANT)
    if key in done:
        r = done[key]
        log(f"{phase:6} {sub:20} {users:6}  (cached) {verdict(r)}")
        return r
    env = dict(os.environ, RAMP=str(60 if phase == "hold" else PROBE_RAMP), MEASURE=str(measure), TAIL="15")
    for attempt in (1, 2):
        log(f"{phase:6} {sub:20} {users:6}  running ({env['RAMP']}s ramp + {measure}s measured)")
        p = subprocess.run(["bash", os.path.join(HERE, "run.sh"), sub, str(users)], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        lines = [l for l in p.stdout.splitlines() if l.startswith("{")]
        if p.returncode == 0 and lines:
            break
        log(f"run.sh failed (exit {p.returncode}, attempt {attempt}): {p.stderr.strip()[-800:]}")
        if attempt == 2:
            sys.exit(1)
    r = json.loads(lines[-1])
    r.update(phase=phase, rep=rep, ts=time.strftime("%Y-%m-%dT%H:%M:%S"))
    with open(OUT, "a") as f:
        f.write(json.dumps(r) + "\n")
    done[key] = r
    log(f"{phase:6} {sub:20} {users:6}  {verdict(r)}")
    return r


def verdict(r):
    v = "PASS" if r["pass"] else "FAIL " + ",".join(r.get("fail_reasons", []))
    if r["lg_limited"]:
        v += "  LOADGEN-LIMITED " + ",".join(r.get("lg_reasons", [])) + f" (lg {r.get('lg_cores')} cores)"
    return (f"{v:40} {r['rps']:6} rps  p50 {r['p50']:7}  p95 {r['p95']:7}  p99 {r['p99']:7}  err {r['err%']}%  "
            f"app {r['app_cores']} pg {r['pg_cores']} cores  workers max/mean {r.get('worker_max_over_mean')}")


class Search:
    """One server's probe search as a generator of user counts; send() back the pass/fail."""

    def __init__(self, sub):
        self.sub, self.lo, self.hi, self.lg = sub, 0, 0, False

    def steps(self):
        u = START
        while True:  # doubling (or halving if the start already fails)
            r = yield u
            if r["lg_limited"]:
                self.lg = True
                return
            if r["pass"]:
                self.lo = u
                if self.hi:
                    break
                u = u + STEP if STEP else u * 2
            else:
                self.hi = u
                if self.lo or u <= 10:
                    break
                u = max(u - STEP, 1) if STEP else nice(u / 2)
        while self.lo and self.hi and self.hi - self.lo > RES * self.lo:  # bisect
            m = nice((self.lo + self.hi) / 2)
            if m <= self.lo or m >= self.hi:
                break
            r = yield m
            if r["lg_limited"]:
                self.lg = True
                return
            if r["pass"]:
                self.lo = m
            else:
                self.hi = m


def lockstep(searches, phase):
    """Advance every search one run at a time, alternating the servers (and their order) each round."""
    gens = {s.sub: s.steps() for s in searches}
    nxt = {sub: next(g) for sub, g in gens.items()}
    rnd = 0
    while nxt:
        order = sorted(nxt) if rnd % 2 == 0 else sorted(nxt, reverse=True)
        for sub in order:
            r = run(phase, sub, nxt[sub])
            try:
                nxt[sub] = gens[sub].send(r)
            except StopIteration:
                del nxt[sub]
        rnd += 1


def holds(searches):
    """5-minute holds from each server's highest passing probe, stepping down 5% until one passes."""
    state = {s.sub: s.lo for s in searches if s.lo and not s.lg and s.sub in HOLD}
    score = {}
    rnd = 0
    while state:
        order = sorted(state) if rnd % 2 == 0 else sorted(state, reverse=True)
        for sub in order:
            u = state[sub]
            r = run("hold", sub, u)
            if r["lg_limited"]:
                log(f"{sub}: hold at {u} is loadgen-limited, stopping")
                del state[sub]
            elif r["pass"]:
                score[sub] = u
                del state[sub]
            else:
                n = nice(u * (1 - RES))
                state[sub] = n if n < u else u - 1
        rnd += 1
    return score


searches = [Search(s) for s in SUBS]
log(f"probe search from {START} users ({PROBE_RAMP}s ramp + {PROBE_MEASURE}s measured), servers {SUBS}, "
    f"holds ({HOLD_MEASURE}s) for {HOLD or 'none'}, repeats {'on' if REPEATS else 'off'}, variant {VARIANT!r} "
    f"(APP_ENV {os.environ.get('APP_ENV', '')!r}), results -> {OUT}")
lockstep(searches, "probe")
for s in searches:
    log(f"{s.sub}: highest pass {s.lo}, lowest fail {s.hi or 'none'}{'  (stopped: loadgen-limited)' if s.lg else ''}")
score = holds(searches)
for sub in HOLD:
    log(f"{sub}: limit ({HOLD_MEASURE}s hold) {score.get(sub, 'none')}")

# Repeats: do the boundary probes and the passing hold reproduce?
if REPEATS:
    log("repeats")
for rnd, (phase, pick) in enumerate([("probe", lambda s: s.lo), ("probe", lambda s: s.hi), ("hold", lambda s: score.get(s.sub))]):
    for s in (searches if rnd % 2 else searches[::-1]) if REPEATS else []:
        u = pick(s)
        if u and not s.lg:
            run(phase, s.sub, u, rep=2)
log("done")
subprocess.run([sys.executable, os.path.join(HERE, "table.py"), OUT])
