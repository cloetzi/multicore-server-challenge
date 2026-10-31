# Measurement only, off unless RAGE_STATS=1: every RAGE_STATS_EVERY seconds (default 10) each worker appends its GC
# and YJIT counters to /tmp/rage-stats-<pid>.jsonl, so GC time, GC counts and YJIT code memory can be compared over
# a load test's measured window.
if ENV["RAGE_STATS"] == "1"
  require "json"

  GC_KEYS = %i[count time marking_time sweeping_time minor_gc_count major_gc_count heap_live_slots heap_available_slots
               total_allocated_objects malloc_increase_bytes_limit oldmalloc_increase_bytes_limit].freeze
  YJIT_KEYS = %i[code_region_size inline_code_size outlined_code_size freed_code_size code_gc_count yjit_alloc_size
                 compiled_iseq_count compiled_block_count invalidation_count].freeze

  Iodine.on_state(:on_start) do
    path = "/tmp/rage-stats-#{Process.pid}.jsonl"
    Iodine.run_every(Integer(ENV.fetch("RAGE_STATS_EVERY", "10")) * 1000) do
      yjit = RubyVM::YJIT.enabled? ? RubyVM::YJIT.runtime_stats.slice(*YJIT_KEYS) : {}
      line = { t: Process.clock_gettime(Process::CLOCK_REALTIME), pid: Process.pid,
               cpu: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID), gc: GC.stat.slice(*GC_KEYS),
               last_major_by: GC.latest_gc_info(:major_by), yjit: }
      File.write(path, JSON.generate(line) << "\n", mode: "a")
    end
  end
end
