//
//  LupedRemotePolicy.swift
//  LupedSmartwatchKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

/// Which of Luped Remote's requests the user allows, each off until turned on
/// in the Pebble settings. The host offers these actions to any watch plugin
/// and applies only its own limits (such as the maximum bolus), so whether
/// Luped Remote may ask at all is decided here. Saved in `rawState`, and
/// turned off when the watch is deleted, so a watch added again starts with
/// every request off.
public struct LupedRemotePermissions: Equatable, Sendable {
    public var bolus: Bool
    public var carbs: Bool
    public var mute: Bool
    /// Override presets (Loop's presets, Trio's overrides).
    public var overrides: Bool
    /// Temp target presets, for hosts that have them (Trio).
    public var tempTargets: Bool

    public init(bolus: Bool = false, carbs: Bool = false, mute: Bool = false, overrides: Bool = false, tempTargets: Bool = false) {
        self.bolus = bolus
        self.carbs = carbs
        self.mute = mute
        self.overrides = overrides
        self.tempTargets = tempTargets
    }

    /// Every request off.
    public static let none = LupedRemotePermissions()

    public typealias RawValue = [String: Bool]

    /// A missing or unknown value is off.
    public init(rawValue: RawValue) {
        self.init(
            bolus: rawValue["bolus"] ?? false,
            carbs: rawValue["carbs"] ?? false,
            mute: rawValue["mute"] ?? false,
            overrides: rawValue["overrides"] ?? false,
            tempTargets: rawValue["tempTargets"] ?? false
        )
    }

    public var rawValue: RawValue {
        ["bolus": bolus, "carbs": carbs, "mute": mute, "overrides": overrides, "tempTargets": tempTargets]
    }
}

/// Luped's limits for Luped Remote's requests. They are the values Loop
/// applied to every watch before these checks moved from the hosts into the
/// plugins, so moving them changed nothing on the watch.
extension LupedSmartwatchManager {
    /// Every request must have been confirmed on the watch at most 30 s ago,
    /// and at most 5 s ahead of the phone's clock.
    public static let requestWindow = SmartwatchRequestWindow(maximumAge: 30, maximumClockSkew: 5)

    public static let bolusLimits = SmartwatchBolusPolicy.Limits(
        requestWindow: requestWindow,
        maximumContextAge: 15 * 60,
        maximumGlucoseAge: 15 * 60,
        minimumInterval: 5 * 60,
        dailyLimitInMaximumBoluses: 3,
        // LupedKit doesn't carry the token: the plugin quotes the context it
        // issued last, which must still be the current one.
        requiresContextToken: true,
        capsAtRecommendation: true
    )

    public static let carbEntryLimits = SmartwatchCarbEntryPolicy.Limits(
        requestWindow: requestWindow,
        minimumInterval: 5 * 60
    )
}

/// Luped Remote's recent boluses and its last carb entry, for the rate limits.
///
/// Kept in `UserDefaults` under the plugin's own keys, not in `rawState`, and
/// kept when the watch is deleted: deleting and adding the watch again must not
/// reset the time between requests or the daily bolus total.
struct LupedRemoteHistory {
    static let bolusDeliveriesKey = "com.loopkit.LupedSmartwatchKit.watchBolusDeliveries"
    static let lastCarbEntryKey = "com.loopkit.LupedSmartwatchKit.lastWatchCarbEntry"
    /// How long a bolus counts for the daily total.
    static let bolusHistoryInterval: TimeInterval = 24 * 60 * 60

    let defaults: UserDefaults

    /// Watch boluses in the last 24 hours, attempts included (0 U).
    var bolusDeliveries: [SmartwatchBolusPolicy.Delivery] {
        get {
            defaults.data(forKey: Self.bolusDeliveriesKey).flatMap { try? JSONDecoder().decode([SmartwatchBolusPolicy.Delivery].self, from: $0) } ?? []
        }
        nonmutating set {
            let dayStart = Date().addingTimeInterval(-Self.bolusHistoryInterval)
            defaults.set(try? JSONEncoder().encode(newValue.filter { $0.date > dayStart }), forKey: Self.bolusDeliveriesKey)
        }
    }

    /// When the last carb entry from the watch was added, for its rate limit.
    var lastCarbEntry: Date? {
        get { defaults.object(forKey: Self.lastCarbEntryKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastCarbEntryKey) }
    }

    /// The deliveries with an attempt at `date`: 0 U, so it counts for the time
    /// between boluses but not the daily total.
    static func bolusAttempted(at date: Date, in deliveries: [SmartwatchBolusPolicy.Delivery]) -> [SmartwatchBolusPolicy.Delivery] {
        deliveries + [SmartwatchBolusPolicy.Delivery(date: date, units: 0)]
    }

    /// The attempt at `attemptedAt` delivered `units`: they count toward the daily total too.
    static func bolusDelivered(_ units: Double, attemptedAt: Date, in deliveries: [SmartwatchBolusPolicy.Delivery]) -> [SmartwatchBolusPolicy.Delivery] {
        deliveries.filter { $0 != SmartwatchBolusPolicy.Delivery(date: attemptedAt, units: 0) }
            + [SmartwatchBolusPolicy.Delivery(date: attemptedAt, units: units)]
    }
}
