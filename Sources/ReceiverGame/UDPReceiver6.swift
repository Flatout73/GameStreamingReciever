import Foundation
import Network

struct RTHeader {
    var time: Double
    var packetnum: UInt
}

/// Wire-format report sent back to the sender.
/// Layout (24 bytes, 8-byte alignment) matches C++ side.
struct ReceiverReport {
    var receivedByteRate: Double   // bytes/sec
    var packetLossRate: Double     // 0..1
    var frameRate: Double          // frames/sec
}

struct DecodedFrame {
    let pixels: Data       // RGBA8
    let width: Int32
    let height: Int32
}

/// UDP receiver with a two-thread design:
///  - Thread A (`receiveLoop`): waits on the socket, decodes the frame and
///    enqueues it. A second helper thread sends a receiver report every
///    ~10 s with the byte rate, loss rate and frame rate.
///  - Thread B (the SDL main thread, driven by `onUpdate`) polls
///    `popFrame()` slightly faster than the source frame rate and renders.
class UDPReceiver6 {
    private var socketFD: Int32 = -1
    private var isRunning = false

    private var receiveThread: Thread?
    private var reportThread: Thread?

    // ---- FIFO of decoded frames (Thread A -> Thread B) ----
    private let queueLock = NSLock()
    private var frameQueue: [DecodedFrame] = []
    private let maxQueueSize = 30

    // ---- Decoder (owned by the receive thread) ----
    private var decoder: VideoDecoder?

    // ---- Stats for the periodic receiver report ----
    private let statsLock = NSLock()
    private var bytesReceived: UInt64 = 0
    private var packetsReceived: UInt64 = 0
    private var framesDecoded: UInt64 = 0
    private var maxPacketnum: UInt64 = 0
    private var sawFirstPacket = false

    private var lastReportTime: Date = Date()
    private var lastBytes: UInt64 = 0
    private var lastFrames: UInt64 = 0
    private var lastPackets: UInt64 = 0
    private var lastMaxPacketnum: UInt64 = 0

    // ---- Sender address (captured on first packet, used to send reports) ----
    private let senderAddrLock = NSLock()
    private var senderAddr: sockaddr_in6?
    private var hasSenderAddr = false

    // ---- Most recent computed report (snapshot for the UI) ----
    private let lastReportLock = NSLock()
    private var lastReport: ReceiverReport?
    private var lastReportSentAt: Date?

    private let reportIntervalSeconds: TimeInterval = 10.0

    init() {}

    deinit { stop() }

    func setDecoder(_ d: VideoDecoder) {
        decoder = d
    }

    func start(port: UInt16) throws {
        socketFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: "NSPOSIXErrorDomain", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
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
            throw NSError(domain: "NSPOSIXErrorDomain", code: error,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to bind socket: \(error)"])
        }

        var rcvbuf: Int32 = 256 * 1024
        setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        isRunning = true
        lastReportTime = Date()

        let recvT = Thread { [weak self] in
            self?.receiveLoop()
        }
        recvT.name = "UDPReceiver.ThreadA"
        recvT.start()
        receiveThread = recvT

        let reportT = Thread { [weak self] in
            self?.reportLoop()
        }
        reportT.name = "UDPReceiver.Report"
        reportT.start()
        reportThread = reportT
    }

