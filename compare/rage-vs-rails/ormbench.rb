# Per-endpoint ORM cost, in-process, for the two Rage versions. Run from a submission's folder with its bundle:
#
#   cd submissions/ruby-rage-cloetzi        && DATABASE_URL=... JWT_SECRET=x RAGE_ENV=production bundle exec ruby ../../compare/rage-vs-rails/ormbench.rb ar
#   cd submissions/ruby-rage-sequel-cloetzi && DATABASE_URL=... JWT_SECRET=x RAGE_ENV=production bundle exec ruby ../../compare/rage-vs-rails/ormbench.rb sequel
#   (same folder)                                                                                                   ... ormbench.rb raw
#
# Loads the app (models, serializer) without the HTTP server, then for each endpoint does what its controller action
# does (queries + ConduitJson + JSON.generate) N times (default 2000) on one connection, and prints a JSON line per
# endpoint: Ruby CPU (this process) and Postgres CPU (this connection's backend, read from /proc, so Postgres must run
# on the same host or container) per call, GC time and allocations. "raw" is the Sequel version's SQL through
# PG::Connection#exec_prepared, the floor without an ORM. DUMP=1 prints each endpoint's JSON once instead, to diff the
# variants (they match byte for byte). Use a database copy, not the seed template.
VARIANT = ARGV.fetch(0)
N = Integer(ENV.fetch("N", 2000))
ENV["DB_POOL"] = "1"
require_relative File.join(Dir.pwd, "config/application")

def cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
def backend_ticks(pid) = File.read("/proc/#{pid}/stat").sub(/.*\) /, "").split.values_at(11, 12).sum(&:to_i)

case VARIANT
when "ar"
  conn = ActiveRecord::Base.connection
  backend = conn.select_value("SELECT pg_backend_pid()")
when "sequel", "raw"
  backend = DB.get(Sequel.function(:pg_backend_pid))
end

# Inputs: a fixed pseudo-random sample of real slugs, users, tags (same seed for every variant).
pg_ = PG.connect(ENV.fetch("DATABASE_URL"))
SLUGS = pg_.exec("SELECT slug FROM articles WHERE id % 97 = 0 ORDER BY id DESC LIMIT 500").column_values(0)
VIEWERS = pg_.exec("SELECT id FROM users WHERE id % 13 = 0 ORDER BY id LIMIT 500").column_values(0).map(&:to_i)
AUTHORS = pg_.exec("SELECT username FROM users u WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = u.id) ORDER BY id LIMIT 500").column_values(0)
TAGS = pg_.exec("SELECT name FROM tags ORDER BY id LIMIT 50").column_values(0)
pg_.close

def pick(list, i) = list[(i * 7919) % list.size]

OPS = {}
def op(name, &blk) = OPS[name] = blk

case VARIANT
when "ar"
  op("GET /api/tags") { |_| JSON.generate(tags: Tag.order(:name).pluck(:name)) }
  op("GET /api/articles/:slug") { |i| JSON.generate(article: ConduitJson.article(Article.presented_for(pick(VIEWERS, i), body: true).find_by!(slug: pick(SLUGS, i)))) }
  op("GET /api/articles/:slug/comments") do |i|
    id = Article.where(slug: pick(SLUGS, i)).pick(:id)
    c = Comment.where(article_id: id).thread_for(pick(VIEWERS, i))
    JSON.generate(comments: c.map { ConduitJson.comment(it, author: ConduitJson.author(it)) })
  end
  list = ->(l, v) { JSON.generate(articles: l.articles_for(v).map { ConduitJson.article(it) }, articlesCount: l.total) }
  op("GET /api/articles") { |i| list.(ArticleListing.filtered(limit: 10, offset: 0), pick(VIEWERS, i)) }
  op("GET /api/articles/feed") { |i| v = pick(VIEWERS, i); list.(ArticleListing.feed(v, limit: 10, offset: 0), v) }
  op("GET /api/articles?author") { |i| list.(ArticleListing.filtered(author: pick(AUTHORS, i), limit: 5, offset: 0), pick(VIEWERS, i)) }
  op("GET /api/articles?tag") { |i| list.(ArticleListing.filtered(tag: pick(TAGS, i), limit: 10, offset: 0), pick(VIEWERS, i)) }
  op("GET /api/profiles/:username") do |i|
    u = User.profile_for(pick(VIEWERS, i)).find_by!(username: pick(AUTHORS, i))
    JSON.generate(profile: ConduitJson.profile(u, following: u[:following]))
  end
  op("GET /api/user") { |i| u = User.find_by(id: pick(VIEWERS, i)); JSON.generate(user: ConduitJson.user(u, token: "t")) }
