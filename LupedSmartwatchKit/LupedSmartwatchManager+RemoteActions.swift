//
//  LupedSmartwatchManager+RemoteActions.swift
//  LupedSmartwatchKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import LupedKit

/// Requests from the watch (mute, carbs, signed boluses, override and temp target presets). The host applies only its
/// own limits, such as the maximum bolus, so the plugin decides first: the user's switch for the action in the Pebble
/// settings, then Luped's limits (`LupedRemotePolicy.swift`) with LoopKit's shared policy. Each request and its outcome
/// goes to the device log, with the wording the hosts used when they made these checks. Each request is answered on
/// `RESULT`.
extension LupedSmartwatchManager {
    /// Whether Luped Remote is on; without it the plugin never asks the host.
    var isLupedRemoteOn: Bool { Self.linkSettings(settings).remoteEnabled }

    /// Checks the watch's mute request, passes it to the host and logs the outcome.
    @MainActor
    func requestAlertMute(_ duration: TimeInterval, requestedAt: Date?) {
        guard isLupedRemoteOn else {
            logNote("Mute request from the watch ignored: Luped Remote is off", kind: .error)
            transport.sendResult("mute:ignored")
            return
        }
        guard let requestedAt else {
            logNote("Mute request refused: the watch didn't say when it was confirmed (COMMAND without @<confirmedAt>)", kind: .error)
            transport.sendResult("mute:refused", reason: .notVerified)
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Mute request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendResult("mute:failed")
            return
        }
        guard remotePermissions.mute else {
            logNote("Mute request from the watch refused: Allow Mute from Watch is off", kind: .error)
            transport.sendResult("mute:refused", reason: .notAllowed)
            return
        }
        guard Self.requestWindow.contains(requestedAt, now: Date()) else {
            logNote(String(format: "Mute request from the watch refused: expiredRequest (confirmed %.0f s ago)", Date().timeIntervalSince(requestedAt)), kind: .error)
            transport.sendResult("mute:refused", reason: .tooOld)
            return
        }
        Task { @MainActor in
            do {
                let end = try await delegate.smartwatchManager(self, muteAlertsFor: duration)
                let time = DateFormatter.localizedString(from: end, dateStyle: .none, timeStyle: .short)
                // A duration of 0 (mute:cancel) ends the mute.
                logNote(duration > 0 ? "\(Self.hostName) alerts muted from the watch until \(time)" : "\(Self.hostName) alerts unmuted from the watch at \(time)", kind: .info)
                transport.sendResult("mute:ok")
            } catch {
                logNote("\(Self.hostName) refused the watch's mute request (\(error))", kind: .error)
                let answer = Self.answer(for: error)
                transport.sendResult("mute:\(answer.outcome)", reason: answer.reason)
            }
        }
    }

    /// The `RESULT` outcome and reason for an error from the plugin's checks or
    /// the host's: `failed` when the host couldn't carry it out, `refused` with
    /// the reason when it wasn't allowed.
    static func answer(for error: Error) -> (outcome: String, reason: LupedResultReason?) {
        switch refusedError(error) {
        case SmartwatchAlertMuteError.notAllowed, SmartwatchCarbEntryError.notAllowed, SmartwatchPresetError.notAllowed, SmartwatchBolusError.notAllowed:
            return ("refused", .notAllowed)
        case SmartwatchAlertMuteError.expiredRequest, SmartwatchCarbEntryError.expiredRequest, SmartwatchPresetError.expiredRequest, SmartwatchBolusError.expiredRequest:
            return ("refused", .tooOld)
        case SmartwatchCarbEntryError.invalidAmount, SmartwatchBolusError.invalidAmount:
            return ("refused", .invalidAmount)
        case SmartwatchCarbEntryError.exceedsMaximum, SmartwatchBolusError.exceedsMaximumBolus:
            return ("refused", .overMaximum)
        case SmartwatchCarbEntryError.rateLimited, SmartwatchBolusError.rateLimited:
            return ("refused", .tooSoon)
        case SmartwatchBolusError.dailyLimitReached:
            return ("refused", .dailyLimit)
        case SmartwatchBolusError.exceedsRecommendation:
            return ("refused", .overRecommendation)
        case SmartwatchBolusError.staleContext, SmartwatchBolusError.noRecentGlucose:
            return ("refused", .noRecentGlucose)
        case SmartwatchBolusError.inProgress:
            return ("refused", .inProgress)
        case SmartwatchPresetError.unknownPreset:
            return ("refused", .noSuchPreset)
        case SmartwatchBolusError.deliveryFailed:
            // The pump may have delivered some or all of it.
            return ("failed", .checkPump)
        case SmartwatchCarbEntryError.failed, SmartwatchPresetError.failed:
            return ("failed", nil)
        default:
            return ("refused", nil)
        }
    }

