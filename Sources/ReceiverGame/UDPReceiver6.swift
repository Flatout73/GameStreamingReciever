import Foundation
import Network

class UDPReceiver6 {
    private var socketFD: Int32 = -1
    private var isRunning = false
    private let receiveQueue = DispatchQueue(label: "UDPReceiverQueue")
    
    struct RTHeader {
        var time: Double
        var packetnum: UInt
    }

    /// Callback for when data is received. The data has the RTHeader stripped.
    var onDataReceived: ((Data, RTHeader) -> Void)?

    init() {}

    deinit {
        stop()
    }

    func start(port: UInt16) throws {
        socketFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: "NSPOSIXErrorDomain", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(port).bigEndian
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }

        guard bindResult == 0 else {
            let error = Int(errno)
            close(socketFD)
            socketFD = -1
            throw NSError(domain: "NSPOSIXErrorDomain", code: error, userInfo: [NSLocalizedDescriptionKey: "Failed to bind socket: \(error)"])
        }
        
        // Increase receive buffer size to accommodate large packets
        var rcvbuf: Int32 = 256 * 1024
        setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        isRunning = true

        receiveQueue.async { [weak self] in
            self?.receiveLoop()
        }
    }

    func stop() {
        isRunning = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func receiveLoop() {
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while isRunning {
            var senderAddr = sockaddr_in6()
            var senderAddrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)

            let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { senderPtr in
                senderPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    recvfrom(socketFD, &buffer, bufferSize, 0, sockaddrPtr, &senderAddrLen)
                }
            }

            if bytesRead > 0 {
                let headerSize = MemoryLayout<RTHeader>.size
                if bytesRead >= headerSize {
                    // Extract the header
                    let headerData = Data(buffer[0..<headerSize])
                    let header = headerData.withUnsafeBytes { $0.load(as: RTHeader.self) }

                    // Extract the payload
                    let payloadData = Data(buffer[headerSize..<bytesRead])
                    
                    onDataReceived?(payloadData, header)
                }
            } else if bytesRead < 0 {
                let error = errno
                if error != EAGAIN && error != EINTR {
                    print("UDPReceiver6: recvfrom failed with error \(error)")
                }
            }
        }
    }
}
