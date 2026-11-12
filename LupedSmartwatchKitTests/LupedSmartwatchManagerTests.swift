//
//  LupedSmartwatchManagerTests.swift
//  LupedSmartwatchKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
import LupedKit
@testable import LupedSmartwatchKit

@MainActor
final class LupedSmartwatchManagerTests: XCTestCase {
    private let start = Date(timeIntervalSinceNow: -1_800)

    private func sample(_ mgdl: Double, minutes: Double, trend: GlucoseTrend? = .flat, wasUserEntered: Bool = false) -> StoredGlucoseSample {
        StoredGlucoseSample(
            startDate: start.addingTimeInterval(minutes * 60),
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl),
            trend: trend,
            wasUserEntered: wasUserEntered
        )
    }

    /// Polls until `condition` holds, for work the manager does in a task.
    private func waitUntil(_ message: String = "", _ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    func testRawStateRoundTrips() throws {
        let settings = LupedSettings(isEnabled: true, watchfaceUUID: UUID(), alarmsEnabled: false, fullScreen: true)
        let manager = LupedSmartwatchManager(settings: settings)
        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.settings, settings)
        XCTAssertEqual(restored.remotePermissions, .none)
    }

    // Only what the watch shows is read from the host (status line and loop ring).
    func testHostReadsFollowTheStatusLineAndLoopRing() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .none, loopRing: false, remoteEnabled: false))
        XCTAssertEqual(manager.hostReads, .init(loopState: false, therapy: false, remote: false))

        manager.settings.loopRing = true
        XCTAssertEqual(manager.hostReads, .init(loopState: true, therapy: false, remote: false), "None with the loop ring still needs the loop's age")

        manager.settings.statusLine = .iobAndCob
        XCTAssertEqual(manager.hostReads, .init(loopState: true, therapy: false, remote: false))

        manager.settings.statusLine = .eventualGlucose
        XCTAssertEqual(manager.hostReads, .init(loopState: true, therapy: true, remote: false))

        manager.settings.loopRing = false
        XCTAssertEqual(manager.hostReads, .init(loopState: true, therapy: true, remote: false), "a shown line keeps the loop ring")

        manager.settings.fullScreen = true
        XCTAssertEqual(manager.hostReads, .init(loopState: false, therapy: false, remote: false), "Large Glucose shows no status line or last loop")
        manager.settings.fullScreen = false
        XCTAssertEqual(manager.hostReads, .init(loopState: true, therapy: true, remote: false), "the chosen line comes back")
    }

    // The host's errors become RESULT outcomes with a reason the watch shows.
    func testHostErrorsBecomeOutcomesWithReasons() {
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchCarbEntryError.rateLimited) == ("refused", .tooSoon))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchBolusError.exceedsMaximumBolus) == ("refused", .overMaximum))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchAlertMuteError.notAllowed) == ("refused", .notAllowed))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchPresetError.unknownPreset) == ("refused", .noSuchPreset))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchBolusError.deliveryFailed("pump")) == ("failed", .checkPump), "the pump may have delivered some of it")
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchBolusError.refusedByHost("no")) == ("refused", nil))
    }

    // Luped Remote shows IOB and COB whatever the watchface shows.
    func testLupedRemoteAlwaysNeedsTheLoopStatus() {
        // Luped Remote is off by default; turned on, it needs the loop status.
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, fullScreen: true))
        XCTAssertEqual(manager.hostReads, .init(loopState: false, therapy: false, remote: false))
        manager.settings.remoteEnabled = true
        XCTAssertEqual(manager.hostReads, .init(loopState: true, therapy: false, remote: true))
        manager.settings.remoteEnabled = false
        XCTAssertEqual(manager.hostReads, .init(loopState: false, therapy: false, remote: false))
    }

    // A bolus with carbs is refused whole when its bolus couldn't follow the
    // carbs within the request window: never carbs without their bolus.
    func testABolusWithCarbsNeedsTimeForTheBolusAfterTheCarbs() {
        let window = LupedSmartwatchManager.requestWindow
        let now = Date()
        XCTAssertTrue(LupedSmartwatchManager.leavesTimeForBolusAfterCarbs(requestedAt: now.addingTimeInterval(-2), now: now, window: window))
        XCTAssertTrue(LupedSmartwatchManager.leavesTimeForBolusAfterCarbs(requestedAt: now.addingTimeInterval(-12), now: now, window: window))
        XCTAssertFalse(LupedSmartwatchManager.leavesTimeForBolusAfterCarbs(requestedAt: now.addingTimeInterval(-13), now: now, window: window), "the bolus could be too old once the carbs are in")
    }

    // Luped's limits are the ones Loop applied to every watch before the checks
    // moved into the plugin, so the watch sees no change.
    func testLupedLimitsAreTheOnesHostsApplied() {
        XCTAssertEqual(LupedSmartwatchManager.requestWindow, SmartwatchRequestWindow(maximumAge: 30, maximumClockSkew: 5))
        let bolus = LupedSmartwatchManager.bolusLimits
        XCTAssertEqual(bolus.requestWindow, LupedSmartwatchManager.requestWindow)
        XCTAssertEqual(bolus.maximumContextAge, 15 * 60)
        XCTAssertEqual(bolus.maximumGlucoseAge, 15 * 60)
        XCTAssertEqual(bolus.minimumInterval, 5 * 60)
        XCTAssertEqual(bolus.dailyLimitInMaximumBoluses, 3)
        XCTAssertTrue(bolus.requiresContextToken)
        XCTAssertTrue(bolus.capsAtRecommendation)
        XCTAssertEqual(LupedSmartwatchManager.carbEntryLimits, SmartwatchCarbEntryPolicy.Limits(requestWindow: LupedSmartwatchManager.requestWindow, minimumInterval: 5 * 60))
    }

    // Luped Remote can be left out of a build; its saved switch is then
    // ignored, so its watch session never opens.
    func testLupedRemoteCanBeLeftOut() {
        XCTAssertTrue(LupedSmartwatchManager.offersLupedRemote, "this build offers Luped Remote")
        let on = LupedSettings(isEnabled: true, remoteEnabled: true)
        XCTAssertFalse(LupedSmartwatchManager.linkSettings(on, offersLupedRemote: false).servesRemote)
        XCTAssertFalse(LupedSmartwatchManager.linkSettings(on, offersLupedRemote: false).remoteEnabled, "nor reads the host's loop status for it")
        XCTAssertTrue(LupedSmartwatchManager.linkSettings(on, offersLupedRemote: true).servesRemote)
    }

    func testSettingsChangesSaveState() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        manager.settings.fullScreen = true
        XCTAssertEqual(delegate.stateUpdates, 1)
        manager.settings.fullScreen = true
        XCTAssertEqual(delegate.stateUpdates, 1, "An unchanged value is not saved again")
    }

    /// Luped's communication log reaches the host's device log, keyed by the
    /// watchface UUID, with each kind mapped to its device log type.
    func testCommunicationLogReachesDeviceLog() async throws {
        let uuid = UUID()
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, watchfaceUUID: uuid))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        _ = manager.transport

        // The test runner has no background modes, so starting the link warns once.
        XCTAssertFalse(LupedSmartwatchManager.hasBluetoothPeripheralBackgroundMode())
        XCTAssertEqual(delegate.logEntries.map(\.type), [.error])
        XCTAssertTrue(delegate.logEntries.first?.message.contains("bluetooth-peripheral") == true)
        delegate.logEntries.removeAll()

        // A settings change is recorded by LupedTransport itself.
        manager.settings.alarmsEnabled = false
        for _ in 0..<50 where delegate.logEntries.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entry = try XCTUnwrap(delegate.logEntries.first)
        XCTAssertEqual(entry.deviceIdentifier, uuid.uuidString.lowercased())
        XCTAssertEqual(entry.type, .connection)
        XCTAssertEqual(entry.message, "Watch Alarms off: the watch won't buzz")

        delegate.logEntries.removeAll()
        manager.logDeviceCommunication("to", kind: .toWatch)
        manager.logDeviceCommunication("from", kind: .fromWatch)
        manager.logDeviceCommunication("error", kind: .error)
        manager.logDeviceCommunication("info", kind: .info)
        XCTAssertEqual(delegate.logEntries.map(\.type), [.send, .receive, .error, .connection])
    }

    /// Host alert notes and the plugin's own alert lines show in the in-app log.
    /// Host notes are not echoed to the device log, which the host already wrote.
    func testAlertNotesShowInCommunicationLog() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let log = manager.transport.communicationLog
        log.clear()
        delegate.logEntries.removeAll()

        issue(manager, glucoseAlert("high", title: "High Glucose"))
        XCTAssertTrue(log.entries.last?.message.hasPrefix("\(LupedSmartwatchManager.hostName) alert issued [warning], event \(manager.alertEvent): High Glucose") == true, log.text)
        XCTAssertEqual(delegate.logEntries.count, 1)

        manager.watchHostDidLog("Next alert: from 11:25 if glucose stays above 10.0 mmol/L")
        XCTAssertEqual(log.entries.last?.message, "\(LupedSmartwatchManager.hostName): Next alert: from 11:25 if glucose stays above 10.0 mmol/L")
        XCTAssertEqual(log.entries.last?.kind, .info)
        XCTAssertEqual(delegate.logEntries.count, 1, "The host already logged its note")
    }

    /// Luped Remote's recommendation request reaches the host with its carbs, and
    /// the host's answer goes back as RECOMMEND, with the maximum bolus. Without
    /// recent glucose it is refused before the host is asked. With no remote
    /// running here, the answer is logged as not sent.
    func testBolusRecommendationRequestReachesTheHost() async throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, remoteEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        manager.remotePermissions.bolus = true
        let log = manager.transport.communicationLog
        delegate.glucoseSamples = [StoredGlucoseSample(startDate: Date(timeIntervalSinceNow: -120), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 120))]
        delegate.recommendation = .success(0.45)

        manager.requestBolusRecommendation(10)
        try await waitUntil(log.text) { log.entries.contains { $0.message == "RECOMMEND 10:ok:0.45:5 not sent: Luped Remote is no longer running" } }
        XCTAssertEqual(delegate.recommendationRequests, [10])

        delegate.glucoseSamples = [StoredGlucoseSample(startDate: Date(timeIntervalSinceNow: -16 * 60), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 120))]
        manager.requestBolusRecommendation(0)
        try await waitUntil(log.text) { log.entries.contains { $0.message == "RECOMMEND 0:refused:no recent glucose not sent: Luped Remote is no longer running" } }
        XCTAssertEqual(delegate.recommendationRequests, [10], "Not asked without recent glucose")
    }

    /// Delete from the settings screen asks the host to remove the manager and
    /// switches the Bluetooth link off.
    func testDeleteRemovesTheManagerAndStopsTheLink() async {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        manager.transportIfStarted = LupedTransport(hostName: LupedSmartwatchManager.hostName, settings: manager.settings)

        await manager.delete()

        XCTAssertEqual(delegate.deletions, 1)
        XCTAssertEqual(manager.transportIfStarted?.settings.isEnabled, false)
    }

    func testHostDataBecomesLupedSnapshot() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        XCTAssertNil(manager.lupedSnapshot(), "Nothing to send before the first read")

        manager.hostData.displayUnit = .millimolesPerLiter
        manager.hostData.glucoseSamples = [
            sample(100, minutes: 0),
            sample(250, minutes: 2, wasUserEntered: true),
            sample(110, minutes: 5, trend: .upUp),
        ]

        let snapshot = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(snapshot.unit, .millimolesPerLiter)
        XCTAssertEqual(snapshot.storedSampleCount, 3)
        XCTAssertEqual(snapshot.readings.map(\.milligramsPerDeciliter), [100, 110], "User-entered samples are not CGM readings")
        XCTAssertEqual(snapshot.readings.last?.trend, .singleUp)
        // Alerts are host-issued: no alert has fired yet.
        XCTAssertEqual(snapshot.hostAlertState, 0)
        XCTAssertEqual(snapshot.alertEvent, manager.alertEvent)
    }

    /// The wire model is mg/dL whatever the host's units: glucose, eventual
    /// glucose, ISF (with or without the per-unit part) and target range given in
    /// mmol/L arrive in mg/dL, basal in U/h.
    func testHostUnitsBecomeMilligramsPerDeciliter() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .sensitivityAndTarget))
        let mmol = { (value: Double) in LoopQuantity(unit: .millimolesPerLiter, doubleValue: value) }
        manager.hostData.displayUnit = .millimolesPerLiter
        manager.hostData.glucoseSamples = [StoredGlucoseSample(startDate: start, quantity: mmol(5.5))]
        manager.hostData.loopState = SmartwatchLoopState(lastLoopCompleted: start, isClosedLoop: true, eventualGlucose: mmol(7))
        manager.hostData.therapy = LupedHostData.Therapy(
            tempBasal: DoseEntry(type: .tempBasal, startDate: start, endDate: start.addingTimeInterval(1_800), value: 0.4, unit: .unitsPerHour),
            scheduledBasalRate: LoopQuantity(unit: .internationalUnitsPerHour, doubleValue: 0.85),
            insulinSensitivity: LoopQuantity(unit: .millimolesPerLiterPerInternationalUnit, doubleValue: 2.5),
            correctionRange: mmol(5.5)...mmol(6.1)
        )

        let snapshot = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(snapshot.unit, .millimolesPerLiter, "The display unit goes separately")
        XCTAssertEqual(try XCTUnwrap(snapshot.readings.first?.milligramsPerDeciliter), 99.09, accuracy: 0.01)
        let therapy = try XCTUnwrap(snapshot.therapy)
        XCTAssertEqual(try XCTUnwrap(therapy.eventualGlucose), 126.11, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(therapy.insulinSensitivity), 45.04, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(therapy.correctionRange?.lowerBound), 99.09, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(therapy.correctionRange?.upperBound), 109.90, accuracy: 0.01)
        XCTAssertEqual(therapy.scheduledBasalRate, 0.85)
        XCTAssertEqual(therapy.tempBasalRate, 0.4)

        // Loop stores ISF as mg/dL, without the per-unit part.
        manager.hostData.therapy?.insulinSensitivity = LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 45)
        XCTAssertEqual(try XCTUnwrap(manager.lupedSnapshot()).therapy?.insulinSensitivity, 45)
        // A unit that isn't glucose is left out rather than trapping.
        manager.hostData.therapy?.insulinSensitivity = LoopQuantity(unit: .gram, doubleValue: 45)
        XCTAssertNil(try XCTUnwrap(manager.lupedSnapshot()).therapy?.insulinSensitivity)
    }

    /// Loop status and therapy values reach the snapshot only while the watch
    /// shows them, as hosts filled them only when asked.
    func testLoopStateAndTherapyReachTheSnapshot() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .none, loopRing: false))
        manager.hostData.displayUnit = .milligramsPerDeciliter
        manager.hostData.glucoseSamples = [sample(120, minutes: 5)]
        manager.hostData.loopState = SmartwatchLoopState(
            lastLoopCompleted: start,
            isClosedLoop: true,
            insulinOnBoard: InsulinValue(startDate: start, value: 1.2),
            carbsOnBoard: CarbValue(startDate: start, value: 15)
        )
        manager.hostData.therapy = LupedHostData.Therapy(insulinSensitivity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 45), correctionRange: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 100)...LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 110))
        let plain = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(plain.loopStatus, LupedLoopStatus(), "nothing shown, nothing filled")
        XCTAssertNil(plain.therapy)

        manager.settings.statusLine = .sensitivityAndTarget
        let withExtras = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(withExtras.readings, plain.readings)
        // Loop status reaches the watch (IOB/COB strip and loop ring).
        XCTAssertEqual(withExtras.loopStatus, LupedLoopStatus(insulinOnBoard: 1.2, carbsOnBoard: 15, lastLoopCompleted: start, isClosedLoop: true))
        XCTAssertEqual(withExtras.therapy, LupedTherapy(insulinSensitivity: 45, correctionRange: 100...110))
        XCTAssertFalse(manager.watchHostDidReceiveURL(URL(string: "trio://smartwatch/callback")!))
    }

    /// Presets go to Luped Remote only while it is on, with the running one
    /// marked. No temp target presets (Loop has no temp targets) hides that kind.
    func testPresetsReachLupedRemote() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        manager.hostData.displayUnit = .milligramsPerDeciliter
        manager.hostData.glucoseSamples = [sample(120, minutes: 5)]
        let exercise = TemporaryPreset(id: "exercise", symbol: nil, name: "Exercise", settings: TemporaryPresetSettings(targetRange: nil, insulinNeedsScaleFactor: 0.5), duration: .finite(3_600))
        let sleep = TemporaryPreset(id: "sleep", symbol: nil, name: "Sleep", settings: TemporaryPresetSettings(targetRange: nil), duration: .indefinite)
        let running = TemporaryScheduleOverride(context: .preset(exercise), settings: exercise.settings, startDate: Date(timeIntervalSinceNow: -60), duration: exercise.duration, enactTrigger: .local, syncIdentifier: UUID())
        manager.hostData.presets = LupedHostData.Presets(overrides: [exercise, sleep], activeOverride: running, tempTargets: nil, activeTempTarget: nil)

        XCTAssertNil(try XCTUnwrap(manager.lupedSnapshot()).overridePresets, "Luped Remote is off")
        manager.settings.remoteEnabled = true
        let snapshot = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(snapshot.overridePresets, [LupedPreset(id: "exercise", name: "Exercise", isActive: true), LupedPreset(id: "sleep", name: "Sleep", isActive: false)])
        XCTAssertNil(snapshot.tempTargetPresets)
    }

    /// The host says what changed and the plugin reads only that: glucose for a
    /// new reading, the loop state after the loop, nothing for the alert mute.
    func testHostChangesAreReadFromTheDelegate() async throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .iobAndCob))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        delegate.displayUnit = .millimolesPerLiter
        delegate.glucoseSamples = [sample(120, minutes: 5)]

        manager.hostDataDidChange(.all)
        await manager.hostReadTask?.value
        XCTAssertEqual(manager.hostData.displayUnit, .millimolesPerLiter)
        XCTAssertEqual(manager.hostData.glucoseSamples, delegate.glucoseSamples)
        XCTAssertEqual(delegate.reads, ["unit", "absorption", "glucose", "loop"], "no therapy for IOB & COB, no presets with Luped Remote off")

        delegate.reads.removeAll()
        manager.hostDataDidChange(.glucose)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        XCTAssertEqual(delegate.reads, ["glucose"], "a new reading is sent with the previous loop state")

        delegate.reads.removeAll()
        manager.hostDataDidChange(.loop)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        XCTAssertEqual(delegate.reads, ["loop"])

        delegate.reads.removeAll()
        manager.hostDataDidChange(.alertMute)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        XCTAssertEqual(delegate.reads, [], "the watch doesn't show the mute")
    }

    private func curve(_ values: [Double], start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> [PredictedGlucoseValue] {
        values.enumerated().map { PredictedGlucoseValue(startDate: start.addingTimeInterval(Double($0.offset) * 300), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: $0.element)) }
    }

    /// Per time, the lowest and highest across the curves, cut where the shortest ends.
    func testForecastCone() {
        let cone = LupedHostData.forecastCone([curve([100, 110, 120]), curve([90, 130]), curve([95, 105, 140])])
        XCTAssertEqual(cone.map(\.low), [90, 105])
        XCTAssertEqual(cone.map(\.high), [100, 130])
        XCTAssertEqual(cone.map(\.date), curve([0, 0]).map(\.startDate))
        XCTAssertEqual(LupedHostData.forecastCone([curve([100, 110])]).map(\.high), [100, 110], "one curve gives its line")
        XCTAssertTrue(LupedHostData.forecastCone([]).isEmpty)
    }

    /// Each curve, then the cone, in whole mg/dL, so the cone can be checked from the log.
    func testForecastLogLines() {
        let lines = LupedHostData.forecastLogLines([curve([100.4, 110]), curve([90, 130.6, 150])])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Debug forecast curve 1 of 2, 2 values: 100,110")
        XCTAssertEqual(lines[1], "Debug forecast curve 2 of 2, 3 values: 90,131,150")
        XCTAssertTrue(lines[2].hasPrefix("Debug forecast cone (not sent), 2 values from 2027-01-15T08:00:00Z to 2027-01-15T08:05:00Z, low-high: "), lines[2])
        XCTAssertTrue(lines[2].hasSuffix(": 90-100,110-131"), lines[2])
        XCTAssertTrue(LupedHostData.forecastLogLines([]).isEmpty, "nothing before the loop has run")
    }

    /// The forecast stays out of the device log (it can be shared), and isn't sent.
    func testForecastIsNotLogged() async throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .iobAndCob))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        delegate.loopState = SmartwatchLoopState(lastLoopCompleted: nil, isClosedLoop: true, predictedGlucose: [curve([100, 110]), curve([90, 120])])

        manager.hostDataDidChange(.all)
        await manager.hostReadTask?.value
        XCTAssertEqual(delegate.reads.last, "loop")
        XCTAssertFalse(delegate.logEntries.contains { $0.message.hasPrefix("Debug forecast") })
        XCTAssertFalse(manager.transport.communicationLog.entries.contains { $0.message.hasPrefix("Debug forecast") })
    }

    /// With Luped Remote on, presets are read and a bolus context is issued from
    /// the host's recommendation, maximum bolus and volumes. The token stays
    /// while they and the newest reading are unchanged.
    /// The changes of one loop cycle arrive one by one; they are read once,
    /// with one recommendation for the bolus context.
    func testABurstOfHostChangesIsReadOnce() async throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, remoteEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        delegate.glucoseSamples = [sample(120, minutes: 5)]
        delegate.recommendation = .success(1.2)
        manager.hostDataDidChange(.all)
        await manager.hostReadTask?.value
        XCTAssertEqual(delegate.recommendationRequests, [0], ".all is read at once")

        let interval = LupedSmartwatchManager.hostChangeCoalescingInterval
        LupedSmartwatchManager.hostChangeCoalescingInterval = 0.2
        defer { LupedSmartwatchManager.hostChangeCoalescingInterval = interval }
        for changes: SmartwatchHostDataChange in [.glucose, .loop, .loop, .settings, .loop, .presets, .loop] {
            manager.hostDataDidChange(changes)
            await Task.yield()
        }
        XCTAssertEqual(delegate.recommendationRequests, [0], "nothing read while changes are collected")
        try await waitUntil { delegate.recommendationRequests.count == 2 }
        await manager.hostReadTask?.value
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(delegate.recommendationRequests, [0, 0], "one read for the burst")
        XCTAssertNil(manager.pendingHostChangesTask)
    }

    /// A bolus request reads changes still being collected first, so the
    /// context it is checked against counts them.
    func testABolusReadsCollectedChangesFirst() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        let interval = LupedSmartwatchManager.hostChangeCoalescingInterval
        LupedSmartwatchManager.hostChangeCoalescingInterval = 60
        defer { LupedSmartwatchManager.hostChangeCoalescingInterval = interval }
        let before = delegate.recommendationRequests.count
        manager.hostDataDidChange(.loop)
        manager.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { delegate.events.contains("bolus 0.50") }
        XCTAssertGreaterThan(delegate.recommendationRequests.count, before, "the collected change was read before the bolus")
        XCTAssertNil(manager.pendingHostChangesTask)
    }

    func testBolusContextIsIssuedFromTheHost() async throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, remoteEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        delegate.glucoseSamples = [sample(120, minutes: 5)]
        delegate.recommendation = .success(1.2)

        manager.hostDataDidChange(.all)
        await manager.hostReadTask?.value
        XCTAssertTrue(delegate.reads.contains("presets"))
        let context = try XCTUnwrap(manager.bolusContext)
        XCTAssertEqual(context.recommendedBolus, 1.2)
        XCTAssertEqual(context.maximumBolus, 5)
        XCTAssertEqual(context.bolusIncrement ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(delegate.recommendationRequests, [0])

        manager.hostDataDidChange(.loop)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        XCTAssertEqual(manager.bolusContext?.token, context.token, "unchanged inputs keep the token")

        delegate.glucoseSamples.append(sample(125, minutes: 10))
        manager.hostDataDidChange(.glucose)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        XCTAssertNotEqual(manager.bolusContext?.token, context.token, "a new reading gives a new token")
    }

    private func glucoseAlert(_ kind: String, _ level: Alert.InterruptionLevel = .timeSensitive, title: String? = nil) -> Alert {
        // The identifier is host-specific (here Trio-style, with a UUID); the type is what counts.
        Alert(
            identifier: Alert.Identifier(managerIdentifier: "Trio", alertIdentifier: "glucose." + kind),
            foregroundContent: nil,
            backgroundContent: Alert.Content(title: title ?? kind, body: "", acknowledgeActionButtonLabel: "OK"),
            trigger: .immediate,
            interruptionLevel: level
        )
    }

    private func issue(_ manager: LupedSmartwatchManager, _ alert: Alert) {
        let kind = alert.identifier.alertIdentifier.components(separatedBy: ".").last ?? ""
        manager.watchAlertDidIssue(alert, glucoseAlertType: SmartwatchGlucoseAlertType(rawValue: kind), issuedAt: Date())
    }

    private func retract(_ manager: LupedSmartwatchManager, _ kind: String) {
        manager.watchAlertDidRetract(Alert.Identifier(managerIdentifier: "Trio", alertIdentifier: "glucose." + kind))
    }

    /// The watch's alert state (DATA index 8) is the most important active glucose
    /// alert: urgent low, low, high, predicted low; retracting falls back.
    func testHostIssuedAlertSetsState() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        XCTAssertEqual(manager.hostAlertState, 0)

        issue(manager, glucoseAlert("predictedLow"))
        XCTAssertEqual(manager.hostAlertState, 4)
        issue(manager, glucoseAlert("high", title: "High Glucose"))
        XCTAssertEqual(manager.hostAlertState, 3, "High outranks predicted low")
        XCTAssertTrue(delegate.logEntries.contains { $0.type == .connection && $0.message.contains("High Glucose") })
        issue(manager, glucoseAlert("low"))
        XCTAssertEqual(manager.hostAlertState, 1, "Low outranks high")
        issue(manager, glucoseAlert("urgentLow", .critical))
        XCTAssertEqual(manager.hostAlertState, 2, "Urgent low outranks everything")
        retract(manager, "urgentLow")
        XCTAssertEqual(manager.hostAlertState, 1)
        let occlusion = Alert(identifier: Alert.Identifier(managerIdentifier: "Pump", alertIdentifier: "occlusion"), foregroundContent: nil, backgroundContent: Alert.Content(title: "Occlusion", body: "", acknowledgeActionButtonLabel: "OK"), trigger: .immediate, interruptionLevel: .critical)
        manager.watchAlertDidIssue(occlusion, glucoseAlertType: nil, issuedAt: Date())
        XCTAssertEqual(manager.hostAlertState, 1, "Non-glucose alerts don't set a state")
        for kind in ["low", "high", "predictedLow"] {
            retract(manager, kind)
        }
        XCTAssertEqual(manager.hostAlertState, 0)
    }

    /// The state comes from the host's glucose alert type, whatever its identifiers
    /// look like (Trio's are `Trio.glucose.<type>.<UUID>`).
    func testAlertStateUsesTheTypeNotTheIdentifier() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        let trioLow = Alert(identifier: Alert.Identifier(managerIdentifier: "Trio", alertIdentifier: "glucose.low.3F2A9C1E"), foregroundContent: nil, backgroundContent: Alert.Content(title: "Low", body: "", acknowledgeActionButtonLabel: "OK"), trigger: .immediate, interruptionLevel: .critical)
        manager.watchAlertDidIssue(trioLow, glucoseAlertType: .low, issuedAt: Date())
        XCTAssertEqual(manager.hostAlertState, 1)
        let untyped = Alert(identifier: Alert.Identifier(managerIdentifier: "GlucoseAlertManager", alertIdentifier: "glucose.high"), foregroundContent: nil, backgroundContent: Alert.Content(title: "High", body: "", acknowledgeActionButtonLabel: "OK"), trigger: .immediate)
        manager.watchAlertDidIssue(untyped, glucoseAlertType: nil, issuedAt: Date())
        XCTAssertEqual(manager.hostAlertState, 1, "An alert without a glucose type doesn't set a state")
    }

    /// With watch alarms off the state is negative: the ring keeps its colour, but
    /// the watch only buzzes for a positive state.
    func testWatchAlarmsOffNegatesTheState() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, alarmsEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        issue(manager, glucoseAlert("low", .critical))
        XCTAssertEqual(manager.hostAlertState, -1)
        XCTAssertFalse(manager.hostAlertReason.contains("Watch Alarms"), "the DATA decode already says Watch Alarms is off: \(manager.hostAlertReason)")
    }

    /// A repeat of an active alert keeps the level but advances the alert event,
    /// which is saved so a relaunch continues from it.
    func testAlertEventAdvancesOnEveryFireAndIsSaved() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let urgentLow = glucoseAlert("urgentLow", .critical, title: "Urgent Low")
        let start = manager.alertEvent

        issue(manager, urgentLow)
        XCTAssertEqual(manager.alertEvent, (start + 1) % LupedSmartwatchManager.alertEventModulus)
        XCTAssertEqual(manager.hostAlertState, 2)

        issue(manager, urgentLow)  // the host's repeat fire
        XCTAssertEqual(manager.alertEvent, (start + 2) % LupedSmartwatchManager.alertEventModulus)
        XCTAssertEqual(manager.hostAlertState, 2, "A repeat doesn't change the state")
        XCTAssertEqual(delegate.stateUpdates, 2, "Each fire saves the new event")

        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.alertEvent, manager.alertEvent)
    }

    /// A watch added again starts at a random event, so its first alert can't
    /// land on the number the watch kept from the previous manager.
    func testANewManagerStartsAtARandomAlertEvent() {
        let starts = Set((0..<20).map { _ in LupedSmartwatchManager(settings: LupedSettings(isEnabled: false)).alertEvent })
        XCTAssertTrue(starts.allSatisfy { (0..<LupedSmartwatchManager.alertEventModulus).contains($0) })
        XCTAssertGreaterThan(starts.count, 1, "20 new managers all started at the same event: \(starts)")
    }

    /// Active alerts survive a relaunch: the host doesn't issue an alert again for
    /// an episode it already alerted on, so the ring would otherwise turn green.
    /// The host's later retraction still clears it, and is saved.
    func testActiveAlertsSurviveRelaunch() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        issue(manager, glucoseAlert("high", title: "High Glucose"))
        issue(manager, glucoseAlert("low", .critical))

        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        let delegate = MockSmartwatchManagerDelegate()
        restored.smartwatchManagerDelegate = delegate
        XCTAssertEqual(restored.activeAlerts.count, 2)
        for (identifier, alert) in manager.activeAlerts {
            var saved = try XCTUnwrap(restored.activeAlerts[identifier])
            XCTAssertEqual(saved.issuedAt.timeIntervalSince(alert.issuedAt), 0, accuracy: 0.001)
            saved.issuedAt = alert.issuedAt
            XCTAssertEqual(saved, alert)
        }
        XCTAssertEqual(restored.hostAlertState, 1)

        retract(restored, "low")
        XCTAssertEqual(restored.hostAlertState, 3)
        XCTAssertEqual(delegate.stateUpdates, 1, "A retraction saves the state")
        retract(restored, "high")
        let relaunchedAgain = try XCTUnwrap(LupedSmartwatchManager(rawState: restored.rawState))
        XCTAssertEqual(relaunchedAgain.hostAlertState, 0)
        XCTAssertNil(restored.rawState["activeAlerts"])
    }

    /// Alerts saved before the host passed LoopKit alerts (the same keys and level
    /// numbers) still come back after the update.
    func testAlertsSavedByTheEarlierBuildAreRestored() throws {
        let saved: [String: Any] = ["identifier": "GlucoseAlertManager.glucose.low", "level": 2, "issuedAt": start.timeIntervalSince1970, "title": "Low", "glucoseAlertType": "low"]
        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: ["activeAlerts": [saved]]))
        let alert = try XCTUnwrap(restored.activeAlerts["GlucoseAlertManager.glucose.low"])
        XCTAssertEqual(alert.level, .critical)
        XCTAssertEqual(restored.hostAlertState, 1)
        restored.watchAlertDidRetract(Alert.Identifier(managerIdentifier: "GlucoseAlertManager", alertIdentifier: "glucose.low"))
        XCTAssertEqual(restored.hostAlertState, 0, "the host's retraction names the same identifier")
    }

    /// The event advances while watch alarms are off, so turning them back on
    /// doesn't replay an alert the watch was told to ignore.
    func testAlertEventAdvancesWhileWatchAlarmsOff() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, alarmsEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        let start = manager.alertEvent
        issue(manager, glucoseAlert("low"))
        XCTAssertEqual(manager.alertEvent, (start + 1) % LupedSmartwatchManager.alertEventModulus)
        XCTAssertEqual(manager.hostAlertState, -1)
    }

    /// The last watch diagnostics report is saved with the state, so the watch
    /// info shows after a relaunch instead of waiting for the next hourly report.
    func testWatchDiagnosticsSurviveRelaunch() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let json = "[2,1792957000000,85,1792950000000,1,0,0,0,0,0,0,0,0,12,3]"
        let receivedAt = Date(timeIntervalSince1970: 1_792_957_000)
        manager.transport.diagnosticsDidArrive?(json, receivedAt)
        XCTAssertEqual(delegate.stateUpdates, 1, "A new report saves the state")

        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.savedDiagnostics, .init(json: json, receivedAt: receivedAt))
        let shown = try XCTUnwrap(restored.transport.status.diagnostics, "Shown as soon as the link starts")
        XCTAssertEqual(shown.battery, 85)
        XCTAssertEqual(shown.receivedAt, receivedAt)
    }

    /// The event wraps from 999 to 1, never to 0: 0 can't be sent negative, so an
    /// alert on event 0 buzzed without the alarm sound.
    func testAlertEventWrapsPastZero() throws {
        let manager = try XCTUnwrap(LupedSmartwatchManager(rawState: ["alertEvent": LupedSmartwatchManager.alertEventModulus - 1]))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        issue(manager, glucoseAlert("high"))
        XCTAssertEqual(manager.alertEvent, 1)
    }

    func testAlertEventsAreNeverZero() {
        XCTAssertEqual(LupedSmartwatchManager.nextAlertEvent(after: 0), 1, "from a manager saved before any alert")
        var event = Int.random(in: 1..<LupedSmartwatchManager.alertEventModulus)
        for _ in 0..<2 * LupedSmartwatchManager.alertEventModulus {
            event = LupedSmartwatchManager.nextAlertEvent(after: event)
            XCTAssertTrue((1..<LupedSmartwatchManager.alertEventModulus).contains(event), "event \(event)")
        }
        for _ in 0..<200 {
            let manager = LupedSmartwatchManager()
            XCTAssertNotEqual(manager.alertEvent, 0, "a new manager starts at 0")
        }
    }
}

