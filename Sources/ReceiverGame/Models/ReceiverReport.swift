//
//  ReceiverReport.swift
//  ReceiverGame
//
//  Created by Leonid Liadveikin on 19.05.26.
//

import Foundation

/// Wire-format report sent back to the sender.
/// Layout (24 bytes, 8-byte alignment) matches C++ side.
struct ReceiverReport {
    var receivedByteRate: Double   // bytes/sec
    var packetLossRate: Double     // 0..1
    var frameRate: Double          // frames/sec
}
