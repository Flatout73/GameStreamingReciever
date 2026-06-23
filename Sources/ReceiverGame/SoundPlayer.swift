import AVFoundation
import Foundation

/// Renders all game audio on the client. Nothing plays on the server; sounds
/// are triggered by `SoundCommand`s streamed from it (see SoundCommandReceiver).
///
/// All AVAudioPlayer access is serialized on a private queue, so `handle(_:)`
/// is safe to call from the UDP receive thread. Background music uses one
/// dedicated looping player; sound effects spawn short-lived players so rapid
/// hits (e.g. eating fruit) can overlap.
final class SoundPlayer {
    private let queue = DispatchQueue(label: "ReceiverGame.SoundPlayer")

    /// Preloaded encoded audio, keyed by `SoundId.rawValue`.
    private var bank: [UInt32: Data] = [:]

    private var musicPlayer: AVAudioPlayer?
    private var musicPerSound: Int32 = 0          // last music per-sound volume (0..128)
    private var sfx: [AVAudioPlayer] = []         // active one-shots, retained until done

    /// Master volume 0..1 (default 0.5 ~ the server's mid volume of 64/128).
    private var masterVolume: Float = 0.5

    /// SoundId -> bundled resource. MUSIC uses the generated snake theme.
    private static let resources: [(SoundId, String, String)] = [
        (.music, "snake_theme", "wav"),
        (.bell, "bell", "wav"),
        (.explosion, "explosion", "wav"),
        (.gameover, "gameover", "wav"),
    ]

    init() {
        for (id, name, ext) in Self.resources {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
                print("SoundPlayer: resource \(name).\(ext) not found in bundle")
                continue
            }
            if let data = try? Data(contentsOf: url) {
                bank[id.rawValue] = data
            } else {
                print("SoundPlayer: failed to load \(name).\(ext)")
            }
        }
    }

    /// Apply a command (asynchronously, on the serial queue).
    func handle(_ cmd: SoundCommand) {
        queue.async { [weak self] in self?.apply(cmd) }
    }

    /// Stop everything (e.g. on shutdown).
    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.musicPlayer?.stop()
            self.musicPlayer = nil
            self.sfx.forEach { $0.stop() }
            self.sfx.removeAll()
        }
    }

    // MARK: - queue-isolated

    private func effectiveVolume(_ perSound: Int32) -> Float {
        let s = Float(max(0, min(128, perSound))) / 128.0
        return s * masterVolume
    }

    private func apply(_ cmd: SoundCommand) {
        guard let action = SoundAction(rawValue: cmd.action) else {
            print("SoundPlayer: unknown action=\(cmd.action) (seq=\(cmd.seq))")
            return
        }
        switch action {
        case .play:
            guard let id = SoundId(rawValue: cmd.soundId) else {
                print("SoundPlayer: unknown soundId=\(cmd.soundId) (seq=\(cmd.seq))")
                return
            }
            if id == .music { playMusic(cmd) } else { playSFX(id, cmd) }
        case .stop:
            if SoundId(rawValue: cmd.soundId) == .music {
                musicPlayer?.stop()
                musicPlayer = nil
            }
        case .stopAll:
            musicPlayer?.stop()
            musicPlayer = nil
            sfx.forEach { $0.stop() }
            sfx.removeAll()
        case .setMasterVolume:
            masterVolume = Float(max(0, min(128, cmd.volume))) / 128.0
            musicPlayer?.volume = effectiveVolume(musicPerSound)
        }
    }

    private func playMusic(_ cmd: SoundCommand) {
        guard let data = bank[SoundId.music.rawValue] else { return }
        musicPlayer?.stop()
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = Int(cmd.loops)        // -1 = forever
            musicPerSound = cmd.volume
            p.volume = effectiveVolume(cmd.volume)
            p.prepareToPlay()
            p.play()
            musicPlayer = p
        } catch {
            print("SoundPlayer: music failed: \(error)")
        }
    }

    private func playSFX(_ id: SoundId, _ cmd: SoundCommand) {
        guard let data = bank[id.rawValue] else { return }
        sfx.removeAll { !$0.isPlaying }             // reap finished players
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = Int(cmd.loops)        // 0 = play once
            p.volume = effectiveVolume(cmd.volume)
            p.prepareToPlay()
            p.play()
            sfx.append(p)
        } catch {
            print("SoundPlayer: sfx \(id) failed: \(error)")
        }
    }
}