// MARK: - Luped Remote: switches, checks and history

extension LupedSmartwatchManagerTests {
    /// A manager with Luped Remote on, a host with a reading 2 minutes old that
    /// recommends 1 U, and rate-limit history of its own.
    private func remoteManager(permissions: LupedRemotePermissions = LupedRemotePermissions(bolus: true, carbs: true), defaults: UserDefaults) async -> (LupedSmartwatchManager, MockSmartwatchManagerDelegate) {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, remoteEnabled: true))
        manager.remoteHistory = LupedRemoteHistory(defaults: defaults)
        let delegate = MockSmartwatchManagerDelegate()
        delegate.glucoseSamples = [StoredGlucoseSample(startDate: Date(timeIntervalSinceNow: -120), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 120))]
        delegate.recommendation = .success(1)
        manager.smartwatchManagerDelegate = delegate
        manager.remotePermissions = permissions
        manager.hostDataDidChange(.all)
        await manager.hostReadTask?.value
        return (manager, delegate)
    }

    /// History kept apart from the app's own defaults, removed after the test.
    private func isolatedDefaults() -> UserDefaults {
        let name = "LupedSmartwatchKitTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func logged(_ delegate: MockSmartwatchManagerDelegate, _ prefix: String) -> Bool {
        delegate.logEntries.contains { $0.message.hasPrefix(prefix) }
    }

    /// Every switch is off until turned on, is saved in rawState, and a missing
    /// one is off.
    func testRemoteSwitchesAreOffUntilTurnedOnAndSaved() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, remoteEnabled: true))
        XCTAssertEqual(manager.remotePermissions, .none)
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate

        manager.remotePermissions.carbs = true
        manager.remotePermissions.tempTargets = true
        XCTAssertEqual(delegate.stateUpdates, 2)
        manager.remotePermissions.carbs = true
        XCTAssertEqual(delegate.stateUpdates, 2, "An unchanged switch is not saved again")

        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.remotePermissions, LupedRemotePermissions(carbs: true, tempTargets: true))
        XCTAssertEqual(LupedRemotePermissions(rawValue: ["bolus": true]), LupedRemotePermissions(bolus: true))
        XCTAssertEqual(LupedRemotePermissions(rawValue: [:]), .none)
    }

    /// D1: the watch gets a bolus key only while Luped Remote is on and boluses
    /// from it are allowed.
    func testBolusKeyOnlyWithLupedRemoteAndItsSwitch() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        manager.remotePermissions.bolus = true
        XCTAssertFalse(manager.bolusKeyAllowed, "Luped Remote is off")
        manager.settings.remoteEnabled = true
        XCTAssertTrue(manager.bolusKeyAllowed)
        manager.remotePermissions.bolus = false
        XCTAssertFalse(manager.bolusKeyAllowed, "boluses from the watch are off")
        manager.remotePermissions = LupedRemotePermissions(carbs: true, mute: true, overrides: true, tempTargets: true)
        XCTAssertFalse(manager.bolusKeyAllowed, "the other switches don't give a key")
    }

    /// Deleting the watch turns every switch off, so a watch added later starts
    /// with none allowed, and takes the bolus key away.
    func testDeleteTurnsEveryRemoteSwitchOff() async {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        manager.remotePermissions = LupedRemotePermissions(bolus: true, carbs: true, mute: true, overrides: true, tempTargets: true)
        manager.transportIfStarted = LupedTransport(hostName: LupedSmartwatchManager.hostName, settings: manager.settings)
        manager.transportIfStarted?.issuesBolusKey = true

        await manager.delete()

        XCTAssertEqual(manager.remotePermissions, .none)
        XCTAssertEqual(LupedSmartwatchManager(rawState: manager.rawState)?.remotePermissions, LupedRemotePermissions.none)
        XCTAssertFalse(manager.bolusKeyAllowed)
        XCTAssertEqual(manager.transportIfStarted?.issuesBolusKey, false)
        XCTAssertEqual(delegate.deletions, 1)
    }

    /// Each request needs its own switch; with it off the host is never asked.
    func testEachRequestNeedsItsSwitch() async throws {
        let (manager, delegate) = await remoteManager(permissions: .none, defaults: isolatedDefaults())

        manager.requestAlertMute(15 * 60, requestedAt: Date())
        XCTAssertTrue(logged(delegate, "Mute request from the watch refused: Allow Mute from Watch is off"))
        manager.requestOverride(.cancel, requestedAt: Date())
        XCTAssertTrue(logged(delegate, "Preset request rejected: notAllowed (Allow Presets from Watch is off)"))
        manager.requestTempTarget(.cancel, requestedAt: Date())
        XCTAssertTrue(logged(delegate, "Temp target request rejected: notAllowed (Allow Temp Targets from Watch is off)"))
        manager.requestBolusRecommendation(0)
        XCTAssertTrue(logged(delegate, "Bolus recommendation refused: Allow Boluses from Watch is off"))
        manager.requestCarbs(20, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Carb entry request rejected: notAllowed (Allow Carbs from Watch is off)") }
        manager.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Bolus request rejected by Luped's checks: notAllowed (Allow Boluses from Watch is off; ") }
        XCTAssertEqual(delegate.events.filter { !$0.hasPrefix("recommend") }, [], "The host was never asked")

        // Turned on, they pass.
        manager.remotePermissions = LupedRemotePermissions(mute: true, overrides: true)
        manager.requestAlertMute(15 * 60, requestedAt: Date())
        manager.requestOverride(.cancel, requestedAt: Date())
        try await waitUntil { delegate.events.contains("mute") && delegate.events.contains("override") }
        // Requests confirmed too long ago are refused.
        manager.requestAlertMute(15 * 60, requestedAt: Date(timeIntervalSinceNow: -31))
        XCTAssertTrue(logged(delegate, "Mute request from the watch refused: expiredRequest"))
    }

    /// A bolus is checked against the context the plugin issued and delivered;
    /// the next one within 5 minutes is refused, and one over the recommendation
    /// is refused unless forced.
    func testWatchBolusIsCheckedThenDelivered() async throws {
        let defaults = isolatedDefaults()
        let (manager, delegate) = await remoteManager(defaults: defaults)

        manager.requestBolus(1.5, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Bolus request rejected by Luped's checks: exceedsRecommendation") }

        manager.requestBolus(0.52, requestedAt: Date())
        try await waitUntil { delegate.events.contains("bolus 0.50") }
        XCTAssertEqual(manager.remoteHistory.bolusDeliveries.map(\.units), [0.5], "rounded down to the pump's 0.05 U steps")
        try await waitUntil { self.logged(delegate, "\(LupedSmartwatchManager.hostName) delivered 0.50 U requested from the watch") }

        manager.requestBolus(0.5, forced: true, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Bolus request rejected by Luped's checks: rateLimited") }
        XCTAssertEqual(delegate.events.filter { $0.hasPrefix("bolus") }, ["bolus 0.50"])
    }

    /// Without a recent reading, even a forced bolus is refused.
    func testBolusNeedsRecentGlucose() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        delegate.glucoseSamples = [StoredGlucoseSample(startDate: Date(timeIntervalSinceNow: -16 * 60), quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: 120))]
        manager.requestBolus(0.5, forced: true, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Bolus request rejected by Luped's checks: noRecentGlucose (newest glucose 16 min ago; ") }
        XCTAssertFalse(delegate.events.contains { $0.hasPrefix("bolus") })
    }

    /// A failed or uncertain delivery counts for the time between boluses, but
    /// not toward the daily total.
    func testAFailedBolusStillCountsForTheGap() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        delegate.bolusError = SmartwatchBolusError.deliveryFailed("lost contact with the pump")
        manager.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "\(LupedSmartwatchManager.hostName) refused the watch's bolus request (deliveryFailed") }
        XCTAssertEqual(manager.remoteHistory.bolusDeliveries.map(\.units), [0])
        try await waitUntil("a new context after the attempt spent it") { manager.bolusContextIssuer.current != nil }

        delegate.bolusError = nil
        manager.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Bolus request rejected by Luped's checks: rateLimited") }
    }

    /// The host answers inProgress while another bolus is delivering: nothing
    /// was sent for this request, so it starts no gap.
    func testABolusTheHostAnswersInProgressStartsNoGap() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        delegate.bolusError = SmartwatchBolusError.inProgress
        manager.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "\(LupedSmartwatchManager.hostName) is still delivering another bolus; this request is refused") }
        XCTAssertEqual(manager.remoteHistory.bolusDeliveries, [])
        try await waitUntil("a new context after the attempt") { manager.bolusContextIssuer.current != nil }

        delegate.bolusError = nil
        manager.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "\(LupedSmartwatchManager.hostName) delivered 0.50 U requested from the watch") }
        XCTAssertEqual(delegate.events.filter { $0.hasPrefix("bolus") }, ["bolus 0.50", "bolus 0.50"])
    }

    /// The history isn't in rawState and survives deleting the watch: a watch
    /// added again doesn't get a fresh 5-minute gap or daily total.
    func testBolusHistorySurvivesDeletingTheWatch() async throws {
        let defaults = isolatedDefaults()
        let (first, firstHost) = await remoteManager(defaults: defaults)
        first.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { firstHost.events.contains("bolus 0.50") }
        XCTAssertNil(first.rawState["bolusDeliveries"])
        await first.delete()
        XCTAssertEqual(LupedRemoteHistory(defaults: defaults).bolusDeliveries.map(\.units), [0.5])

        let (second, secondHost) = await remoteManager(defaults: defaults)
        second.requestBolus(0.5, requestedAt: Date())
        try await waitUntil { self.logged(secondHost, "Bolus request rejected by Luped's checks: rateLimited") }
        XCTAssertFalse(secondHost.events.contains { $0.hasPrefix("bolus") })
    }

    /// Bolus history keeps 24 hours; an attempt is replaced by what was delivered.
    func testBolusHistoryBookkeeping() {
        let history = LupedRemoteHistory(defaults: isolatedDefaults())
        let old = SmartwatchBolusPolicy.Delivery(date: Date(timeIntervalSinceNow: -25 * 3_600), units: 2)
        let recent = SmartwatchBolusPolicy.Delivery(date: Date(timeIntervalSinceNow: -3_600), units: 1)
        history.bolusDeliveries = [old, recent]
        XCTAssertEqual(history.bolusDeliveries, [recent], "pruned to 24 h")

        let attemptedAt = Date()
        history.bolusDeliveries = LupedRemoteHistory.bolusAttempted(at: attemptedAt, in: history.bolusDeliveries)
        XCTAssertEqual(history.bolusDeliveries.last, SmartwatchBolusPolicy.Delivery(date: attemptedAt, units: 0))
        history.bolusDeliveries = LupedRemoteHistory.bolusDelivered(0.75, attemptedAt: attemptedAt, in: history.bolusDeliveries)
        XCTAssertEqual(history.bolusDeliveries.map(\.units), [1, 0.75])

        let refusedAt = attemptedAt.addingTimeInterval(1)
        history.bolusDeliveries = LupedRemoteHistory.bolusAttempted(at: refusedAt, in: history.bolusDeliveries)
        history.bolusDeliveries = LupedRemoteHistory.bolusAttemptRefused(at: refusedAt, in: history.bolusDeliveries)
        XCTAssertEqual(history.bolusDeliveries.map(\.units), [1, 0.75], "a refusal by the host sent nothing, so it starts no gap")

        history.lastCarbEntry = attemptedAt
        XCTAssertEqual(LupedRemoteHistory(defaults: history.defaults).lastCarbEntry, attemptedAt)
    }

    /// With carbs, the carbs go to the host first, then the bolus is checked
    /// against a context whose recommendation counts them.
    func testBolusWithCarbsAddsTheCarbsFirst() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        delegate.events.removeAll()
        manager.requestBolus(0.5, grams: 20, absorption: .slow, requestedAt: Date())
        try await waitUntil { delegate.events.contains { $0.hasPrefix("bolus") } }
        XCTAssertEqual(Array(delegate.events.prefix(3)), ["carbs 20 14400", "recommend 0.0", "bolus 0.50"])
        XCTAssertNotNil(manager.remoteHistory.lastCarbEntry)
    }

    /// A refusal by Luped's own limits says so, with when the next entry may
    /// come; the watch gets the same answer as before.
    func testLupedsOwnCarbRefusalIsNamedAsSuch() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        manager.requestCarbs(20, requestedAt: Date())
        try await waitUntil { delegate.events.contains { $0.hasPrefix("carbs") } }
        manager.requestBolus(0.3, grams: 5, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Luped's checks refused the watch's carbs (rateLimited), so the bolus isn't given either") }
        XCTAssertTrue(delegate.logEntries.contains { $0.message.hasPrefix("Carb entry request rejected: rateLimited (5 min between entries from the watch; next at ") })
        XCTAssertFalse(delegate.logEntries.contains { $0.message.hasPrefix("\(LupedSmartwatchManager.hostName) refused the watch's carbs") })
        XCTAssertTrue(LupedSmartwatchManager.answer(for: LupedRemoteRefusal(error: SmartwatchCarbEntryError.rateLimited)) == ("refused", .tooSoon))
        XCTAssertEqual(delegate.events.filter { $0.hasPrefix("carbs") || $0.hasPrefix("bolus") }.count, 1, "neither the carbs nor the bolus was passed on")
    }

    /// The carb entry takes its rate-limit slot before the host adds it, and
    /// gets it back when adding fails.
    func testCarbSlotIsGivenBackWhenAddingFails() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        delegate.carbEntryError = SmartwatchCarbEntryError.failed("store unavailable")
        manager.requestCarbs(20, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "\(LupedSmartwatchManager.hostName) refused the watch's carb request") }
        XCTAssertNil(manager.remoteHistory.lastCarbEntry)

        delegate.carbEntryError = nil
        manager.requestCarbs(20, requestedAt: Date())
        try await waitUntil { delegate.events.filter { $0.hasPrefix("carbs") }.count == 2 }
        XCTAssertNotNil(manager.remoteHistory.lastCarbEntry)
        manager.requestCarbs(10, requestedAt: Date())
        try await waitUntil { self.logged(delegate, "Carb entry request rejected: rateLimited") }
    }

    /// The watch's fast, medium and slow become the host's absorption times;
    /// a host without them (Trio) tells Luped Remote not to ask, and an
    /// absorption an older watch still sends is left out.
    func testCarbAbsorptionMapsToTheHostsTimes() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        manager.hostData.displayUnit = .milligramsPerDeciliter
        manager.hostData.glucoseSamples = [sample(120, minutes: 5)]
        manager.hostData.carbAbsorptionTimes = LupedHostData.CarbAbsorptionTimes(fast: 7_200, medium: 10_800, slow: 14_400)
        XCTAssertEqual(try XCTUnwrap(manager.lupedSnapshot()).usesCarbAbsorption, true)
        XCTAssertEqual(manager.hostAbsorptionTime(.fast), 7_200)
        XCTAssertEqual(manager.hostAbsorptionTime(.medium), 10_800)
        XCTAssertEqual(manager.hostAbsorptionTime(.slow), 14_400)
        XCTAssertNil(manager.hostAbsorptionTime(nil), "the host's default")

        manager.hostData.carbAbsorptionTimes = nil
        XCTAssertEqual(try XCTUnwrap(manager.lupedSnapshot()).usesCarbAbsorption, false)
        XCTAssertNil(manager.hostAbsorptionTime(.slow))
        XCTAssertNil(manager.hostAbsorptionTime(nil))
    }

    /// A set of absorption times with any zero, negative, NaN or infinite value
    /// is treated as none: Luped Remote doesn't ask, carbs get the host's
    /// default, and each read that returns one logs it once.
    func testUnusableCarbAbsorptionTimesAreTreatedAsNone() async throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        delegate.glucoseSamples = [sample(120, minutes: 5)]
        manager.smartwatchManagerDelegate = delegate
        let unusable: [(fast: TimeInterval, medium: TimeInterval, slow: TimeInterval)] = [
            (0, 10_800, 14_400), (7_200, -1, 14_400), (7_200, 10_800, .nan), (.infinity, 10_800, 14_400),
        ]
        for times in unusable {
            delegate.logEntries.removeAll()
            delegate.carbAbsorptionTimes = times
            manager.hostDataDidChange(.settings)
            manager.flushHostChanges()
            await manager.hostReadTask?.value
            XCTAssertNil(manager.hostData.carbAbsorptionTimes, "\(times)")
            XCTAssertEqual(try XCTUnwrap(manager.lupedSnapshot()).usesCarbAbsorption, false)
            XCTAssertNil(manager.hostAbsorptionTime(.medium))
            XCTAssertEqual(delegate.logEntries.filter { $0.type == .error && $0.message.contains("carb absorption times aren't usable") }.count, 1)
        }

        delegate.logEntries.removeAll()
        manager.hostDataDidChange(.glucose)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        XCTAssertFalse(delegate.logEntries.contains { $0.message.contains("aren't usable") }, "only a settings read checks them")

        delegate.carbAbsorptionTimes = (1_800, 10_800, 14_400)
        manager.hostDataDidChange(.settings)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        XCTAssertEqual(manager.hostData.carbAbsorptionTimes, LupedHostData.CarbAbsorptionTimes(fast: 1_800, medium: 10_800, slow: 14_400))
        XCTAssertEqual(manager.hostAbsorptionTime(.fast), 1_800)
        XCTAssertFalse(delegate.logEntries.contains { $0.message.contains("aren't usable") })
    }

    /// Carbs from the watch with unusable absorption times reach the host
    /// with its default; with usable ones, with the chosen time.
    func testCarbsGetTheHostsDefaultWithUnusableAbsorptionTimes() async throws {
        let (manager, delegate) = await remoteManager(defaults: isolatedDefaults())
        delegate.carbAbsorptionTimes = (7_200, 0, 14_400)
        manager.hostDataDidChange(.settings)
        manager.flushHostChanges()
        await manager.hostReadTask?.value
        delegate.events.removeAll()
        manager.requestCarbs(20, absorption: .medium, requestedAt: Date())
        try await waitUntil { delegate.events.contains { $0.hasPrefix("carbs") } }
        XCTAssertEqual(delegate.events.first { $0.hasPrefix("carbs") }, "carbs 20 -1")

        let (validManager, validDelegate) = await remoteManager(defaults: isolatedDefaults())
        validDelegate.events.removeAll()
        validManager.requestCarbs(20, absorption: .medium, requestedAt: Date())
        try await waitUntil { validDelegate.events.contains { $0.hasPrefix("carbs") } }
        XCTAssertEqual(validDelegate.events.first { $0.hasPrefix("carbs") }, "carbs 20 10800")
    }

    /// Rounding as `PumpManager` does by default: down to a supported volume.
    func testBolusRoundsDownToASupportedVolume() {
        let volumes = [0.05, 0.1, 0.15, 0.2]
        XCTAssertEqual(LupedSmartwatchManager.roundToSupportedBolusVolume(0.12, volumes: volumes), 0.1)
        XCTAssertEqual(LupedSmartwatchManager.roundToSupportedBolusVolume(0.01, volumes: volumes), 0)
        XCTAssertEqual(LupedSmartwatchManager.roundToSupportedBolusVolume(0.12, volumes: []), 0.12, "no pump: the host refuses")
    }
}

