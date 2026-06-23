import Foundation
import os

/// Receives sound-play commands streamed from the server on a dedicated UDP
/// channel and forwards them to a `SoundPlayer`.
///
/// Each datagram is `[RTHeader | SoundCommand]` (the server sends through the
/// same UDPSender6 used for video, which prepends the header). Commands are
/// re-sent for reliability — both back-to-back and on a server heartbeat — so
/// we dedup by the monotonically increasing `seq`.
final class SoundCommandReceiver {
    private var socketFD: Int32 = -1
    // Cross-thread shutdown flag (written by stop() on the main thread, read by
    // the receive thread); a lock gives it a defined happens-before edge.
    private let running = OSAllocatedUnfairLock(initialState: false)
    private var thread: Thread?
    private var player: SoundPlayer?

    // Dedup: seqs already applied. `seq` only increases, so anything <= the
    // high-water mark is a resend; a small recent set also tolerates reordering.
    private var seen = Set<UInt32>()
    private var highSeq: UInt32 = 0

    init() {}
    deinit { stop() }

    func start(player: SoundPlayer, port: UInt16 = 50002) {
        self.player = player

        socketFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            print("SoundCommandReceiver: socket creation failed errno=\(errno)")
            return
        }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(port).bigEndian
        addr.sin6_addr = in6addr_any

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            print("SoundCommandReceiver: bind failed errno=\(errno)")
            close(socketFD)
            socketFD = -1
            return
        }

        running.withLock { $0 = true }
        let t = Thread { [weak self] in self?.receiveLoop() }
        t.name = "SoundCommandReceiver"
        t.start()
        thread = t
        print("SoundCommandReceiver: listening for sound commands on [::]:\(port)")
    }

    func stop() {
        running.withLock { $0 = false }
        // Capture and clear the fd, then shutdown() to unblock the parked
        // recvfrom (close() alone does NOT reliably wake a blocked recvfrom on
        // Darwin). The receive thread captured its own fd copy, so it never
        // touches a recycled descriptor.
        let fd = socketFD
        socketFD = -1
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func receiveLoop() {
        let headerSize = MemoryLayout<RTHeader>.size
        let cmdSize = MemoryLayout<SoundCommand>.size
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let fd = socketFD   // stable for this thread's lifetime

        while running.withLock({ $0 }) {
            let n = recvfrom(fd, &buffer, bufferSize, 0, nil, nil)
            if n <= 0 {
                // stop() shut the socket down -> recvfrom returns; bail cleanly.
                if !running.withLock({ $0 }) { break }
                if n < 0 {
                    let e = errno
                    if e != EAGAIN && e != EINTR {
                        print("SoundCommandReceiver: recvfrom failed errno=\(e)")
                    }
                }
                continue
            }
            guard n >= headerSize + cmdSize else {
                print("SoundCommandReceiver: short datagram n=\(n) (need \(headerSize + cmdSize))")
                continue
            }

            let cmd = buffer.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: headerSize, as: SoundCommand.self)
            }

            if alreadySeen(cmd.seq) { continue }
            player?.handle(cmd)
        }
    }

    /// True if this seq was already applied (a resend); otherwise records it.
    private func alreadySeen(_ seq: UInt32) -> Bool {
        if seen.contains(seq) { return true }
        seen.insert(seq)
        if seq > highSeq { highSeq = seq }
        // Keep the set bounded: drop seqs well below the high-water mark.
        if seen.count > 512 {
            let cutoff = highSeq > 256 ? highSeq - 256 : 0
            seen = seen.filter { $0 >= cutoff }
        }
        return false
    }
}
