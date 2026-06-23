//
//  RTHeader.swift
//  ReceiverGame
//
//  Created by Leonid Liadveikin on 19.05.26.
//

import Foundation

struct RTHeader {
    var time: Double
    var packetnum: UInt64   // matches C++ uint64_t; pins the header at 16 bytes
}