/// A host for the tests: what it returns is set per test, and its reads and
/// actions are recorded.
private final class MockSmartwatchManagerDelegate: SmartwatchManagerDelegate {
    struct LogEntry {
        var deviceIdentifier: String?
        var type: DeviceLogEntryType
        var message: String
    }

    var logEntries: [LogEntry] = []
    var stateUpdates = 0
    var deletions = 0
    /// The reads in order, by short name.
    var reads: [String] = []

    var displayUnit: LoopUnit = .milligramsPerDeciliter
    var glucoseSamples: [StoredGlucoseSample] = []
    var loopState = SmartwatchLoopState(lastLoopCompleted: nil, isClosedLoop: true)
    var maximumBolus: Double? = 5
    var maximumCarbEntry: Double? = 250
    var supportedBolusVolumes = (1...600).map { Double($0) / 20 }
    var carbAbsorptionTimes: (fast: TimeInterval, medium: TimeInterval, slow: TimeInterval)? = (2 * 3_600, 3 * 3_600, 4 * 3_600)
    var recommendation: Result<Double, Error> = .failure(SmartwatchBolusError.refusedByHost("no recommendation"))
    var recommendationRequests: [Double] = []

    func smartwatchManagerDidUpdateState(_ manager: SmartwatchManager) { stateUpdates += 1 }
    func smartwatchManagerWantsDeletion(_ manager: SmartwatchManager) async { deletions += 1 }