    /// Time allowed for the host's new bolus context once a request's carbs are added.
    static let carbsContextTimeout: TimeInterval = 15
    /// Time left for the plugin's and the host's checks once that context is in.
    static let bolusCheckMargin: TimeInterval = 3

    /// Whether a bolus with carbs confirmed at `requestedAt` is young enough
    /// that its bolus can still be checked within `window` after the carbs
    /// and the new context. If not, neither is asked for: carbs without their
    /// bolus would be worse than nothing.
    nonisolated static func leavesTimeForBolusAfterCarbs(requestedAt: Date, now: Date, window: SmartwatchRequestWindow) -> Bool {
        now.timeIntervalSince(requestedAt) + carbsContextTimeout + bolusCheckMargin <= window.maximumAge
    }

    /// A signed bolus the watch chose (LupedKit has checked the signature, timing
    /// and resends): checked with `SmartwatchBolusPolicy` and Luped's limits, then
    /// passed to the host. With carbs, like Loop's and Trio's Apple Watch apps:
    /// the carbs are added first, then the bolus is checked against a new bolus
    /// context, whose recommendation includes them; without the carbs there is
    /// no bolus. The policy checks the switch, request and context age, recent
    /// glucose, maximum bolus, recommendation (skipped when `forced`) and rate
    /// limits; the host then applies its own limits.
    @MainActor
    func requestBolus(_ units: Double, forced: Bool = false, grams: Double? = nil, absorption: LupedCarbAbsorption? = nil, requestedAt: Date) {
        let action = forced ? "signedforcedbolus" : "signedbolus"
        // Answers the request: its carbs first if it had any, then the bolus.
        let answer = { [transport] (carbs: String?, bolus: String, reason: LupedResultReason?) in
            if grams != nil, let carbs {
                transport.sendResult("carbs:\(carbs)", reason: reason)
            }
            transport.sendResult("\(action):\(bolus)", reason: reason)
        }
        guard isLupedRemoteOn else {
            logNote("Bolus request from the watch ignored: Luped Remote is off", kind: .error)
            answer("ignored", "ignored", nil)
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Bolus request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            answer("failed", "failed", nil)
            return
        }
        if grams != nil, !Self.leavesTimeForBolusAfterCarbs(requestedAt: requestedAt, now: Date(), window: Self.requestWindow) {
            logNote(String(format: "Bolus request with carbs refused: confirmed %.0f s ago, too late for the bolus to follow the carbs within %.0f s, so neither is added", Date().timeIntervalSince(requestedAt), Self.requestWindow.maximumAge), kind: .error)
            answer("refused", "refused", .tooOld)
            return
        }
        Task { @MainActor in
            if let grams {
                do {
                    let added = try await addCarbs(grams, absorption: absorption, requestedAt: requestedAt, delegate: delegate, purpose: " before the bolus")
                    logNote(String(format: "%@ added %g g of carbs requested from the watch", Self.hostName, added), kind: .info)
                    transport.sendResult("carbs:ok")
                } catch {
                    logNote("\(Self.refuser(of: error)) refused the watch's carbs (\(Self.refusedError(error))), so the bolus isn't given either", kind: .error)
                    let carbs = Self.answer(for: error)
                    answer(carbs.outcome, "refused", carbs.reason)
                    return
                }
                // The context issued before the carbs recommends too little:
                // issue one that counts them.
                await enqueueHostRead { await $0.issueBolusContext(delegate) }.value
            }
            await passBolus(units, forced: forced, requestedAt: requestedAt, action: action, delegate: delegate)
        }
    }

