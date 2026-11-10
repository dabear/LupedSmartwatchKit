//
//  LupedSmartwatchManager+HostData.swift
//  LupedSmartwatchKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import LupedKit

/// What the plugin last read from the host for the watch, in the host's own
/// types. Each part is read after a change that can affect it, and only while
/// the watch shows it (`LupedSmartwatchManager.HostReads`); `lupedSnapshot()`
/// converts it to LupedKit's wire model at the edge.
struct LupedHostData {
    /// How far back glucose is read. The watch gets the last
    /// `LupedPayload.historyInterval` of it.
    static let glucoseHistoryInterval: TimeInterval = 3 * 60 * 60

    /// `nil` until the host's settings were first read: nothing is sent before.
    var displayUnit: LoopUnit?
    /// Stored readings from the last `glucoseHistoryInterval`, oldest first,
    /// user-entered and display-only ones included.
    var glucoseSamples: [StoredGlucoseSample] = []
    var loopState: SmartwatchLoopState?
    var therapy: Therapy?
    var presets: Presets?
    /// `nil` for a host whose carbs have no per-entry absorption time (Trio),
    /// or whose times aren't usable: Luped Remote then doesn't ask for one.
    var carbAbsorptionTimes: CarbAbsorptionTimes?

    struct Therapy {
        var tempBasal: DoseEntry?
        var scheduledBasalRate: LoopQuantity?
        var insulinSensitivity: LoopQuantity?
        var correctionRange: ClosedRange<LoopQuantity>?
    }

    struct Presets {
        var overrides: [TemporaryPreset]
        var activeOverride: TemporaryScheduleOverride?
        /// `nil` for a host without temp targets (Loop).
        var tempTargets: [TemporaryPreset]?
        var activeTempTarget: TemporaryScheduleOverride?
    }

    /// The host's fast, medium and slow carb absorption times.
    struct CarbAbsorptionTimes: Equatable {
        var fast: TimeInterval
        var medium: TimeInterval
        var slow: TimeInterval

        /// The host's time for the watch's choice.
        func time(for absorption: LupedCarbAbsorption) -> TimeInterval {
            switch absorption {
            case .fast: fast
            case .medium: medium
            case .slow: slow
            }
        }
    }

    /// The newest reading's date, CGM or entered by the user.
    var latestGlucoseDate: Date? {
        glucoseSamples.map(\.startDate).max()
    }

    // MARK: Units

    // A LoopQuantity in an incompatible unit traps in `doubleValue(for:)`, so
    // each conversion checks the unit first and gives nil for anything else.

    /// mg/dL, from a glucose value in mg/dL or mmol/L.
    static func milligramsPerDeciliter(_ quantity: LoopQuantity) -> Double? {
        quantity.is(compatibleWith: .milligramsPerDeciliter) ? quantity.doubleValue(for: .milligramsPerDeciliter) : nil
    }

    /// mg/dL per unit, from an insulin sensitivity in mg/dL or mmol/L, with or
    /// without the per-unit part (hosts store it either way).
    static func sensitivityMilligramsPerDeciliter(_ quantity: LoopQuantity) -> Double? {
        if quantity.is(compatibleWith: .milligramsPerDeciliterPerInternationalUnit) {
            return quantity.doubleValue(for: .milligramsPerDeciliterPerInternationalUnit)
        }
        return milligramsPerDeciliter(quantity)
    }

    /// U/h, from a basal rate.
    static func unitsPerHour(_ quantity: LoopQuantity) -> Double? {
        quantity.is(compatibleWith: .internationalUnitsPerHour) ? quantity.doubleValue(for: .internationalUnitsPerHour) : nil
    }

    /// The presets as Luped Remote lists them, with the running one marked: the
    /// one whose override context is that preset.
    static func lupedPresets(_ presets: [TemporaryPreset], active: TemporaryScheduleOverride?, now: Date = Date()) -> [LupedPreset] {
        let runningID: String? = if let active, active.isActive(at: now), case .preset(let preset) = active.context { preset.id } else { nil }
        return presets.map { LupedPreset(id: $0.id, name: $0.name, isActive: $0.id == runningID) }
    }
}

