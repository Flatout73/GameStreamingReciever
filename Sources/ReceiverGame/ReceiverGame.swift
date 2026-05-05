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
            .width(2400),
            .height(1200),
            .resizable(true)
        ]
    }
    
    @OptionGroup
    var options: GameOptions
    
    @Argument
    var message: String = "Waiting for stream..."
    
    private var renderer: (any Renderer)! = nil
    private var texture: (any Texture)! = nil
    
    private let udpReceiver = UDPReceiver6()
    private var videoDecoder: VideoDecoder?
    
    // For passing frames from UDP thread to SDL thread
    private let frameLock = NSLock()
    private var latestFrameData: Data?
    private var frameWidth: Int32 = 0
    private var frameHeight: Int32 = 0
    private var isNewFrameAvailable = false

    func onReady(window: any Window) throws(SDL_Error) {
        renderer = try window.createRenderer()
        
        do {
            videoDecoder = try VideoDecoder(codecName: "hevc")
            print("VideoDecoder initialized for HEVC.")
        } catch {
            print("Failed to initialize video decoder: \(error)")
        }
        
        udpReceiver.onDataReceived = { [weak self] payload, header in
            guard let self = self, let decoder = self.videoDecoder else { return }
            do {
                if let rgbaData = try decoder.decode(data: payload) {
                    self.frameLock.lock()
                    self.latestFrameData = rgbaData
                    self.frameWidth = decoder.width
                    self.frameHeight = decoder.height
                    self.isNewFrameAvailable = true
                    self.frameLock.unlock()
                }
            } catch {
                // print("Decode error: \(error)")
            }
        }
        
        do {
            try udpReceiver.start(port: 50000)
            print("Listening on UDP port 50000...")
        } catch {
            print("Failed to start UDP receiver: \(error)")
        }
    }
    
    func onUpdate(window: any Window) throws(SDL_Error) {
        var frameDataToRender: Data?
        var w: Int32 = 0
        var h: Int32 = 0
        
        frameLock.lock()
        if isNewFrameAvailable {
            frameDataToRender = latestFrameData
            w = frameWidth
            h = frameHeight
            isNewFrameAvailable = false
        }
        frameLock.unlock()
        
        if let data = frameDataToRender, w > 0, h > 0 {
            var needsNewTexture = true
            if let t = texture {
                do {
                    let size = try t.size(as: Int32.self)
                    if size.x == w && size.y == h {
                        needsNewTexture = false
                    }
                } catch {
                    // fallthrough to recreate
                }
            }
            
            if needsNewTexture {
                // Create streaming texture using C-API and wrap it in SDLObject
                if let ptr = SwiftSDL.SDL_CreateTexture(
                    renderer.pointer,
                    SDL_PIXELFORMAT_RGBA32,
                    SDL_TEXTUREACCESS_STREAMING,
                    w,
                    h
                ) {
                    texture = SDLObject(ptr, tag: .custom("videoTexture"), destroy: SDL_DestroyTexture)
                }
            }
            
            // Update texture
            if let texture = texture {
                data.withUnsafeBytes { ptr in
                    if let baseAddress = ptr.baseAddress {
                        let _ = SDL_UpdateTexture(
                            texture.pointer,
                            nil,
                            baseAddress,
                            w * 4 // RGBA = 4 bytes per pixel
                        )
                    }
                }
                try renderer
                    .clear(color: .black)
                    .draw(texture: texture)
                    .present()
            }
        } else if texture == nil {
            try renderer
                .clear(color: .black)
                .debug(text: message, position: [12, 12], scale: [2, 2])
                .present()
        } else {
             // Keep presenting last frame if no new frame
            try renderer
                .clear(color: .black)
                .draw(texture: texture)
                .present()
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