    /// Checks the bolus against the context last issued, records the attempt and
    /// asks the host to deliver it.
    @MainActor
    private func passBolus(_ units: Double, forced: Bool, requestedAt: Date, action: String, delegate: SmartwatchManagerDelegate) async {
        // The context from every change the host has signalled so far, such as
        // the one issued after the previous bolus, including changes still
        // being collected.
        flushHostChanges()
        await hostReadTask?.value
        let latestGlucoseDate = await self.latestGlucoseDate(delegate)

        // No suspension from here until the attempt is recorded, so a second
        // request can't pass the same checks meanwhile.
        // LupedKit doesn't carry a token: the request quotes the context the
        // plugin issued last. Without one, the policy refuses it as stale.
        let request = SmartwatchBolusRequest(units: units, contextToken: bolusContext?.token ?? UUID(), requestedAt: requestedAt, isForced: forced)
        logNote(String(format: "%@ request: %.3f U, confirmed at %@, context %@", forced ? "Forced bolus (recommendation not checked)" : "Bolus", units, String(describing: requestedAt), bolusContext?.token.uuidString ?? "none"), kind: .info)
        if bolusContextIssuer.isDelivering(request) {
            // LupedKit passes each signed request on once, so this is another
            // request for the bolus being delivered: that one's result follows.
            logNote("Bolus request answered with inProgress: the same bolus is still being delivered", kind: .error)
            transport.sendResult("\(action):refused", reason: .inProgress)
            return
        }
        let context = bolusContextIssuer.current
        let volumes = context?.supportedBolusVolumes ?? []
        let policy = SmartwatchBolusPolicy(
            limits: Self.bolusLimits,
            isAllowed: isLupedRemoteOn && remotePermissions.bolus,
            currentContext: context,
            latestGlucoseDate: latestGlucoseDate,
            recentDeliveries: remoteHistory.bolusDeliveries,
            roundToSupportedVolume: { Self.roundToSupportedBolusVolume($0, volumes: volumes) }
        )
        let allowed: Double
        switch policy.evaluate(request, now: Date()) {
        case .failure(let error):
            let units = { (value: Double?) in value.map { String(format: "%.2f U", $0) } ?? "none" }
            let notAllowedReason = error == .notAllowed ? (isLupedRemoteOn ? "Allow Boluses from Watch is off; " : "Luped Remote is off; ") : ""
            let glucoseAge = error == .noRecentGlucose ? latestGlucoseDate.map { String(format: "newest glucose %.0f min ago; ", Date().timeIntervalSince($0) / 60) } ?? "no glucose; " : ""
            let nextBolus = error == .rateLimited ? remoteHistory.bolusDeliveries.map(\.date).max().map { "5 min between boluses from the watch; next at \(Self.timeText($0.addingTimeInterval(Self.bolusLimits.minimumInterval))); " } ?? "" : ""
            logNote("Bolus request rejected by Luped's checks: \(error) (\(notAllowedReason)\(glucoseAge)\(nextBolus)requested \(units(request.units)), \(Self.hostName) recommends \(units(context?.recommendedBolus ?? 0)), maximum bolus \(units(context?.maximumBolus)))", kind: .error)
            let answer = Self.answer(for: error)
            transport.sendResult("\(action):\(answer.outcome)", reason: answer.reason)
            return
        case .success(let units):
            allowed = units
        }

        bolusContextIssuer.beginDelivery(of: request)
        // Counted for the time between watch boluses from here, whether or not
        // the host reports it delivered: a failure can be uncertain (the pump lost
        // contact mid-bolus), and a resend at once could give it twice. Only a
        // delivered bolus counts toward the daily total.
        let attemptedAt = Date()
        remoteHistory.bolusDeliveries = LupedRemoteHistory.bolusAttempted(at: attemptedAt, in: remoteHistory.bolusDeliveries)
        logNote(String(format: "Asking %@ for a %.2f U %@from the watch", Self.hostName, allowed, forced ? "forced bolus (recommendation not checked) " : "bolus "), kind: .info)
        do {
            let delivered = try await delegate.smartwatchManager(self, deliverBolus: allowed)
            bolusContextIssuer.endDelivery()
            remoteHistory.bolusDeliveries = LupedRemoteHistory.bolusDelivered(delivered, attemptedAt: attemptedAt, in: remoteHistory.bolusDeliveries)
            logNote(String(format: "%@ delivered %.2f U requested from the watch", Self.hostName, delivered), kind: .info)
            transport.sendResult("\(action):ok")
        } catch SmartwatchBolusError.inProgress {
            bolusContextIssuer.endDelivery()
            // The host sent nothing to the pump: like its other refusals, no gap.
            remoteHistory.bolusDeliveries = LupedRemoteHistory.bolusAttemptRefused(at: attemptedAt, in: remoteHistory.bolusDeliveries)
            logNote("\(Self.hostName) is still delivering another bolus; this request is refused", kind: .error)
            transport.sendResult("\(action):refused", reason: .inProgress)
        } catch {
            bolusContextIssuer.endDelivery()
            // Only a bolus the pump was asked for keeps its attempt for the time
            // between boluses; a refusal by the host's own limits sent nothing.
            if case SmartwatchBolusError.deliveryFailed = error {} else {
                remoteHistory.bolusDeliveries = LupedRemoteHistory.bolusAttemptRefused(at: attemptedAt, in: remoteHistory.bolusDeliveries)
            }
            logNote("\(Self.hostName) refused the watch's bolus request (\(error))", kind: .error)
            let answer = Self.answer(for: error)
            transport.sendResult("\(action):\(answer.outcome)", reason: answer.reason)
        }
        // The bolus spent the context: issue the next one.
        enqueueHostRead { await $0.issueBolusContext(delegate) }
    }

