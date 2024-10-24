//
//  Item.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/24/24.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    var label: String
    
    init(timestamp: Date, label: String) {
        self.timestamp = timestamp
        self.label = label
    }
}