    // MARK: DeviceManagerDelegate

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        logEntries.append(LogEntry(deviceIdentifier: deviceIdentifier, type: type, message: message))
    }
    func issueAlert(_ alert: Alert) async {}
    func retractAlert(identifier: Alert.Identifier) async {}
    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}

    // MARK: Reads

    func smartwatchManagerGlucoseDisplayUnit(_ manager: SmartwatchManager) async -> LoopUnit {
        reads.append("unit")
        return displayUnit
    }
    func smartwatchManager(_ manager: SmartwatchManager, glucoseSamplesSince date: Date) async throws -> [StoredGlucoseSample] {
        reads.append("glucose")
        return glucoseSamples.filter { $0.startDate >= date }
    }
    func smartwatchManagerLoopState(_ manager: SmartwatchManager) async -> SmartwatchLoopState {
        reads.append("loop")
        return loopState
    }
    func smartwatchManagerScheduledBasalRate(_ manager: SmartwatchManager) async -> LoopQuantity? {
        reads.append("therapy")
        return nil
    }
    func smartwatchManagerTempBasal(_ manager: SmartwatchManager) async -> DoseEntry? { nil }
    func smartwatchManagerInsulinSensitivity(_ manager: SmartwatchManager) async -> LoopQuantity? { nil }
    func smartwatchManagerCorrectionRange(_ manager: SmartwatchManager) async -> ClosedRange<LoopQuantity>? { nil }
    func smartwatchManagerOverridePresets(_ manager: SmartwatchManager) async -> [TemporaryPreset] {
        reads.append("presets")
        return []
    }
    func smartwatchManagerActiveOverride(_ manager: SmartwatchManager) async -> TemporaryScheduleOverride? { nil }
    func smartwatchManagerAlertMuteEnd(_ manager: SmartwatchManager) async -> Date? { nil }
    func smartwatchManagerMaximumBolus(_ manager: SmartwatchManager) async -> Double? { maximumBolus }
    func smartwatchManagerMaximumCarbEntry(_ manager: SmartwatchManager) async -> Double? { maximumCarbEntry }
    func smartwatchManagerSupportedBolusVolumes(_ manager: SmartwatchManager) async -> [Double] { supportedBolusVolumes }
    func smartwatchManagerDefaultCarbAbsorptionTimes(_ manager: SmartwatchManager) async -> (fast: TimeInterval, medium: TimeInterval, slow: TimeInterval)? {
        reads.append("absorption")
        return carbAbsorptionTimes
    }

    func smartwatchManager(_ manager: SmartwatchManager, recommendBolusForCarbs grams: Double, absorptionTime: TimeInterval?) async throws -> Double {
        recommendationRequests.append(grams)
        events.append("recommend \(grams)")
        return try recommendation.get()
    }

    // MARK: Actions

    /// The actions in order, such as "carbs 20 10800" (grams, absorption time
    /// in seconds or -1 for the default) or "bolus 0.50".
    var events: [String] = []
    /// `nil` delivers what was asked.
    var bolusError: Error?
    var carbEntryError: Error?

    func smartwatchManager(_ manager: SmartwatchManager, deliverBolus units: Double) async throws -> Double {
        events.append(String(format: "bolus %.2f", units))
        if let bolusError { throw bolusError }
        return units
    }
    func smartwatchManager(_ manager: SmartwatchManager, addCarbEntry grams: Double, absorptionTime: TimeInterval?, date: Date) async throws -> Double {
        events.append("carbs \(Int(grams)) \(absorptionTime.map { Int($0) } ?? -1)")
        if let carbEntryError { throw carbEntryError }
        return grams
    }
    func smartwatchManager(_ manager: SmartwatchManager, enactOverride action: SmartwatchPresetAction) async throws {
        events.append("override")
    }
    func smartwatchManager(_ manager: SmartwatchManager, muteAlertsFor duration: TimeInterval) async throws -> Date {
        events.append("mute")
        return Date(timeIntervalSinceNow: duration)
    }
}

