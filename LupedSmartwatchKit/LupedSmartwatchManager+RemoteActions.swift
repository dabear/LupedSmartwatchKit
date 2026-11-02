//
//  LupedSmartwatchManager+RemoteActions.swift
//  LupedSmartwatchKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import LupedKit

/// Requests from the watch (mute, carbs, signed boluses, override and temp target presets), passed to the host only
/// with their capability; the host decides. Each request is answered on `RESULT`.
extension LupedSmartwatchManager {
    /// Passes the watch's mute request to the host and logs the outcome.
    @MainActor
    func requestAlertMute(_ duration: TimeInterval, requestedAt: Date?) {
        // Without `.remoteMute` the host never hears of it.
        guard effectiveCapabilities.contains(.remoteMute) else {
            logNote("Mute request from the watch ignored: \(capabilityMismatch(.remoteMute, named: "remoteMute"))", kind: .error)
            transport.sendResult("mute:ignored")
            return
        }
        guard let requestedAt else {
            logNote("Mute request refused: the watch didn't say when it was confirmed (COMMAND without @<confirmedAt>)", kind: .error)
            transport.sendResult("mute:refused")
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Mute request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendResult("mute:failed")
            return
        }
        Task { @MainActor in
            do {
                let request = SmartwatchAlertMuteRequest(duration: duration, requestedAt: requestedAt)
                let end = try await delegate.smartwatchManager(self, requestAlertMute: request)
                let time = DateFormatter.localizedString(from: end, dateStyle: .none, timeStyle: .short)
                logNote("\(Self.hostName) alerts muted from the watch until \(time)", kind: .info)
                transport.sendResult("mute:ok")
            } catch {
                logNote("\(Self.hostName) refused the watch's mute request (\(error)); check Allow Mute from Watch in \(Self.hostName)'s settings", kind: .error)
                transport.sendResult("mute:refused")
            }
        }
    }

    /// Why a request needing `capability` isn't passed to the host.
    func capabilityMismatch(_ capability: SmartwatchCapabilities, named name: String) -> String {
        Self.capabilities.contains(capability)
            ? "this plugin has the \(name) capability but doesn't request it now"
            : "this plugin doesn't have the \(name) capability"
    }

    /// The longest wait for the host's snapshot after adding a request's carbs.
    static let carbsSnapshotTimeout: TimeInterval = 15

