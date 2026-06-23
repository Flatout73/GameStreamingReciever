//
//  NetInputEvent.swift
//  ReceiverGame
//
//  Wire format for input events forwarded from this client back to the server.
//  Layout (48 bytes, 12 x 4-byte fields, no padding) matches the C++
//  `netinput::NetInputEvent` struct in game/net_input_event.h byte-for-byte.
//

import Foundation

struct NetInputEvent {
    enum Kind: UInt32 {
        case keyDown = 1
        case keyUp = 2
        case mouseMotion = 3
        case mouseButtonDown = 4
        case mouseButtonUp = 5
        case mouseWheel = 6
    }

    var kind: UInt32 = 0
    var scancode: UInt32 = 0   // SDL_Scancode raw value
    var keycode: UInt32 = 0    // SDL_Keycode raw value
    var mod: UInt32 = 0        // SDL_Keymod
    var button: UInt32 = 0     // mouse button index (1=left, 2=middle, 3=right)
    var repeatFlag: UInt32 = 0 // 0/1
    var x: Float = 0
    var y: Float = 0
    var xrel: Float = 0
    var yrel: Float = 0
    var wheelX: Float = 0
    var wheelY: Float = 0
}