when "sequel"
  op("GET /api/tags") { |_| JSON.generate(tags: Tag.names) }
  op("GET /api/articles/:slug") { |i| JSON.generate(article: ConduitJson.article(Article.presented_by_slug!(pick(VIEWERS, i), pick(SLUGS, i)))) }
  op("GET /api/articles/:slug/comments") do |i|
    c = Comment.thread(pick(VIEWERS, i), Article.id_for!(pick(SLUGS, i)))
    JSON.generate(comments: c.map { ConduitJson.comment(it, author: ConduitJson.author(it)) })
  end
  list = ->((a, t)) { JSON.generate(articles: a.map { ConduitJson.article(it) }, articlesCount: t) }
  op("GET /api/articles") { |i| list.(ArticleListing.filtered(pick(VIEWERS, i), limit: 10, offset: 0)) }
  op("GET /api/articles/feed") { |i| list.(ArticleListing.feed(pick(VIEWERS, i), limit: 10, offset: 0)) }
  op("GET /api/articles?author") { |i| list.(ArticleListing.filtered(pick(VIEWERS, i), author: pick(AUTHORS, i), limit: 5, offset: 0)) }
  op("GET /api/articles?tag") { |i| list.(ArticleListing.filtered(pick(VIEWERS, i), tag: pick(TAGS, i), limit: 10, offset: 0)) }
  op("GET /api/profiles/:username") do |i|
    u = User.profile(pick(VIEWERS, i), pick(AUTHORS, i))
    JSON.generate(profile: ConduitJson.profile(u, following: u[:following]))
  end
  op("GET /api/user") { |i| u = User[pick(VIEWERS, i)]; JSON.generate(user: ConduitJson.user(u, token: "t")) }