    /// Asks the host for a signed bolus the watch chose (LupedKit has checked the
    /// signature, timing and resends), and logs the outcome. With carbs, like
    /// Loop's and Trio's Apple Watch apps: the carbs are added first, then the
    /// bolus is checked against the host's next bolus context, whose
    /// recommendation includes them; without the carbs there is no bolus. The
    /// host's policy decides: permission, request and context age, maximum
    /// bolus, recommendation (skipped when `forced`) and rate limits.
    @MainActor
    func requestBolus(_ units: Double, forced: Bool = false, grams: Double? = nil, requestedAt: Date) {
        let action = forced ? "signedforcedbolus" : "signedbolus"
        // Answers the request: its carbs first if it had any, then the bolus.
        let answer = { [transport] (carbs: String?, bolus: String) in
            if grams != nil, let carbs {
                transport.sendResult("carbs:\(carbs)")
            }
            transport.sendResult("\(action):\(bolus)")
        }
        guard effectiveCapabilities.contains(.remoteBolus) else {
            logNote("Bolus request from the watch ignored: \(capabilityMismatch(.remoteBolus, named: "remoteBolus"))", kind: .error)
            answer("ignored", "ignored")
            return
        }
        if grams != nil, !effectiveCapabilities.contains(.remoteCarbs) {
            logNote("Bolus request with carbs refused: \(capabilityMismatch(.remoteCarbs, named: "remoteCarbs")), and the bolus isn't given without its carbs", kind: .error)
            answer("ignored", "refused")
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Bolus request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            answer("failed", "failed")
            return
        }
        Task { @MainActor in
            if let grams {
                logNote(String(format: "Asking %@ to add %g g of carbs from the watch before the bolus", Self.hostName, grams), kind: .info)
                do {
                    let added = try await delegate.smartwatchManager(self, requestCarbEntry: SmartwatchCarbEntryRequest(grams: grams, requestedAt: requestedAt))
                    logNote(String(format: "%@ added %g g of carbs requested from the watch", Self.hostName, added), kind: .info)
                    transport.sendResult("carbs:ok")
                } catch {
                    logNote("\(Self.hostName) refused the watch's carbs (\(error)), so the bolus isn't given either", kind: .error)
                    answer("refused", "refused")
                    return
                }
            }
            // With carbs, the context sent before them recommends too little: wait
            // for the host's next one, which counts them.
            let snapshot = grams == nil ? latestSnapshot : await nextSnapshot(timeout: Self.carbsSnapshotTimeout)
            guard let context = snapshot?.bolusContext else {
                logNote("Bolus request not passed on: \(Self.hostName) hasn't sent a bolus context\(grams == nil ? " yet (Allow Boluses from Watch may be off)" : String(format: " within %.0f s of adding the carbs", Self.carbsSnapshotTimeout))", kind: .error)
                transport.sendResult("\(action):failed")
                return
            }
            let request = SmartwatchBolusRequest(units: units, contextToken: context.token, requestedAt: requestedAt, isForced: forced)
            logNote(String(format: "Asking %@ for a %.2f U %@from the watch", Self.hostName, request.units, forced ? "forced bolus (recommendation not checked) " : "bolus "), kind: .info)
            do {
                let units = try await delegate.smartwatchManager(self, requestBolus: request)
                logNote(String(format: "%@ delivered %.2f U requested from the watch", Self.hostName, units), kind: .info)
                transport.sendResult("\(action):ok")
            } catch SmartwatchBolusError.inProgress {
                // LupedKit passes each signed request on once, so this is another
                // request for the bolus being delivered: that one's result follows.
                logNote("\(Self.hostName) is still delivering a bolus for this context; this request is refused", kind: .error)
                transport.sendResult("\(action):refused")
            } catch {
                logNote("\(Self.hostName) refused the watch's bolus request (\(error))", kind: .error)
                transport.sendResult("\(action):refused")
            }
        }
    }

