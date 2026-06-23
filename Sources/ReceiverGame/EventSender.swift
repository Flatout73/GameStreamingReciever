import Foundation

/// Sends input events captured from the user back to the server over IPv6 UDP.
final class EventSender {
    private var socketFD: Int32 = -1
    private var destAddr = sockaddr_in6()
    private var hasDest = false

    init() {}
    
    deinit {
        stop()
    }

    func start(host: String = "::1", port: UInt16 = 50001) {
        socketFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            print("EventSender: socket creation failed errno=\(errno)")
            return
        }

        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(port).bigEndian

        let ok = host.withCString { cstr in
            inet_pton(AF_INET6, cstr, &addr.sin6_addr)
        }
        guard ok == 1 else {
            print("EventSender: inet_pton failed for \(host)")
            close(socketFD)
            socketFD = -1
            return
        }

        destAddr = addr
        hasDest = true
        print("EventSender: forwarding input events to [\(host)]:\(port)")
    }

    func send(_ event: NetInputEvent) {
        guard socketFD >= 0, hasDest else { return }
        var ev = event
        var addr = destAddr
        _ = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                withUnsafeBytes(of: &ev) { bytes in
                    sendto(socketFD,
                           bytes.baseAddress,
                           bytes.count,
                           0,
                           sockaddrPtr,
                           socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    func stop() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        hasDest = false
    }
}
