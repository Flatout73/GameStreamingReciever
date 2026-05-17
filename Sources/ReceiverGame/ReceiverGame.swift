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
                try renderer.clear(color: .black)
                SDL_RenderTexture(renderer.pointer, texture.pointer, nil, nil)
                try renderer.present()
            }
        } else if texture == nil {
            try renderer
                .clear(color: .black)
                .debug(text: message, position: [12, 12], scale: [2, 2])
                .present()
        } else {
            // No fresh frame this tick — keep the last one on screen.
            try renderer.clear(color: .black)
            SDL_RenderTexture(renderer.pointer, texture.pointer, nil, nil)
            try renderer.present()
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
