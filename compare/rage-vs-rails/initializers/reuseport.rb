# Even out connections across the Iodine workers.
#
# Iodine's master opens one listening socket and forks the workers, which all poll it. Every new connection wakes
# every worker and the first to run takes it, so the same few workers win most of the time; with keep-alive, each
# user then stays on the worker that accepted it. Measured on 8 workers: the busiest did 2-3.5x the average
# worker's work, and once it ran out of CPU its users waited seconds while other workers had time to spare.
#
# Iodine has no option for this, but each worker runs :enter_child right after forking, before it adds the
# listening socket to its own epoll. There, swap the inherited socket (same fd number, so Iodine's bookkeeping is
# untouched) for a new SO_REUSEPORT socket on the same address. The kernel then spreads new connections evenly over
# the workers' sockets by hashing their addresses. The shared socket is shut down first: nothing would accept from
# it any more, and as it isn't SO_REUSEPORT it would block the bind. The master notes which fds are its listening
# TCP sockets before forking (:pre_start), as once the first worker has shut one down it no longer looks like one.
# RAGE_REUSEPORT=0 turns this off.
require "socket"
require "fcntl"

if RUBY_PLATFORM.include?("linux") && Socket.const_defined?(:SO_REUSEPORT) && ENV["RAGE_REUSEPORT"] != "0"
  listeners = {} # fd => local Addrinfo, filled in by the master

  Iodine.on_state(:pre_start) do
    Dir.children("/proc/self/fd").each do |name|
      fd = name.to_i
      next unless (File.readlink("/proc/self/fd/#{fd}") rescue "").start_with?("socket:")

      sock = Socket.for_fd(fd)
      sock.autoclose = false
      addr = sock.local_address
      listeners[fd] = addr if (addr.ipv4? || addr.ipv6?) && sock.getsockopt(:SOCKET, :ACCEPTCONN).int == 1
    rescue SystemCallError, IOError, SocketError
      next
    end
  end

  Iodine.on_state(:enter_child) do
    listeners.each do |fd, addr|
      shared = Socket.for_fd(fd)
      shared.autoclose = false
      own = Socket.new(addr.afamily, :STREAM, 0)
      own.setsockopt(:SOCKET, :REUSEADDR, true)
      own.setsockopt(:SOCKET, :REUSEPORT, true)
      own.fcntl(Fcntl::F_SETFL, own.fcntl(Fcntl::F_GETFL) | Fcntl::O_NONBLOCK)
      begin
        shared.shutdown(:RDWR) # stops it listening in every process; ENOTCONN once another worker has done it
      rescue Errno::ENOTCONN
      end
      own.bind(addr)
      own.listen(Socket::SOMAXCONN) # what Iodine uses
      shared.reopen(own) # dup2: the fd Iodine knows now refers to this worker's own socket
      own.close
    rescue SystemCallError, IOError, SocketError => e
      warn "reuseport: fd #{fd}: #{e.class}: #{e.message}"
    end
  end
end
