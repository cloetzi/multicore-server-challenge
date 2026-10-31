# Measurement only, off unless RAGE_PROFILE=1: one worker (the first to claim a lock file) runs stackprof in CPU mode
# from RAGE_PROFILE_DELAY seconds after it starts, for RAGE_PROFILE_SECS seconds, then writes
#   /tmp/rage-profile-<pid>.txt     top frames by own and by total CPU samples
#   /tmp/rage-profile-<pid>.folded  collapsed stacks (for a flame graph)
#   /tmp/rage-profile-<pid>.dump    the raw stackprof result (Marshal)
# stackprof is not in the bundle: install it apart, e.g. `gem install stackprof --install-dir /opt/profgems`, and
# point RAGE_PROFILE_GEMS at that directory (default /opt/profgems).
if ENV["RAGE_PROFILE"] == "1"
  lib = Dir[File.join(ENV.fetch("RAGE_PROFILE_GEMS", "/opt/profgems"), "gems", "stackprof-*", "lib")].max
  raise "RAGE_PROFILE=1 but no stackprof under #{ENV.fetch("RAGE_PROFILE_GEMS", "/opt/profgems")}" unless lib

  $LOAD_PATH.unshift(lib)
  require "stackprof"

  Iodine.on_state(:on_start) do
    lock = File.open("/tmp/rage-profile.lock", File::CREAT | File::WRONLY)
    next unless lock.flock(File::LOCK_EX | File::LOCK_NB) # another worker profiles

    delay = Float(ENV.fetch("RAGE_PROFILE_DELAY", "110"))
    secs = Float(ENV.fetch("RAGE_PROFILE_SECS", "60"))
    Iodine.run_after((delay * 1000).to_i) do
      StackProf.start(mode: :cpu, interval: Integer(ENV.fetch("RAGE_PROFILE_INTERVAL_US", "1000")), raw: true)
      Iodine.run_after((secs * 1000).to_i) do
        StackProf.stop
        result = StackProf.results
        base = "/tmp/rage-profile-#{Process.pid}"
        File.binwrite("#{base}.dump", Marshal.dump(result))
        report = StackProf::Report.new(result)
        File.open("#{base}.txt", "w") do |f|
          f.puts "pid #{Process.pid}: #{result[:samples]} samples, #{result[:gc_samples]} in GC, " \
                 "#{result[:missed_samples]} missed, interval #{result[:interval]} us, #{secs} s"
          f.puts "\n== by own samples"
          report.print_text(false, 60, nil, nil, nil, nil, f)
          f.puts "\n== by total samples (including callees)"
          report.print_text(true, 60, nil, nil, nil, nil, f)
        end
        File.open("#{base}.folded", "w") do |f| # what Report#print_stackcollapse prints, without consuming :raw
          raw, frames, i = result[:raw], result[:frames], 0
          while i < raw.size
            len = raw[i]
            f.puts "#{raw[i + 1, len].map { frames[it][:name] }.join(";")} #{raw[i + 1 + len]}"
            i += len + 2
          end
        end
        lock.close
      end
    end
  end
end