    /// Rounds down to a volume the pump supports, as `PumpManager` does by
    /// default; unchanged without volumes (no pump), where the host refuses.
    nonisolated static func roundToSupportedBolusVolume(_ units: Double, volumes: [Double]) -> Double {
        guard !volumes.isEmpty else { return units }
        return volumes.filter { $0 <= units }.max() ?? 0
    }

    /// When the newest glucose reading was taken, CGM or entered, read from the
    /// host now; `nil` when it has none or can't be read.
    @MainActor
    func latestGlucoseDate(_ delegate: SmartwatchManagerDelegate) async -> Date? {
        let samples = try? await delegate.smartwatchManager(self, glucoseSamplesSince: Date(timeIntervalSinceNow: -LupedHostData.glucoseHistoryInterval))
        return samples?.map(\.startDate).max()
    }

    /// The host's absorption time for the watch's fast, medium or slow; `nil`
    /// keeps the host's default. Left out when the host has no per-entry
    /// absorption or no usable times (an older Luped Remote still sends it).
    @MainActor
    func hostAbsorptionTime(_ absorption: LupedCarbAbsorption?) -> TimeInterval? {
        guard let absorption else { return nil }
        guard let times = hostData.carbAbsorptionTimes else {
            logNote("No carb absorption times from \(Self.hostName): the watch's \(absorption.rawValue) is left out", kind: .info)
            return nil
        }
        return times.time(for: absorption)
    }

    /// Answers Luped Remote's question before a bolus: what the host would
    /// recommend with the carbs about to go with it (0 for none). Nothing is
    /// added or delivered. Answered only while boluses from the watch are
    /// allowed and glucose is recent, like a bolus.
    @MainActor
    func requestBolusRecommendation(_ grams: Double, absorption: LupedCarbAbsorption? = nil) {
        guard isLupedRemoteOn else {
            logNote("Bolus recommendation request ignored: Luped Remote is off", kind: .error)
            transport.sendBolusRecommendationRefusal(grams: grams, outcome: "ignored", reason: nil)
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Bolus recommendation request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendBolusRecommendationRefusal(grams: grams, outcome: "failed", reason: nil)
            return
        }
        let absorptionTime = hostAbsorptionTime(absorption)
        logNote(String(format: "Bolus recommendation request with %.0f g of %@ carbs", grams, absorptionTime == nil ? "default" : absorption?.rawValue ?? "default"), kind: .info)
        guard remotePermissions.bolus else {
            logNote("Bolus recommendation refused: Allow Boluses from Watch is off", kind: .error)
            transport.sendBolusRecommendationRefusal(grams: grams, outcome: "refused", reason: .notAllowed)
            return
        }
        Task { @MainActor in
            let maximumGlucoseAge = Self.bolusLimits.maximumGlucoseAge
            guard let latestGlucoseDate = await latestGlucoseDate(delegate), Date().timeIntervalSince(latestGlucoseDate) <= maximumGlucoseAge else {
                logNote("Bolus recommendation refused: no glucose in the last \(Int(maximumGlucoseAge / 60)) minutes", kind: .error)
                transport.sendBolusRecommendationRefusal(grams: grams, outcome: "refused", reason: .noRecentGlucose)
                return
            }
            do {
                let units = try await delegate.smartwatchManager(self, recommendBolusForCarbs: grams, absorptionTime: absorptionTime)
                let maximumBolus = await delegate.smartwatchManagerMaximumBolus(self)
                logNote(String(format: "%@ recommends %.2f U with %g g of carbs", Self.hostName, units, grams), kind: .info)
                transport.sendBolusRecommendation(grams: grams, units: units, maximumBolus: maximumBolus)
            } catch {
                logNote("\(Self.hostName) gave no bolus recommendation (\(error))", kind: .error)
                let answer = Self.answer(for: error)
                transport.sendBolusRecommendationRefusal(grams: grams, outcome: answer.outcome, reason: answer.reason)
            }
        }
    }