    /// Asks the host for a snapshot and waits for it; `nil` after `timeout`.
    @MainActor
    private func nextSnapshot(timeout: TimeInterval) async -> SmartwatchStatusSnapshot? {
        let start = snapshotCount
        smartwatchManagerDelegate?.smartwatchManagerRequestsRefresh(self)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if snapshotCount != start {
                return latestSnapshot
            }
        }
        return nil
    }

    /// Asks the host to add the carb entry the watch chose, and logs the outcome.
    /// The host decides: permission and rate limit.
    @MainActor
    func requestCarbs(_ grams: Double, requestedAt: Date?) {
        guard effectiveCapabilities.contains(.remoteCarbs) else {
            logNote("Carb request from the watch ignored: \(capabilityMismatch(.remoteCarbs, named: "remoteCarbs"))", kind: .error)
            transport.sendResult("carbs:ignored")
            return
        }
        guard let requestedAt else {
            logNote("Carb request refused: the watch didn't say when it was confirmed (COMMAND without @<confirmedAt>)", kind: .error)
            transport.sendResult("carbs:refused")
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Carb request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendResult("carbs:failed")
            return
        }
        logNote(String(format: "Asking %@ to add %g g of carbs from the watch", Self.hostName, grams), kind: .info)
        Task { @MainActor in
            do {
                let request = SmartwatchCarbEntryRequest(grams: grams, requestedAt: requestedAt)
                let grams = try await delegate.smartwatchManager(self, requestCarbEntry: request)
                logNote(String(format: "%@ added %g g of carbs requested from the watch", Self.hostName, grams), kind: .info)
                transport.sendResult("carbs:ok")
            } catch {
                logNote("\(Self.hostName) refused the watch's carb request (\(error))", kind: .error)
                transport.sendResult("carbs:refused")
            }
        }
    }

    /// Asks the host to start the override preset the watch named (by id, or by
    /// name ignoring case, from the host's latest presets) or to end the running
    /// one, and logs the outcome. The host decides: permission and request age.
    @MainActor
    func requestOverride(_ action: LupedPresetAction, requestedAt: Date?) {
        requestPreset(action, requestedAt: requestedAt, kind: .override)
    }

    /// The same for temp target presets, on hosts that have them.
    @MainActor
    func requestTempTarget(_ action: LupedPresetAction, requestedAt: Date?) {
        requestPreset(action, requestedAt: requestedAt, kind: .tempTarget)
    }

    enum PresetKind {
        case override, tempTarget

        var capability: SmartwatchCapabilities { self == .override ? .remoteOverride : .remoteTempTarget }
        var capabilityName: String { self == .override ? "remoteOverride" : "remoteTempTarget" }
        /// The `<action>` of its `RESULT`.
        var action: String { self == .override ? "override" : "temptarget" }
        var noun: String { self == .override ? "preset" : "temp target" }
        var permission: String { self == .override ? "Allow Presets from Watch" : "Allow Temp Targets from Watch" }
    }

    @MainActor
    private func requestPreset(_ action: LupedPresetAction, requestedAt: Date?, kind: PresetKind) {
        let request = kind.noun.prefix(1).uppercased() + kind.noun.dropFirst() + " request"
        guard effectiveCapabilities.contains(kind.capability) else {
            logNote("\(request) from the watch ignored: \(capabilityMismatch(kind.capability, named: kind.capabilityName))", kind: .error)
            transport.sendResult("\(kind.action):ignored")
            return
        }
        guard let requestedAt else {
            logNote("\(request) refused: the watch didn't say when it was confirmed (COMMAND without @<confirmedAt>)", kind: .error)
            transport.sendResult("\(kind.action):refused")
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("\(request) not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendResult("\(kind.action):failed")
            return
        }
        let presetAction: SmartwatchPresetAction
        switch action {
        case .cancel:
            presetAction = .cancel
        case .start(let wanted):
            let presets = (kind == .override ? latestSnapshot?.overridePresets : latestSnapshot?.tempTargetPresets) ?? []
            guard let preset = presets.first(where: { $0.id == wanted })
                ?? presets.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
            else {
                let known = presets.isEmpty ? "it hasn't sent any" : presets.map { "\"\($0.name)\"" }.joined(separator: ", ")
                logNote("\(request) refused: \(Self.hostName) has no \(kind.noun) \"\(wanted)\" (\(known))", kind: .error)
                transport.sendResult("\(kind.action):refused")
                return
            }
            presetAction = .activate(presetID: preset.id)
        }
        Task { @MainActor in
            do {
                switch kind {
                case .override:
                    try await delegate.smartwatchManager(self, requestOverride: SmartwatchOverrideRequest(action: presetAction, requestedAt: requestedAt))
                case .tempTarget:
                    try await delegate.smartwatchManager(self, requestTempTarget: SmartwatchTempTargetRequest(action: presetAction, requestedAt: requestedAt))
                }
                logNote("\(Self.hostName) \(action == .cancel ? "ended the running" : "started the") \(kind.noun) requested from the watch", kind: .info)
                transport.sendResult("\(kind.action):ok")
            } catch {
                logNote("\(Self.hostName) refused the watch's \(kind.noun) request (\(error)); check \(kind.permission) in \(Self.hostName)'s settings", kind: .error)
                transport.sendResult("\(kind.action):refused")
            }
        }
    }
}