when "raw"
  # No ORM: the Sequel version's exact SQL, prepared once on the raw PG::Connection, rows decoded by pg's type map.
  RAW = DB.synchronize { it }
  RAW.type_map_for_results = PG::BasicTypeMapForResults.new(RAW)
  RAW.type_map_for_queries = PG::BasicTypeMapForQueries.new(RAW)
  { tag_names: Tag::NAMES, article_by_slug: Article::BY_SLUG, article_id_by_slug: Article::ID_BY_SLUG,
    comment_thread: Comment::THREAD, all_page: ArticleListing::EVERYTHING.page, all_count: ArticleListing::EVERYTHING.count,
    feed_page: ArticleListing::FEED.page, feed_count: ArticleListing::FEED.count,
    author_page: ArticleListing::BY_AUTHOR.page, author_count: ArticleListing::BY_AUTHOR.count,
    tag_page: ArticleListing::TAGGED.page, tag_count: ArticleListing::TAGGED.count, user_profile: User::PROFILE }
    .each { |name, ps| RAW.prepare("raw_#{name}", ps.prepared_sql) }
  RAW.prepare("raw_user", 'SELECT * FROM "users" WHERE "id" = $1')
  # Sequel numbers placeholders in order of first appearance; these are the argument orders of the statements above.
  x = ->(name, *args) { RAW.exec_prepared("raw_#{name}", args) }
  ts = ->(t) { t.utc.iso8601(3) }
  art = ->(r) {
    j = { slug: r["slug"], title: r["title"], description: r["description"], tagList: r["tag_list"],
          createdAt: ts.(r["created_at"]), updatedAt: ts.(r["updated_at"]), favorited: r["favorited"],
          favoritesCount: r["favorites_count"],
          author: { username: r["author_username"], bio: r["author_bio"], image: r["author_image"], following: r["following"] } }
    r.key?("body") ? j.merge(body: r["body"]) : j
  }
  op("GET /api/tags") { |_| JSON.generate(tags: x.(:tag_names).column_values(0)) }
  op("GET /api/articles/:slug") { |i| JSON.generate(article: art.(x.(:article_by_slug, pick(VIEWERS, i), pick(SLUGS, i)).first)) }
  op("GET /api/articles/:slug/comments") do |i|
    id = x.(:article_id_by_slug, pick(SLUGS, i)).getvalue(0, 0)
    rows = x.(:comment_thread, pick(VIEWERS, i), id)
    JSON.generate(comments: rows.map { |r|
      { id: r["id"], createdAt: ts.(r["created_at"]), updatedAt: ts.(r["updated_at"]), body: r["body"],
        author: { username: r["author_username"], bio: r["author_bio"], image: r["author_image"], following: r["following"] } } })
  end
  op("GET /api/articles") { |i| JSON.generate(articles: x.(:all_page, pick(VIEWERS, i), 10, 0).map(&art), articlesCount: x.(:all_count).getvalue(0, 0)) }
  op("GET /api/articles/feed") do |i|
    v = pick(VIEWERS, i)
    JSON.generate(articles: x.(:feed_page, v, 10, 10, 0).map(&art), articlesCount: x.(:feed_count, v).getvalue(0, 0))
  end
  op("GET /api/articles?author") do |i|
    a = pick(AUTHORS, i)
    JSON.generate(articles: x.(:author_page, pick(VIEWERS, i), a, 5, 0).map(&art), articlesCount: x.(:author_count, a).getvalue(0, 0))
  end
  op("GET /api/articles?tag") do |i|
    t = pick(TAGS, i)
    JSON.generate(articles: x.(:tag_page, pick(VIEWERS, i), t, 10, 0).map(&art), articlesCount: x.(:tag_count, t).getvalue(0, 0))
  end
  op("GET /api/profiles/:username") do |i|
    r = x.(:user_profile, pick(VIEWERS, i), pick(AUTHORS, i)).first
    JSON.generate(profile: { username: r["username"], bio: r["bio"], image: r["image"], following: r["following"] })
  end
  op("GET /api/user") do |i|
    r = x.(:user, pick(VIEWERS, i)).first
    JSON.generate(user: { email: r["email"], token: "t", username: r["username"], bio: r["bio"], image: r["image"] })
  end
end

if ENV["DUMP"] # print each op's JSON once, to diff the variants' output
  OPS.each { |name, blk| puts "#{name}\t#{blk.(3)}" }
  exit
end

RubyVM::YJIT.enable
OPS.each { |_, blk| 300.times { blk.(it) } } # warm up: YJIT, prepared statements, Postgres caches
GC.start
puts({ variant: VARIANT, n: N }.to_json)
OPS.each do |name, blk|
  GC.start
  c0 = cpu; b0 = backend_ticks(backend); g0 = GC.stat(:time); a0 = GC.stat(:total_allocated_objects)
  N.times { blk.(it) }
  c1 = cpu; b1 = backend_ticks(backend); g1 = GC.stat(:time); a1 = GC.stat(:total_allocated_objects)
  puts JSON.generate(variant: VARIANT, op: name, ruby_us: ((c1 - c0) / N * 1e6).round(1),
                     pg_us: ((b1 - b0) * 10_000.0 / N).round(1), gc_us: ((g1 - g0) * 1000.0 / N).round(1),
                     allocs: (a1 - a0) / N)
end
