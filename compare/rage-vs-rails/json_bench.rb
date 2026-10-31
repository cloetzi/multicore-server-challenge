# Micro-benchmark: Active Support's to_json (what Rage's `render json:` calls once Active Record is loaded) against
# JSON.generate, on payloads shaped like the API's responses. Run inside msc-app:
#   cd /work/submissions/ruby-rage-cloetzi && bundle exec ruby /work/compare/rage-vs-rails/json_bench.rb
# (or with any Ruby that has activesupport and json installed)
require "bundler/setup" if ENV["BUNDLE_GEMFILE"]
require "json"
require "active_support"
require "active_support/core_ext/object/json" # what Active Record loads: Object#to_json via Active Support's encoder

def author(i) = { username: "user#{i}", bio: (i.even? ? "I write about things & stuff." : nil), image: "https://example.com/u#{i}.png", following: i % 3 == 0 }

def article(i, body: false)
  json = { slug: "how-to-train-your-dragon-#{i}", title: "How to train your dragon #{i}", description: "Ever wonder how?",
           tagList: %w[dragons training fantasy], createdAt: "2026-10-31T13:14:51.123Z", updatedAt: "2026-10-31T13:14:51.123Z",
           favorited: i.odd?, favoritesCount: i * 7, author: author(i) }
  body ? json.merge(body: "It takes a Jacobian <and> some patience. " * 40) : json
end

PAYLOADS = {
  "article list (20)" => { articles: Array.new(20) { article(it) }, articlesCount: 500_000 },
  "article + body" => { article: article(1, body: true) },
  "profile" => { profile: author(4) },
  "comments (10)" => { comments: Array.new(10) { { id: it, createdAt: "2026-10-31T13:14:51.123Z", updatedAt: "2026-10-31T13:14:51.123Z", body: "Nice one! " * 5, author: author(it) } } },
  "tags" => { tags: Array.new(20) { "tag#{it}" } }
}

def us_per_call(n)
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e6
end

RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled? # the server runs with YJIT
puts "ruby #{RUBY_VERSION} yjit=#{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?}, activesupport #{ActiveSupport.version}, json #{JSON::VERSION}"
PAYLOADS.each do |name, payload|
  as, gen = payload.to_json, JSON.generate(payload)
  raise "#{name}: different JSON values" unless JSON.parse(as) == JSON.parse(gen)
  n = 200_000 / [as.bytesize / 200, 1].max
  2.times { us_per_call(n / 4) { payload.to_json }; us_per_call(n / 4) { JSON.generate(payload) } } # warm-up
  a = us_per_call(n) { payload.to_json }
  g = us_per_call(n) { JSON.generate(payload) }
  printf("%-18s %6d bytes   to_json %7.2f us   JSON.generate %7.2f us   saves %6.2f us (%.0f%%)\n", name, as.bytesize, a, g, a - g, 100 * (a - g) / a)
end