    func stop() {
        isRunning = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    /// Snapshot of the most recently produced receiver report (for the UI).
    /// Returns nil until the first report has been produced.
    func latestReport() -> (report: ReceiverReport, sentAt: Date)? {
        lastReportLock.lock()
        defer { lastReportLock.unlock() }
        guard let r = lastReport, let t = lastReportSentAt else { return nil }
        return (r, t)
    }

    /// Called by Thread B (SDL main thread).
    func popFrame() -> DecodedFrame? {
        queueLock.lock()
        defer { queueLock.unlock() }
        if frameQueue.isEmpty { return nil }
        return frameQueue.removeFirst()
    }

    // MARK: - Thread A

    private func receiveLoop() {
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while isRunning {
            var from = sockaddr_in6()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in6>.size)

            let bytesRead = withUnsafeMutablePointer(to: &from) { fromPtr in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    recvfrom(socketFD, &buffer, bufferSize, 0, sockaddrPtr, &fromLen)
                }
            }

            if bytesRead <= 0 {
                if bytesRead < 0 {
                    let e = errno
                    if e != EAGAIN && e != EINTR && isRunning {
                        print("UDPReceiver6: recvfrom failed errno=\(e)")
                    }
                }
                continue
            }

            // Remember the sender so we can send reports back to its ephemeral port.
            senderAddrLock.lock()
            senderAddr = from
            hasSenderAddr = true
            senderAddrLock.unlock()

            let headerSize = MemoryLayout<RTHeader>.size
            guard bytesRead >= headerSize else { continue }

            let header = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: RTHeader.self) }
            let payload = Data(buffer[headerSize..<bytesRead])

            // Update receive stats
            statsLock.lock()
            bytesReceived &+= UInt64(bytesRead)
            packetsReceived &+= 1
            let pn = UInt64(header.packetnum)
            if !sawFirstPacket {
                sawFirstPacket = true
                maxPacketnum = pn
                lastMaxPacketnum = pn &- 1   // so the first window counts this packet as expected
            } else if pn > maxPacketnum {
                maxPacketnum = pn
            }
            statsLock.unlock()

            // Decode and enqueue
            guard let decoder = decoder else { continue }
            do {
                if let rgba = try decoder.decode(data: payload) {
                    // decoder reuses its internal RGBA buffer, so copy.
                    let frame = DecodedFrame(pixels: Data(rgba),
                                             width: decoder.width,
                                             height: decoder.height)
                    queueLock.lock()
                    if frameQueue.count >= maxQueueSize {
                        frameQueue.removeFirst()
                    }
                    frameQueue.append(frame)
                    queueLock.unlock()

                    statsLock.lock()
                    framesDecoded &+= 1
                    statsLock.unlock()
                }
            } catch {
                print("UDPReceiver6: decode error \(error)")
            }
        }
    }

    // MARK: - Report thread

    private func reportLoop() {
        // Fire a first report quickly (1 s) so the UI gets something to show,
        // then settle into the requested ~10 s cadence.
        Thread.sleep(forTimeInterval: 1.0)
        if !isRunning { return }
        sendReceiverReport()
        while isRunning {
            Thread.sleep(forTimeInterval: reportIntervalSeconds)
            if !isRunning { break }
            sendReceiverReport()
        }
    }

    private func sendReceiverReport() {
        let now = Date()

        statsLock.lock()
        let elapsed = now.timeIntervalSince(lastReportTime)
        let byteDelta = bytesReceived &- lastBytes
        let frameDelta = framesDecoded &- lastFrames
        let packetsDelta = packetsReceived &- lastPackets
        let expectedDelta = (maxPacketnum &- lastMaxPacketnum)

        lastReportTime = now
        lastBytes = bytesReceived
        lastFrames = framesDecoded
        lastPackets = packetsReceived
        lastMaxPacketnum = maxPacketnum
        statsLock.unlock()

        guard elapsed > 0 else { return }
        let byteRate = Double(byteDelta) / elapsed
        let frameRate = Double(frameDelta) / elapsed
        var lossRate = 0.0
        if expectedDelta > 0 {
            let lost = Int64(expectedDelta) - Int64(packetsDelta)
            if lost > 0 {
                lossRate = Double(lost) / Double(expectedDelta)
            }
        }

        senderAddrLock.lock()
        let canSend = hasSenderAddr
        var addr = senderAddr ?? sockaddr_in6()
        senderAddrLock.unlock()

        print(String(format: "ReceiverReport: byteRate=%.1f B/s, loss=%.3f, fps=%.2f",
                     byteRate, lossRate, frameRate))

        var report = ReceiverReport(receivedByteRate: byteRate,
                                    packetLossRate: lossRate,
                                    frameRate: frameRate)

        // Publish snapshot for the UI before attempting to send.
        lastReportLock.lock()
        lastReport = report
        lastReportSentAt = now
        lastReportLock.unlock()

        guard canSend, socketFD >= 0 else { return }

        let sent = withUnsafePointer(to: &addr) { addrPtr -> ssize_t in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr -> ssize_t in
                withUnsafeBytes(of: &report) { bytes -> ssize_t in
                    sendto(socketFD,
                           bytes.baseAddress,
                           bytes.count,
                           0,
                           sockaddrPtr,
                           socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if sent < 0 {
            print("UDPReceiver6: sendto(report) failed errno=\(errno)")
        }
    }
}
