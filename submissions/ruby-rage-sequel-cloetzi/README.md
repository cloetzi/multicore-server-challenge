# Ruby + Rage + Sequel + YJIT

Front: direct

[`ruby-rage-cloetzi`](../ruby-rage-cloetzi) (the Rails app ported to Rage) with Active Record replaced by
[Sequel](https://sequel.jeremyevans.net), to see what the ORM costs. It's still an ORM app as you would run it in
production: Sequel models with associations and validations, model datasets in place of scopes, and Sequel's own
prepared statements. There's no hand-written result parsing. The controllers, routes, serializer, JWT code and
request validation are the Rage version's, changed only where Active Record's API was used. The SQL sent to
Postgres is the same, statement for statement.

## Versions

| | |
|---|---|
| Ruby | 4.0.9, built from source by `install.sh` with YJIT and jemalloc (same `install.sh` as the Rage and Rails versions) |
| Framework | rage-rb 1.29.0 (standalone mode) |
| Server | rage-iodine 6.4.0 (facil.io, epoll), started by `rage s` |
| ORM | Sequel 5.109.0, with sequel_pg 1.20.0 (Sequel's C extension that builds rows and parses types in C) |
| Postgres driver | pg 1.7.0 |
| bcrypt | bcrypt 3.1.22, cost 10 |
| JWT | jwt 3.3.0 |
| JSON | json 3.1.0 (the version the Active Record version gets through Active Support) |

Gems are pinned in `Gemfile.lock`, and `build.sh` compiles the native ones from source. Neither Active Record nor
Active Support is loaded.

## How it runs

The same as the Rage version: `rage s` boots the app in the master, then Iodine forks one worker per core, each
a single thread with an event loop and a fiber per request.

- **Connections.** Sequel's `fiber_concurrency` extension keys the connection pool by fiber rather than thread.
  The pool (`timed_queue`, Sequel's default on Ruby >= 3.2) waits on a `Thread::Queue`, which yields to Rage's
  fiber scheduler, and pg's async API yields while Postgres works. A request holds a connection only while a query
  or transaction runs. Each worker gets `88 / workers` connections, as before.
- **Prepared statements.** Every hot read is built once at boot from model datasets and prepared with
  `Dataset#prepare`, so each one has a name (`article_by_slug`, `feed_page`, `comment_thread`, ...). The viewer,
  slug, limit and offset are `:$placeholders`, and each connection prepares a statement the first time it runs it.
  Writes use Sequel's normal dataset and model methods; model inserts and updates go through the
  `prepared_statements` plugin.
- **Forking.** The master reads the table schemas when it loads the models and then drops its connections
  (`Iodine.on_state(:pre_start) { DB.disconnect }`), so workers never share a socket.
- **Saves.** `Sequel::Model.use_transactions = false`: a single INSERT or UPDATE is atomic anyway, and the
  BEGIN/COMMIT around every save only added two round trips. `Article.publish` opens its own transaction.

## Code

```
app/models/            Sequel models; each one's prepared statements are constants next to the dataset they come from
app/models/article_listing.rb   the list endpoints: a prepared page and a prepared capped count per list
app/controllers/       the Rage version's controllers, calling the models above
app/concerns/          token auth and request input (no ActiveSupport::Concern)
app/serializers/       ConduitJson, reading record[:column]
config/initializers/sequel.rb   connection, pool, extensions, model defaults
config/routes.rb       nested routes spelled out (see below)
```

## Differences from the Active Record version

- **Routes.** Without Active Support's inflector, Rage's fallback singularizes `articles` to `articl` and
  `profiles` to `profil`, so nested `resources` would hand controllers `:articl_slug`. The nested routes are
  written out with `scope path: "articles/:article_slug"`, and the paths are the same as before.
- **Passwords.** `has_secure_password` is replaced by a `password=` that hashes with bcrypt on a short-lived
  thread, as before. It also keeps the 72-byte limit (a longer password is a 422), and `authenticate_by` still runs
  bcrypt once when the email doesn't exist, as Active Record does.
- **No-op updates.** Sequel's `update` returns nil when nothing changed. `User#revise` treats that as success, as
  Active Record does.
- **Errors.** `Sequel::NoMatchingRow` is a 404 and `Sequel::UniqueConstraintViolation` a 422.
- **Comment insert** is one statement (`INSERT ... RETURNING`), without the BEGIN/COMMIT Active Record wrapped it in.
- `RAGE_LOG_LEVEL=debug` logs every query, through Sequel's logger this time.

## Rules

- Nothing is cached between requests. Prepared statements cache plans, not data.
- Passwords are bcrypt cost 10 and every login checks the stored hash.
- Every request verifies the token's HS256 signature and `exp` with the jwt gem.
- Writes are committed before the response goes out. Creating an article is one transaction.
- Passes `test/run.sh` (197/197) on the dev seed and the full seed.

## Local measurements (preliminary)

These were measured on a small laptop (i5-1030NG7, 4 cores / 8 threads, `powersave` governor), not the benchmark
box, so they're only good for comparing the two versions against each other. The real comparison is still to run
on the Docker harness in [`compare/rage-vs-rails`](../../compare/rage-vs-rails).

**Per endpoint, in-process.** Each endpoint's model calls, serializer and `JSON.generate`, 1,500 times on one
connection against the full seed, outside the HTTP server. The third column is the same SQL through raw
`PG::Connection#exec_prepared` with pg's type map, which is the floor without any ORM. All three produce
byte-identical JSON.

| Endpoint | Ruby µs: Active Record | Sequel | raw pg | Postgres µs: AR | Sequel |
|---|--:|--:|--:|--:|--:|
| `GET /api/tags` | 144 | 56 | 54 | 53 | 40 |
| `GET /api/articles/:slug` | 277 | 50 | 47 | 133 | 93 |
| `GET /api/articles/:slug/comments` | 400 | 104 | 62 | 147 | 107 |
| `GET /api/articles` | 724 | 229 | 169 | 880 | 740 |
| `GET /api/articles/feed` | 721 | 222 | 161 | 853 | 587 |
| `GET /api/articles?author` | 684 | 137 | 83 | 393 | 213 |
| `GET /api/articles?tag` | 814 | 242 | 177 | 1,047 | 920 |
| `GET /api/profiles/:username` | 142 | 39 | 19 | 53 | 33 |
| `GET /api/user` | 75 | 26 | 19 | 33 | 67 |

Sequel spends 3-5x less Ruby time than Active Record on the same queries, and comes within 1.0-2x of raw pg.
(`GET /api/user` is the one hot query Sequel doesn't prepare: it's `User[id]`, which Sequel sends as literal SQL.)

**End to end.** 2 workers, a fixed load of about 660 req/s (500 users at think-scale 0.2), full seed, CPU per
request from `/proc` over a 60 s window. These are the means of three rounds, run alternately; all six runs were
within 3%.

| | app CPU / request | Postgres CPU / request |
|---|--:|--:|
| Active Record | 1,183 µs | 655 µs |
| Sequel | 953 µs (−19%) | 920 µs (+40%) |

The app's saving roughly matches the per-endpoint table: weighted by the request mix (the GETs above are 94% of
requests), those code paths cost about 400 µs per request with Active Record, 110 µs with Sequel and 80 µs with
raw pg. That's a saving of about 290 µs, against the 230 µs measured end to end. The rest of the app's CPU is Rage, Iodine, JWT, bcrypt, JSON and the kernel. A
`perf` profile of the Active Record version put about 30% of a worker in bcrypt, the kernel, Iodine, pg and
OpenSSL, none of which this change touches.

The Postgres number is not explained yet. Under the server, both versions send the same statements over the same
wire protocol (checked with libpq's trace) and Sequel's statements re-plan no more often than Active Record's (`pg_prepared_statements`).
Per request they read the same rows and buffers and make the same context switches, with no new connections
during the window. Yet Postgres burns about 35% more CPU time per request, and only with the Sequel app. Pool size,
pool order (FIFO or LIFO), holding one connection per request and the session time zone made no difference; a
single connection per worker brought both versions down to the same ~580 µs. My best guess is the laptop's
frequency scaling, since a lighter app lets the cores clock down and charges Postgres more time for the same work.
The run on the real host should settle it.

## Build and run

```bash
sudo bash install.sh   # once: builds Ruby 4.0.9 into /opt/ruby-4.0.9
bash build.sh          # installs gems into ./vendor/bundle
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`WEB_CONCURRENCY` and `DB_POOL` override the worker count and pool size, `RAGE_LOG_LEVEL=debug` logs every query,
and `NO_SEQUEL_PG=1` runs Sequel without its C extension.