    /// Checks the carbs with `SmartwatchCarbEntryPolicy` and Luped's limits, takes
    /// the rate-limit slot and asks the host to add them, logging each step.
    ///
    /// - Returns: The grams the host added.
    /// - Throws: `SmartwatchCarbEntryError` from the checks, or the host's error.
    @MainActor
    private func addCarbs(_ grams: Double, absorption: LupedCarbAbsorption?, requestedAt: Date, delegate: SmartwatchManagerDelegate, purpose: String = "") async throws -> Double {
        let absorptionTime = hostAbsorptionTime(absorption)
        logNote(String(format: "Carb entry request: %.0f g, %@ absorption, confirmed at %@", grams, absorptionTime == nil ? "default" : absorption?.rawValue ?? "default", String(describing: requestedAt)), kind: .info)
        let maximumGrams = await delegate.smartwatchManagerMaximumCarbEntry(self)

        // No suspension from here until the slot is taken.
        let refusal: String? = if !isLupedRemoteOn {
            "Luped Remote is off"
        } else if !remotePermissions.carbs {
            "Allow Carbs from Watch is off"
        } else {
            nil
        }
        let history = remoteHistory
        let previousEntry = history.lastCarbEntry
        let policy = SmartwatchCarbEntryPolicy(
            limits: Self.carbEntryLimits,
            isAllowed: refusal == nil,
            // The host applies its own maximum in any case.
            maximumGrams: maximumGrams ?? .infinity,
            lastEntry: previousEntry
        )
        if case .failure(let error) = policy.evaluate(SmartwatchCarbEntryRequest(grams: grams, requestedAt: requestedAt), now: Date()) {
            let next = error == .rateLimited ? previousEntry.map { "5 min between entries from the watch; next at \(Self.timeText($0.addingTimeInterval(Self.carbEntryLimits.minimumInterval)))" } : nil
            let detail = [refusal, next].compactMap { $0 }.joined(separator: "; ")
            logNote("Carb entry request rejected: \(error)\(detail.isEmpty ? "" : " (\(detail))")", kind: .error)
            throw LupedRemoteRefusal(error: error)
        }
        // Take the slot before asking the host, so a resend that arrives meanwhile
        // is rate limited instead of adding the carbs a second time.
        history.lastCarbEntry = Date()
        logNote(String(format: "Asking %@ to add %g g of carbs from the watch%@", Self.hostName, grams, purpose), kind: .info)
        do {
            return try await delegate.smartwatchManager(self, addCarbEntry: grams, absorptionTime: absorptionTime, date: requestedAt)
        } catch {
            history.lastCarbEntry = previousEntry
            throw error
        }
    }

    /// Checks the carb entry the watch chose, asks the host to add it and logs
    /// the outcome.
    @MainActor
    func requestCarbs(_ grams: Double, absorption: LupedCarbAbsorption? = nil, requestedAt: Date?) {
        guard isLupedRemoteOn else {
            logNote("Carb request from the watch ignored: Luped Remote is off", kind: .error)
            transport.sendResult("carbs:ignored")
            return
        }
        guard let requestedAt else {
            logNote("Carb request refused: the watch didn't say when it was confirmed (COMMAND without @<confirmedAt>)", kind: .error)
            transport.sendResult("carbs:refused", reason: .notVerified)
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Carb request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendResult("carbs:failed")
            return
        }
        Task { @MainActor in
            do {
                let grams = try await addCarbs(grams, absorption: absorption, requestedAt: requestedAt, delegate: delegate)
                logNote(String(format: "%@ added %g g of carbs requested from the watch", Self.hostName, grams), kind: .info)
                transport.sendResult("carbs:ok")
            } catch {
                logNote("\(Self.refuser(of: error)) refused the watch's carb request (\(Self.refusedError(error)))", kind: .error)
                let answer = Self.answer(for: error)
                transport.sendResult("carbs:\(answer.outcome)", reason: answer.reason)
            }
        }
    }

