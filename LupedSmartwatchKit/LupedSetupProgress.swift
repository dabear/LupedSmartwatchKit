//
//  LupedSetupProgress.swift
//  LupedSmartwatchKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LupedKit

/// Where adding a Pebble stands, from the watch link's live status. Setup is
/// done once the watch has acknowledged a reading, not merely connected.
public enum LupedSetupProgress: Equatable {
    /// Bluetooth is off or Loop may not use it.
    case bluetoothUnavailable
    /// The watch has not opened a session with Loop yet.
    case waitingForWatch
    case connecting
    /// Connected; no reading has been delivered yet.
    case waitingForReading
    /// The watch rejected the reading, or stopped answering: the Luped
    /// watchface is not running.
    case watchfaceNotRunning
    /// The watch acknowledged the reading taken at `readingDate`.
    case delivered(readingDate: Date)

    public init(link: LupedLinkStatus.Link, lastDelivery: (readingDate: Date, deliveredAt: Date)?, lastRejectedAt: Date?, paused: Bool) {
        if let lastDelivery, lastDelivery.deliveredAt >= (lastRejectedAt ?? .distantPast) {
            self = .delivered(readingDate: lastDelivery.readingDate)
            return
        }
        switch link {
        case .bluetoothUnavailable:
            self = .bluetoothUnavailable
        case .off, .waitingForWatch:
            self = .waitingForWatch
        case .connecting:
            self = .connecting
        case .open:
            self = lastRejectedAt != nil || paused ? .watchfaceNotRunning : .waitingForReading
        }
    }

    @MainActor
    public init(_ status: LupedLinkStatus) {
        self.init(
            link: status.link,
            lastDelivery: status.lastDelivery.map { ($0.readingDate, $0.deliveredAt) },
            lastRejectedAt: status.lastRejectedAt,
            paused: status.paused
        )
    }

    public var isComplete: Bool {
        if case .delivered = self {
            return true
        }
        return false
    }
}
