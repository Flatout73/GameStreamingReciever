import Foundation
import CFFmpeg

enum DecoderError: Error {
    case codecNotFound
    case contextAllocationFailed
    case contextOpenFailed
    case sendPacketFailed
    case receiveFrameFailed
    case frameAllocationFailed
    case swsContextFailed
}

class VideoDecoder {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swsCtx: UnsafeMutablePointer<SwsContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var rgbaFrame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var rgbaBuffer: UnsafeMutablePointer<UInt8>?
    
    /// Current dimensions of the decoded frame
    var width: Int32 = 0
    var height: Int32 = 0
    
    init(codecName: String = "hevc") throws {
        let codec = avcodec_find_decoder_by_name(codecName)
        guard let codec = codec else {
            throw DecoderError.codecNotFound
        }
        
        codecCtx = avcodec_alloc_context3(codec)
        guard let codecCtx = codecCtx else {
            throw DecoderError.contextAllocationFailed
        }

        // Low latency: emit each frame as soon as it decodes, and avoid
        // frame-threading (which delays output by ~thread_count frames to fill
        // its pipeline). AV_CODEC_FLAG_LOW_DELAY == 1 << 19.
        codecCtx.pointee.flags |= Int32(AV_CODEC_FLAG_LOW_DELAY)
        codecCtx.pointee.thread_count = 1

        if avcodec_open2(codecCtx, codec, nil) < 0 {
            avcodec_free_context(&self.codecCtx)
            throw DecoderError.contextOpenFailed
        }
        
        frame = av_frame_alloc()
        rgbaFrame = av_frame_alloc()
        packet = av_packet_alloc()
        
        guard frame != nil, rgbaFrame != nil, packet != nil else {
            throw DecoderError.frameAllocationFailed
        }
    }
    
    deinit {
        if let rgbaBuffer = rgbaBuffer {
            av_free(rgbaBuffer)
        }
        av_packet_free(&packet)
        av_frame_free(&rgbaFrame)
        av_frame_free(&frame)
        if swsCtx != nil {
            sws_freeContext(swsCtx)
        }
        avcodec_free_context(&codecCtx)
    }
    
    /// Decodes a packet and returns RGBA pixel data if a frame is fully decoded.
    /// The returned Data points to a temporary buffer and is only valid until the next call.
    func decode(data: Data) throws -> Data? {
        guard let codecCtx = codecCtx, let frame = frame, let packet = packet else { return nil }
        
        // Setup packet
        var ret: Int32 = 0
        data.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                packet.pointee.data = UnsafeMutablePointer(mutating: baseAddress.assumingMemoryBound(to: UInt8.self))
                packet.pointee.size = Int32(data.count)
                ret = avcodec_send_packet(codecCtx, packet)
            }
        }
        
        guard ret >= 0 else {
            print("VideoDecoder: avcodec_send_packet failed (\(ret))")
            throw DecoderError.sendPacketFailed
        }
        
        ret = avcodec_receive_frame(codecCtx, frame)
        if ret == -35 { // AVERROR(EAGAIN)
            return nil // Needs more data
        } else if ret < 0 {
            print("VideoDecoder: avcodec_receive_frame failed (\(ret))")
            throw DecoderError.receiveFrameFailed
        }
        
        // We have a decoded frame
        let frameWidth = frame.pointee.width
        let frameHeight = frame.pointee.height
        
        // Check if we need to initialize or reinitialize the scaler
        if swsCtx == nil || width != frameWidth || height != frameHeight {
            if swsCtx != nil {
                sws_freeContext(swsCtx)
            }
            if let rgbaBuffer = rgbaBuffer {
                av_free(rgbaBuffer)
            }
            
            width = frameWidth
            height = frameHeight
            
            swsCtx = sws_getContext(
                width, height, AVPixelFormat(frame.pointee.format),
                width, height, AV_PIX_FMT_RGBA,
                2, nil, nil, nil // 2 == SWS_BILINEAR
            )
            
            guard swsCtx != nil else {
                throw DecoderError.swsContextFailed
            }
            
            let numBytes = av_image_get_buffer_size(AV_PIX_FMT_RGBA, width, height, 1)
            rgbaBuffer = UnsafeMutablePointer<UInt8>(mutating: av_malloc(Int(numBytes))!.assumingMemoryBound(to: UInt8.self))
            
            // Cast to deal with the pointer type expected by C function in Swift 6
            let rgbaDataPtr = withUnsafeMutablePointer(to: &rgbaFrame!.pointee.data) {
                $0.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { ptr in
                    return ptr
                }
            }
            
            let rgbaLinesizePtr = withUnsafeMutablePointer(to: &rgbaFrame!.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 8) { ptr in
                    return ptr
                }
            }

            av_image_fill_arrays(
                rgbaDataPtr,
                rgbaLinesizePtr,
                rgbaBuffer,
                AV_PIX_FMT_RGBA,
                width,
                height,
                1
            )
        }
        
        guard let swsCtx = swsCtx else { return nil }
        
        // Use withUnsafeMutablePointer for frame data/linesize arrays
        let srcDataPtr = withUnsafeMutablePointer(to: &frame.pointee.data) {
            $0.withMemoryRebound(to: Optional<UnsafePointer<UInt8>>.self, capacity: 8) { ptr in
                return ptr
            }
        }
        let srcLinesizePtr = withUnsafeMutablePointer(to: &frame.pointee.linesize) {
            $0.withMemoryRebound(to: Int32.self, capacity: 8) { ptr in
                return ptr
            }
        }
        
        let dstDataPtr = withUnsafeMutablePointer(to: &rgbaFrame!.pointee.data) {
            $0.withMemoryRebound(to: Optional<UnsafeMutablePointer<UInt8>>.self, capacity: 8) { ptr in
                return ptr
            }
        }
        let dstLinesizePtr = withUnsafeMutablePointer(to: &rgbaFrame!.pointee.linesize) {
            $0.withMemoryRebound(to: Int32.self, capacity: 8) { ptr in
                return ptr
            }
        }
        
        _ = sws_scale(
            swsCtx,
            srcDataPtr,
            srcLinesizePtr,
            0,
            height,
            dstDataPtr,
            dstLinesizePtr
        )
        
        let rgbaSize = Int(rgbaFrame!.pointee.linesize.0 * height)
        return Data(bytesNoCopy: rgbaFrame!.pointee.data.0!, count: rgbaSize, deallocator: .none)
    }
}