extension LupedSmartwatchManager {
    /// Reads what changed, then sends the watch what it now shows. Only what
    /// the watch shows is read: glucose always, the loop state and therapy
    /// values for the chosen display, presets and the bolus context while Luped
    /// Remote is on. A new reading is sent before the loop runs on it, with the
    /// previous loop result; LupedKit holds it briefly for the loop result.
    ///
    /// A host reports each change at once, and one loop cycle brings several
    /// (Trio: the reading, its save, IOB, the loop date, the determination), so
    /// changes are collected for `hostChangeCoalescingInterval` and read
    /// together. `.all` is read at once. A bolus request reads the collected
    /// changes first (`flushHostChanges`), so it is checked against everything
    /// the host has signalled.
    @MainActor
    public func hostDataDidChange(_ changes: SmartwatchHostDataChange) {
        // The alert mute isn't shown on the watch.
        guard !changes.isDisjoint(with: [.glucose, .loop, .presets, .settings]) else { return }
        pendingHostChanges.formUnion(changes)
        guard changes != .all, Self.hostChangeCoalescingInterval > 0 else {
            flushHostChanges()
            return
        }
        guard pendingHostChangesTask == nil else { return }
        pendingHostChangesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hostChangeCoalescingInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushHostChanges()
        }
    }

    /// How long changes from the host are collected before they are read.
    @MainActor static var hostChangeCoalescingInterval: TimeInterval = 1

    /// Reads the changes collected so far, now.
    @MainActor
    func flushHostChanges() {
        pendingHostChangesTask?.cancel()
        pendingHostChangesTask = nil
        let changes = pendingHostChanges
        pendingHostChanges = []
        guard !changes.isEmpty else { return }
        enqueueHostRead { manager in
            await manager.readHostData(changes)
            await manager.transport.refresh()
        }
    }

    /// Runs `work` after the host reads queued before it, so a slower read can't
    /// overwrite a newer one, and a bolus context can't be issued from older inputs.
    @MainActor
    @discardableResult
    func enqueueHostRead(_ work: @escaping @MainActor (LupedSmartwatchManager) async -> Void) -> Task<Void, Never> {
        let previous = hostReadTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        hostReadTask = task
        return task
    }

    @MainActor
    func readHostData(_ changes: SmartwatchHostDataChange) async {
        guard let delegate = smartwatchManagerDelegate else { return }
        let reads = hostReads
        if changes.contains(.settings) {
            hostData.displayUnit = await delegate.smartwatchManagerGlucoseDisplayUnit(self)
            hostData.carbAbsorptionTimes = usableCarbAbsorptionTimes(await delegate.smartwatchManagerDefaultCarbAbsorptionTimes(self))
        }
        if changes.contains(.glucose) {
            do {
                hostData.glucoseSamples = try await delegate.smartwatchManager(self, glucoseSamplesSince: Date(timeIntervalSinceNow: -LupedHostData.glucoseHistoryInterval))
            } catch {
                logNote(String(format: "Unable to read glucose from %@: %@", Self.hostName, String(describing: error)), kind: .error)
            }
        }
        if !reads.loopState {
            hostData.loopState = nil
        } else if changes.contains(.loop) {
            hostData.loopState = await delegate.smartwatchManagerLoopState(self)
        }
        // Read on every change: the basal rate, sensitivity and target follow the
        // time of day, so a new reading is when a schedule's next value shows.
        if !reads.therapy {
            hostData.therapy = nil
        } else {
            hostData.therapy = LupedHostData.Therapy(
                tempBasal: await delegate.smartwatchManagerTempBasal(self),
                scheduledBasalRate: await delegate.smartwatchManagerScheduledBasalRate(self),
                insulinSensitivity: await delegate.smartwatchManagerInsulinSensitivity(self),
                correctionRange: await delegate.smartwatchManagerCorrectionRange(self)
            )
        }
        if !reads.remote {
            hostData.presets = nil
        } else if changes.contains(.presets) {
            hostData.presets = LupedHostData.Presets(
                overrides: await delegate.smartwatchManagerOverridePresets(self),
                activeOverride: await delegate.smartwatchManagerActiveOverride(self),
                tempTargets: await delegate.smartwatchManagerTempTargetPresets(self),
                activeTempTarget: await delegate.smartwatchManagerActiveTempTarget(self)
            )
        }
        // A new context after every change to what a recommendation is computed
        // from (presets change the target), so a bolus is checked against the
        // host's current state.
        if reads.remote {
            await issueBolusContext(delegate)
        }
    }

    /// The host's absorption times, or `nil` when it has none or any of them
    /// isn't a finite time above zero. Such a set is treated as none, so it is
    /// never passed back to the host: Luped Remote doesn't ask, and carbs get
    /// the host's default. Logged on each settings read that returns one.
    @MainActor
    func usableCarbAbsorptionTimes(_ times: (fast: TimeInterval, medium: TimeInterval, slow: TimeInterval)?) -> LupedHostData.CarbAbsorptionTimes? {
        guard let times else { return nil }
        guard [times.fast, times.medium, times.slow].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            logNote("\(Self.hostName)'s carb absorption times aren't usable (fast \(times.fast) s, medium \(times.medium) s, slow \(times.slow) s): the watch's choice is left out and carbs get \(Self.hostName)'s default", kind: .error)
            return nil
        }
        return LupedHostData.CarbAbsorptionTimes(fast: times.fast, medium: times.medium, slow: times.slow)
    }

    /// Issues the bolus context from the host's recommendation now, its maximum
    /// bolus and the pump's volumes. The issuer keeps the token while these and
    /// the newest reading are unchanged; a bolus made against an older state is
    /// refused as a stale context.
    @MainActor
    func issueBolusContext(_ delegate: SmartwatchManagerDelegate) async {
        let recommendedBolus = try? await delegate.smartwatchManager(self, recommendBolusForCarbs: 0, absorptionTime: nil)
        let maximumBolus = await delegate.smartwatchManagerMaximumBolus(self)
        let supportedBolusVolumes = await delegate.smartwatchManagerSupportedBolusVolumes(self)
        let inputs = SmartwatchBolusContextIssuer.Inputs(
            recommendedBolus: recommendedBolus,
            maximumBolus: maximumBolus,
            supportedBolusVolumes: supportedBolusVolumes,
            latestGlucoseDate: hostData.latestGlucoseDate
        )
        bolusContext = bolusContextIssuer.context(for: inputs, now: Date())
    }

    /// Whether the host has temp targets (Trio), for the settings' temp target
    /// switch. Read while Luped Remote is on.
    @MainActor
    public var hostHasTempTargets: Bool {
        hostData.presets?.tempTargets != nil
    }

    /// The next payload's data, from what was last read from the host; `nil`
    /// before the first read. Converted here, at the edge, into LupedKit's wire
    /// model: glucose in mg/dL whatever the display unit, which the watch gets
    /// separately.
    @MainActor
    func lupedSnapshot() -> LupedSnapshot? {
        guard let displayUnit = hostData.displayUnit else {
            return nil
        }
        let linkSettings = Self.linkSettings(settings)
        let start = Date(timeIntervalSinceNow: -LupedPayload.historyInterval)
        let samples = hostData.glucoseSamples.filter { $0.startDate >= start }
        let readings = samples
            .filter { !$0.wasUserEntered && !$0.isDisplayOnly }
            .compactMap { sample in
                LupedHostData.milligramsPerDeciliter(sample.quantity).map {
                    LupedReading(date: sample.startDate, milligramsPerDeciliter: $0, trend: sample.trend.map(LupedTrend.init))
                }
            }
        // As read for the chosen display; the payload sends only what it shows.
        let loopState = linkSettings.hostNeedsLoopStatus ? hostData.loopState : nil
        let presets = linkSettings.remoteEnabled ? hostData.presets : nil
        return LupedSnapshot(
            readings: readings,
            storedSampleCount: samples.count,
            unit: displayUnit == .millimolesPerLiter ? .millimolesPerLiter : .milligramsPerDeciliter,
            hostAlertState: hostAlertState,
            hostAlertReason: hostAlertReason,
            alertEvent: alertEvent,
            // IOB, COB and the loop's age and mode for the watch's strip and loop ring.
            loopStatus: LupedLoopStatus(
                insulinOnBoard: loopState?.insulinOnBoard?.value,
                carbsOnBoard: loopState?.carbsOnBoard?.quantity.doubleValue(for: .gram),
                lastLoopCompleted: loopState?.lastLoopCompleted,
                isClosedLoop: loopState?.isClosedLoop
            ),
            therapy: settings.needsTherapy ? lupedTherapy() : nil,
            // For Luped Remote's preset lists.
            overridePresets: presets.map { LupedHostData.lupedPresets($0.overrides, active: $0.activeOverride) },
            // nil hides temp targets on the watch: a host without them (Loop).
            tempTargetPresets: presets.flatMap { presets in presets.tempTargets.map { LupedHostData.lupedPresets($0, active: presets.activeTempTarget) } },
            // Without absorption times (Trio), Luped Remote doesn't ask how fast carbs are absorbed.
            usesCarbAbsorption: hostData.carbAbsorptionTimes != nil
        )
    }

    /// The therapy values in mg/dL and U/h; `nil` until they were read.
    @MainActor
    func lupedTherapy() -> LupedTherapy? {
        guard let therapy = hostData.therapy else {
            return nil
        }
        let range = therapy.correctionRange.flatMap { range in
            LupedHostData.milligramsPerDeciliter(range.lowerBound).flatMap { lower in
                LupedHostData.milligramsPerDeciliter(range.upperBound).map { lower...max(lower, $0) }
            }
        }
        return LupedTherapy(
            tempBasalRate: therapy.tempBasal?.unitsPerHour,
            scheduledBasalRate: therapy.scheduledBasalRate.flatMap(LupedHostData.unitsPerHour),
            insulinSensitivity: therapy.insulinSensitivity.flatMap(LupedHostData.sensitivityMilligramsPerDeciliter),
            eventualGlucose: hostData.loopState?.eventualGlucose.flatMap(LupedHostData.milligramsPerDeciliter),
            correctionRange: range
        )
    }
}

extension LupedTrend {
    init(_ trend: GlucoseTrend) {
        switch trend {
        case .downDownDown: self = .doubleDown
        case .downDown: self = .singleDown
        case .down: self = .fortyFiveDown
        case .flat: self = .flat
        case .up: self = .fortyFiveUp
        case .upUp: self = .singleUp
        case .upUpUp: self = .doubleUp
        }
    }
}
