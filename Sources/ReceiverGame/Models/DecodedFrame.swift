//
//  DecodedFrame.swift
//  ReceiverGame
//
//  Created by Leonid Liadveikin on 19.05.26.
//

import Foundation

struct DecodedFrame {
    let pixels: Data       // RGBA8
    let width: Int32
    let height: Int32
}
