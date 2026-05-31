import SwiftSDL
import Foundation

@main
final class ReceiverGame: Game {
    private enum CodingKeys: String, CodingKey {
        case options, message
    }

    static var windowProperties: [WindowProperty] {
        [
            .windowTitle("Receiver Game Stream"),
            .width(1200),
            .height(600),
            .resizable(true)
        ]
    }

    @OptionGroup
    var options: GameOptions

    @Argument
    var message: String = "Waiting for stream..."

    private var renderer: (any Renderer)! = nil
    private var texture: (any Texture)! = nil
    private var currentTextureWidth: Int32 = 0
    private var currentTextureHeight: Int32 = 0

    private let udpReceiver = UDPReceiver6()
    private var videoDecoder: VideoDecoder?

    func onReady(window: any Window) throws(SDL_Error) {
        renderer = try window.createRenderer()

        do {
            videoDecoder = try VideoDecoder(codecName: "hevc")
            print("VideoDecoder initialized for HEVC.")
            udpReceiver.setDecoder(videoDecoder!)
        } catch {
            print("Failed to initialize video decoder: \(error)")
        }

        do {
            try udpReceiver.start(port: 50000)
            print("Listening on UDP port 50000 (Thread A receive + decode, Thread B render).")
        } catch {
            print("Failed to start UDP receiver: \(error)")
        }
    }

    // Thread B: the SDL main loop calls this at the display refresh rate,
    // which is slightly larger than the source frame rate. Each tick we
    // pull at most one frame off the FIFO and present it.
    func onUpdate(window: any Window) throws(SDL_Error) {
        // 1) Update the streaming texture if a new frame arrived.
        if let frame = udpReceiver.popFrame() {
            let w = frame.width
            let h = frame.height

            if texture == nil || currentTextureWidth != w || currentTextureHeight != h {
                if let ptr = SwiftSDL.SDL_CreateTexture(
                    renderer.pointer,
                    SDL_PIXELFORMAT_RGBA32,
                    SDL_TEXTUREACCESS_STREAMING,
                    w, h
                ) {
                    texture = SDLObject(ptr, tag: .custom("videoTexture"), destroy: SDL_DestroyTexture)
                    currentTextureWidth = w
                    currentTextureHeight = h
                }
            }

            if let texture = texture {
                frame.pixels.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = SDL_UpdateTexture(texture.pointer, nil, base, w * 4)
                    }
                }
            }
        }

        // 2) Render the current scene.
        try renderer.clear(color: .black)
        if let texture = texture {
            SDL_RenderTexture(renderer.pointer, texture.pointer, nil, nil)
        } else {
            try renderer.debug(text: message, position: [12, 12], scale: [2, 2])
        }

        // 3) Receiver-report overlay in the bottom-left corner.
        drawReportOverlay(window: window)

        try renderer.present()
    }

    private func drawReportOverlay(window: any Window) {
        // Renderer output size in pixels (matches SDL_RenderDebugText's target
        // coordinate space).
        var rw: Int32 = 0
        var rh: Int32 = 0
        _ = SDL_GetRenderOutputSize(renderer.pointer, &rw, &rh)
        if rw == 0 || rh == 0 { return }

        let lines: [String]
        if let snapshot = udpReceiver.latestReport() {
            let report = snapshot.report
            let kib = report.receivedByteRate / 1024.0
            let lossPct = report.packetLossRate * 100.0
            lines = [
                "Receiver Report",
                String(format: "Byte rate:  %.1f KiB/s", kib),
                String(format: "Loss rate:  %.2f %%", lossPct),
                String(format: "Frame rate: %.2f fps", report.frameRate),
            ]
        } else {
            lines = [
                "Receiver Report",
                "Waiting for first report...",
            ]
        }

        // Layout in renderer-pixel space.
        let scale: Float = 2.0
        let glyphHpx: Float = 8.0 * scale      // SDL debug font is 8 px tall
        let glyphWpx: Float = 8.0 * scale      // ...and 8 px wide per char
        let lineGapPx: Float = 4.0
        let lineStridePx = glyphHpx + lineGapPx
        let marginPx: Float = 16.0
        let padPx: Float = 8.0

        let totalHpx = lineStridePx * Float(lines.count) - lineGapPx
        let longestChars = lines.map { $0.count }.max() ?? 0
        let totalWpx = glyphWpx * Float(longestChars)

        let boxX = marginPx
        let boxY = Float(rh) - marginPx - totalHpx - 2 * padPx
        let boxW = totalWpx + 2 * padPx
        let boxH = totalHpx + 2 * padPx

        // 1) Semi-transparent black background.
        do {
            try renderer.set(blendMode: .blend)
            let bg = SDL_FRect(x: boxX, y: boxY, w: boxW, h: boxH)
            try renderer.fill(rects: bg, color: SDL_Color(r: 0, g: 0, b: 0, a: 180))
        } catch {
            // ignore
        }

        // 2) White text on top. position is in scale-applied logical units,
        //    so divide pixel coords by scale.
        let textX = (boxX + padPx) / scale
        var textY = (boxY + padPx) / scale
        let yIncrement = lineStridePx / scale
        let white = SDL_Color(r: 255, g: 255, b: 255, a: 255)
        for line in lines {
            do {
                try renderer.debug(text: line,
                                   position: [textX, textY],
                                   color: white,
                                   scale: [scale, scale])
            } catch {
                // ignore
            }
            textY += yIncrement
        }
    }

    func onEvent(window: any Window, _ event: SDL_Event) throws(SDL_Error) {
    }

    func onShutdown(window: (any Window)?) throws(SDL_Error) {
        udpReceiver.stop()
        texture = nil
        renderer = nil
    }
}