    /// Asks the host to start the override preset the watch named (by id, or by
    /// name ignoring case, from the host's presets last read) or to end the
    /// running one, and logs the outcome. Only with Allow Presets from Watch on,
    /// and within the request window.
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

        /// The `<action>` of its `RESULT`.
        var action: String { self == .override ? "override" : "temptarget" }
        var noun: String { self == .override ? "preset" : "temp target" }
        var permission: String { self == .override ? "Allow Presets from Watch" : "Allow Temp Targets from Watch" }

        func isAllowed(by permissions: LupedRemotePermissions) -> Bool {
            self == .override ? permissions.overrides : permissions.tempTargets
        }
    }

    @MainActor
    private func requestPreset(_ action: LupedPresetAction, requestedAt: Date?, kind: PresetKind) {
        let request = kind.noun.prefix(1).uppercased() + kind.noun.dropFirst() + " request"
        guard isLupedRemoteOn else {
            logNote("\(request) from the watch ignored: Luped Remote is off", kind: .error)
            transport.sendResult("\(kind.action):ignored")
            return
        }
        guard let requestedAt else {
            logNote("\(request) refused: the watch didn't say when it was confirmed (COMMAND without @<confirmedAt>)", kind: .error)
            transport.sendResult("\(kind.action):refused", reason: .notVerified)
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
            logNote("\(request): end the running \(kind.noun), confirmed at \(requestedAt)", kind: .info)
        case .start(let wanted):
            let presets = (kind == .override ? hostData.presets?.overrides : hostData.presets?.tempTargets ?? nil) ?? []
            guard let preset = presets.first(where: { $0.id == wanted })
                ?? presets.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
            else {
                let known = presets.isEmpty ? "it has none" : presets.map { "\"\($0.name)\"" }.joined(separator: ", ")
                logNote("\(request) refused: \(Self.hostName) has no \(kind.noun) \"\(wanted)\" (\(known))", kind: .error)
                transport.sendResult("\(kind.action):refused", reason: .noSuchPreset)
                return
            }
            presetAction = .activate(presetID: preset.id)
            logNote("\(request): start \"\(preset.name)\", confirmed at \(requestedAt)", kind: .info)
        }
        guard kind.isAllowed(by: remotePermissions) else {
            logNote("\(request) rejected: notAllowed (\(kind.permission) is off)", kind: .error)
            transport.sendResult("\(kind.action):refused", reason: .notAllowed)
            return
        }
        guard Self.requestWindow.contains(requestedAt, now: Date()) else {
            logNote(String(format: "%@ rejected: expiredRequest (confirmed %.0f s ago)", request, Date().timeIntervalSince(requestedAt)), kind: .error)
            transport.sendResult("\(kind.action):refused", reason: .tooOld)
            return
        }
        Task { @MainActor in
            do {
                switch kind {
                case .override:
                    try await delegate.smartwatchManager(self, enactOverride: presetAction)
                case .tempTarget:
                    try await delegate.smartwatchManager(self, enactTempTarget: presetAction)
                }
                logNote("\(Self.hostName) \(action == .cancel ? "ended the running" : "started the") \(kind.noun) requested from the watch", kind: .info)
                transport.sendResult("\(kind.action):ok")
            } catch {
                logNote("\(Self.hostName) refused the watch's \(kind.noun) request (\(error))", kind: .error)
                let answer = Self.answer(for: error)
                transport.sendResult("\(kind.action):\(answer.outcome)", reason: answer.reason)
            }
        }
    }
}

/// A request Luped's own checks refused before the host was asked, so the log
/// doesn't blame the host for it. The watch gets the same answer either way.
struct LupedRemoteRefusal: Error {
    let error: Error
}

extension LupedSmartwatchManager {
    /// Who refused: Luped's own checks or the host.
    static func refuser(of error: Error) -> String {
        error is LupedRemoteRefusal ? "Luped's checks" : hostName
    }

    /// The refusal itself, without the wrapper.
    static func refusedError(_ error: Error) -> Error {
        (error as? LupedRemoteRefusal)?.error ?? error
    }

    /// A time of day for the log, with seconds.
    static func timeText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }
}