final class LupedSetupProgressTests: XCTestCase {
    private let reading = Date(timeIntervalSince1970: 1_800_000_000)

    private func progress(_ link: LupedLinkStatus.Link, delivered: Date? = nil, rejected: Date? = nil, paused: Bool = false) -> LupedSetupProgress {
        LupedSetupProgress(link: link, lastDelivery: delivered.map { (reading, $0) }, lastRejectedAt: rejected, paused: paused)
    }

    func testLinkStatesBeforeAnyReading() {
        XCTAssertEqual(progress(.off), .waitingForWatch)
        XCTAssertEqual(progress(.waitingForWatch), .waitingForWatch)
        XCTAssertEqual(progress(.connecting), .connecting)
        XCTAssertEqual(progress(.bluetoothUnavailable), .bluetoothUnavailable)
    }

    func testConnectedIsNotDoneUntilTheWatchAcknowledgesAReading() {
        XCTAssertEqual(progress(.open), .waitingForReading)
        XCTAssertFalse(progress(.open).isComplete)
        XCTAssertEqual(progress(.open, delivered: reading.addingTimeInterval(5)), .delivered(readingDate: reading))
        XCTAssertTrue(progress(.open, delivered: reading.addingTimeInterval(5)).isComplete)
    }

    func testRejectedOrPausedMeansTheWatchfaceIsNotRunning() {
        XCTAssertEqual(progress(.open, rejected: reading), .watchfaceNotRunning)
        XCTAssertEqual(progress(.open, paused: true), .watchfaceNotRunning)
    }

