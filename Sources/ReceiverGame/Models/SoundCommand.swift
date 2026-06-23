//
//  SoundCommand.swift
//  ReceiverGame
//
//  Wire format for sound-play commands streamed from the server to this
//  client. Layout (20 bytes, 5 x 4-byte fields, no padding) matches the C++
//  `netsound::SoundCommand` struct in game/net_sound_command.h byte-for-byte.
//  On the wire each command is preceded by an RTHeader (16 bytes), which the
//  receiver skips before decoding.
//

import Foundation

enum SoundAction: UInt32 {
    case play = 1               // start `soundId`
    case stop = 2               // stop `soundId`
    case stopAll = 3            // stop every sound
    case setMasterVolume = 4    // set master volume (`volume`)
}

enum SoundId: UInt32 {
    case none = 0
    case music = 1              // looping background music
    case bell = 2               // fruit eaten
    case explosion = 3          // crash death
    case gameover = 4           // game over jingle
}

struct SoundCommand {
    var action: UInt32 = 0   // SoundAction
    var soundId: UInt32 = 0  // SoundId
    var loops: Int32 = 0     // -1 = loop forever, 0 = play once, N = repeat N more times
    var volume: Int32 = 0    // 0..128 volume scale
    var seq: UInt32 = 0      // monotonically increasing; dedup resends by it
}