    func testTheNewestOfDeliveryAndRejectionWins() {
        let early = reading.addingTimeInterval(10)
        let late = reading.addingTimeInterval(20)
        XCTAssertEqual(progress(.open, delivered: late, rejected: early), .delivered(readingDate: reading))
        XCTAssertEqual(progress(.open, delivered: early, rejected: late), .watchfaceNotRunning)
    }

    func testADeliveredReadingStaysDoneAfterTheLinkDrops() {
        XCTAssertEqual(progress(.waitingForWatch, delivered: reading), .delivered(readingDate: reading))
    }
}

/// The notice for a watch that is connected to the iPhone but doesn't open a
/// session with the app: about the watch, never glucose, and at most time-sensitive.
@MainActor
final class LupedLinkStalledAlertTests: XCTestCase {
    func testAlertNamesTheHostAndTellsTheUserToRestartIt() {
        let alert = LupedSmartwatchManager.linkStalledAlert(pluginIdentifier: "LupedSmartwatchManager", hostName: "Trio")
        XCTAssertEqual(alert.identifier.managerIdentifier, "LupedSmartwatchManager")
        XCTAssertEqual(alert.identifier.alertIdentifier, "watchLinkStalled")
        XCTAssertEqual(alert.trigger, .immediate)
        XCTAssertEqual(alert.interruptionLevel, .timeSensitive)
        XCTAssertNil(alert.sound)
        XCTAssertTrue(alert.backgroundContent.body.contains("Close Trio completely and open it again"), alert.backgroundContent.body)
        XCTAssertEqual(alert.foregroundContent, alert.backgroundContent)
    }

    func testRetractionUsesTheSameIdentifier() {
        let issued = LupedSmartwatchManager.linkStalledAlert(pluginIdentifier: "LupedSmartwatchManager", hostName: "Loop")
        let again = LupedSmartwatchManager.linkStalledAlert(pluginIdentifier: "LupedSmartwatchManager", hostName: "Loop")
        XCTAssertEqual(issued.identifier, again.identifier)
    }
}

final class LupedLocalizationTests: XCTestCase {
    func testNorwegianStringsShipWithTheFramework() throws {
        let bundle = Bundle(for: LupedSmartwatchManager.self)
        let path = try XCTUnwrap(bundle.path(forResource: "nb", ofType: "lproj"))
        let norwegian = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(norwegian.localizedString(forKey: "Watch not connected", value: nil, table: nil), "Klokken er ikke tilkoblet")
    }
}
