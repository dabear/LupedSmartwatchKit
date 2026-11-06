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

    private func sample(_ mgdl: Double, minutes: Double, trend: SmartwatchGlucoseTrend? = .flat, wasUserEntered: Bool = false) -> SmartwatchGlucoseReading {
        SmartwatchGlucoseReading(
            date: start.addingTimeInterval(minutes * 60),
            milligramsPerDeciliter: mgdl,
            trend: trend,
            wasUserEntered: wasUserEntered
        )
    }

    func testRawStateRoundTrips() throws {
        let settings = LupedSettings(isEnabled: true, watchfaceUUID: UUID(), alarmsEnabled: false, fullScreen: true)
        let manager = LupedSmartwatchManager(settings: settings)
        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.settings, settings)
    }

    // The host fills only what the watch shows (status line and loop ring), and
    // is asked for a new snapshot when that changes.
    func testRequestedCapabilitiesFollowTheStatusLineAndLoopRing() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .none, loopRing: false, remoteEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts])

        manager.settings.loopRing = true
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts, .loopStatus], "None with the loop ring still needs the loop's age")
        XCTAssertEqual(delegate.refreshRequests, 1)

        manager.settings.statusLine = .iobAndCob
        XCTAssertEqual(delegate.refreshRequests, 1, "same capabilities: no new snapshot needed")

        manager.settings.statusLine = .eventualGlucose
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts, .loopStatus, .therapy])
        XCTAssertEqual(delegate.refreshRequests, 2)

        manager.settings.loopRing = false
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts, .loopStatus, .therapy], "a shown line keeps the loop ring")
        XCTAssertTrue(manager.requestedCapabilities.isSubset(of: LupedSmartwatchManager.capabilities))

        manager.settings.fullScreen = true
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts], "Large Glucose shows no status line or last loop")
        XCTAssertEqual(delegate.refreshRequests, 3)
        manager.settings.fullScreen = false
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts, .loopStatus, .therapy], "the chosen line comes back")
    }

    // The host's errors become RESULT outcomes with a reason the watch shows.
    func testHostErrorsBecomeOutcomesWithReasons() {
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchCarbEntryError.rateLimited) == ("refused", .tooSoon))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchBolusError.exceedsMaximumBolus) == ("refused", .overMaximum))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchAlertMuteError.notAllowed) == ("refused", .notAllowed))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchPresetError.unknownPreset) == ("refused", .noSuchPreset))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchBolusError.deliveryFailed("pump")) == ("failed", nil))
        XCTAssertTrue(LupedSmartwatchManager.answer(for: SmartwatchBolusError.refusedByHost("no")) == ("refused", nil))
    }

    // Luped Remote shows IOB and COB whatever the watchface shows.
    func testLupedRemoteAlwaysNeedsTheLoopStatus() {
        // Luped Remote is off by default; turned on, it needs the loop status.
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, fullScreen: true))
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts])
        manager.settings.remoteEnabled = true
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts, .loopStatus])
        manager.settings.remoteEnabled = false
        XCTAssertEqual(manager.requestedCapabilities.subtracting(LupedSmartwatchManager.remoteCapabilities), [.glucose, .history, .alerts])
    }

    // Luped Remote is offered only with a remote capability declared; without one
    // its saved switch is ignored, so its watch session never opens.
    func testLupedRemoteNeedsADeclaredRemoteCapability() {
        XCTAssertTrue(LupedSmartwatchManager.offersLupedRemote, "this build declares the remote capabilities")
        XCTAssertTrue(LupedSmartwatchManager.capabilities.isSuperset(of: LupedSmartwatchManager.remoteCapabilities))

        let on = LupedSettings(isEnabled: true, remoteEnabled: true)
        XCTAssertFalse(LupedSmartwatchManager.linkSettings(on, offersLupedRemote: false).servesRemote)
        XCTAssertFalse(LupedSmartwatchManager.linkSettings(on, offersLupedRemote: false).remoteEnabled, "nor asks the host for loop status for it")
        XCTAssertTrue(LupedSmartwatchManager.linkSettings(on, offersLupedRemote: true).servesRemote)
    }

    // A plugin can't obtain a capability it didn't declare: hosts act only on
    // effectiveCapabilities (declared ∩ requested).
    func testUndeclaredRequestedCapabilitiesAreIgnored() {
        let greedy = GreedySmartwatchManager()
        XCTAssertEqual(greedy.effectiveCapabilities, [.glucose])
        XCTAssertEqual(greedy.undeclaredRequestedCapabilities, [.prediction, .loopStatus])
        XCTAssertEqual(greedy.undeclaredRequestedCapabilities.description, "prediction, loopStatus", "hosts log the names")
        XCTAssertEqual(SmartwatchCapabilities([]).description, "none")
        XCTAssertEqual(SmartwatchCapabilities([.glucose, SmartwatchCapabilities(rawValue: 1 << 20)]).description, "glucose, raw value 1048576")

        let luped = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .eventualGlucose))
        XCTAssertEqual(luped.effectiveCapabilities, luped.requestedCapabilities)
        XCTAssertTrue(luped.undeclaredRequestedCapabilities.isEmpty)
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

    /// Luped's communication log reaches Loop's device log, keyed by the
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

        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose.high"), level: .warning, title: "High Glucose", issuedAt: Date()))
        XCTAssertTrue(log.entries.last?.message.hasPrefix("\(LupedSmartwatchManager.hostName) alert issued [warning], event \(manager.alertEvent): High Glucose") == true, log.text)
        XCTAssertEqual(delegate.logEntries.count, 1)

        manager.watchHostDidLog("Next alert: from 11:25 if glucose stays above 10.0 mmol/L")
        XCTAssertEqual(log.entries.last?.message, "\(LupedSmartwatchManager.hostName): Next alert: from 11:25 if glucose stays above 10.0 mmol/L")
        XCTAssertEqual(log.entries.last?.kind, .info)
        XCTAssertEqual(delegate.logEntries.count, 1, "The host already logged its note")
    }

    /// Luped Remote's recommendation request reaches the host with its carbs, and
    /// the host's answer (or refusal, with its reason) goes back as RECOMMEND.
    /// With no remote running here, the answer is logged as not sent.
    func testBolusRecommendationRequestReachesTheHost() async throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let log = manager.transport.communicationLog
        delegate.recommendation = .success(SmartwatchBolusRecommendation(units: 0.45, grams: 10, maximumBolus: 5, issuedAt: Date()))

        manager.requestBolusRecommendation(10)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(delegate.recommendationRequests, [10])
        XCTAssertTrue(log.entries.contains { $0.message == "RECOMMEND 10:ok:0.45:5 not sent: Luped Remote is no longer running" }, log.text)

        delegate.recommendation = .failure(SmartwatchBolusError.noRecentGlucose)
        manager.requestBolusRecommendation(0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(delegate.recommendationRequests, [10, 0])
        XCTAssertTrue(log.entries.contains { $0.message == "RECOMMEND 0:refused:no recent glucose not sent: Luped Remote is no longer running" }, log.text)
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

    func testSnapshotBecomesLupedSnapshot() throws {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        XCTAssertNil(manager.lupedSnapshot(), "Nothing to send before the first snapshot")

        let history = [
            sample(100, minutes: 0),
            sample(250, minutes: 2, wasUserEntered: true),
            sample(110, minutes: 5, trend: .upUp),
        ]
        manager.latestSnapshot = SmartwatchStatusSnapshot(displayUnit: .millimolesPerLiter, glucose: history.last, glucoseHistory: history)

        let snapshot = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(snapshot.unit, .millimolesPerLiter)
        XCTAssertEqual(snapshot.storedSampleCount, 3)
        XCTAssertEqual(snapshot.readings.map(\.milligramsPerDeciliter), [100, 110], "User-entered samples are not CGM readings")
        XCTAssertEqual(snapshot.readings.last?.trend, .singleUp)
        // Alerts are host-issued: no alert has fired yet.
        XCTAssertEqual(snapshot.hostAlertState, 0)
        XCTAssertEqual(snapshot.alertEvent, manager.alertEvent)
    }

    /// Luped declares loop status (IOB/COB and the loop ring) and therapy (the
    /// other status line choices) but handles no URL. Remote actions stay off
    /// until requests are secured.
    func testOptionalHostFeaturesStayOff() throws {
        XCTAssertEqual(LupedSmartwatchManager.capabilities, [.glucose, .history, .alerts, .loopStatus, .therapy, .remoteMute, .remoteCarbs, .remoteBolus, .remoteOverride, .remoteTempTarget])
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let reading = sample(120, minutes: 5)
        manager.latestSnapshot = SmartwatchStatusSnapshot(displayUnit: .milligramsPerDeciliter, glucose: reading, glucoseHistory: [reading])
        let plain = try XCTUnwrap(manager.lupedSnapshot())
        manager.latestSnapshot = SmartwatchStatusSnapshot(
            displayUnit: .milligramsPerDeciliter, glucose: reading, glucoseHistory: [reading],
            insulinOnBoard: 1.2, carbsOnBoard: 15,
            therapy: SmartwatchTherapyContext(tempBasalRate: 0.4, insulinSensitivity: 45, correctionRange: 100...110, activePresetName: "Exercise")
        )
        let withExtras = try XCTUnwrap(manager.lupedSnapshot())
        XCTAssertEqual(withExtras.readings, plain.readings)
        XCTAssertEqual(withExtras.unit, plain.unit)
        // Loop status reaches the watch (IOB/COB strip and loop ring).
        XCTAssertEqual(withExtras.loopStatus, LupedLoopStatus(insulinOnBoard: 1.2, carbsOnBoard: 15))
        // Therapy values reach the status line choices (the preset is not used).
        XCTAssertEqual(withExtras.therapy, LupedTherapy(tempBasalRate: 0.4, insulinSensitivity: 45, correctionRange: 100...110))
        XCTAssertFalse(manager.watchHostDidReceiveURL(URL(string: "trio://smartwatch/callback")!))
    }

    private func glucoseAlert(_ kind: String, _ level: SmartwatchAlertLevel = .warning, title: String? = nil) -> SmartwatchAlert {
        // The identifier is host-specific (here Trio-style, with a UUID); the type is what counts.
        SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose." + kind), level: level, title: title, body: nil, issuedAt: Date(), glucoseAlertType: SmartwatchGlucoseAlertType(rawValue: kind))
    }

    /// The watch's alert state (DATA index 8) is the most important active glucose
    /// alert: urgent low, low, high, predicted low; retracting falls back.
    func testHostIssuedAlertSetsState() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        XCTAssertEqual(manager.hostAlertState, 0)

        manager.watchAlertDidIssue(glucoseAlert("predictedLow"))
        XCTAssertEqual(manager.hostAlertState, 4)
        manager.watchAlertDidIssue(glucoseAlert("high", title: "High Glucose"))
        XCTAssertEqual(manager.hostAlertState, 3, "High outranks predicted low")
        XCTAssertTrue(delegate.logEntries.contains { $0.type == .connection && $0.message.contains("High Glucose") })
        manager.watchAlertDidIssue(glucoseAlert("low"))
        XCTAssertEqual(manager.hostAlertState, 1, "Low outranks high")
        manager.watchAlertDidIssue(glucoseAlert("urgentLow", .critical))
        XCTAssertEqual(manager.hostAlertState, 2, "Urgent low outranks everything")
        manager.watchAlertDidRetract(SmartwatchAlertIdentifier("glucose.urgentLow"))
        XCTAssertEqual(manager.hostAlertState, 1)
        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("Pump.occlusion"), level: .critical, title: nil, body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.hostAlertState, 1, "Non-glucose alerts don't set a state")
        for kind in ["low", "high", "predictedLow"] {
            manager.watchAlertDidRetract(SmartwatchAlertIdentifier("glucose." + kind))
        }
        XCTAssertEqual(manager.hostAlertState, 0)
    }

    /// The state comes from the host's glucose alert type, whatever its identifiers
    /// look like (Trio's are `Trio.glucose.<type>.<UUID>`).
    func testAlertStateUsesTheTypeNotTheIdentifier() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("Trio.glucose.low.3F2A9C1E"), level: .critical, title: "Low", body: nil, issuedAt: Date(), glucoseAlertType: .low))
        XCTAssertEqual(manager.hostAlertState, 1)
        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("GlucoseAlertManager.glucose.high"), level: .warning, title: nil, body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.hostAlertState, 1, "An alert without a glucose type doesn't set a state")
    }

    /// With watch alarms off the state is negative: the ring keeps its colour, but
    /// the watch only buzzes for a positive state.
    func testWatchAlarmsOffNegatesTheState() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, alarmsEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        manager.watchAlertDidIssue(glucoseAlert("low", .critical))
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

        manager.watchAlertDidIssue(urgentLow)
        XCTAssertEqual(manager.alertEvent, (start + 1) % LupedSmartwatchManager.alertEventModulus)
        XCTAssertEqual(manager.hostAlertState, 2)

        manager.watchAlertDidIssue(urgentLow)  // the host's repeat fire
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
        manager.watchAlertDidIssue(glucoseAlert("high", title: "High Glucose"))
        manager.watchAlertDidIssue(glucoseAlert("low", .critical))

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

        restored.watchAlertDidRetract(SmartwatchAlertIdentifier("glucose.low"))
        XCTAssertEqual(restored.hostAlertState, 3)
        XCTAssertEqual(delegate.stateUpdates, 1, "A retraction saves the state")
        restored.watchAlertDidRetract(SmartwatchAlertIdentifier("glucose.high"))
        let relaunchedAgain = try XCTUnwrap(LupedSmartwatchManager(rawState: restored.rawState))
        XCTAssertEqual(relaunchedAgain.hostAlertState, 0)
        XCTAssertNil(restored.rawState["activeAlerts"])
    }

    /// The event advances while watch alarms are off, so turning them back on
    /// doesn't replay an alert the watch was told to ignore.
    func testAlertEventAdvancesWhileWatchAlarmsOff() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, alarmsEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        let start = manager.alertEvent
        manager.watchAlertDidIssue(glucoseAlert("low"))
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

    func testAlertEventWraps() throws {
        let manager = try XCTUnwrap(LupedSmartwatchManager(rawState: ["alertEvent": LupedSmartwatchManager.alertEventModulus - 1]))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose.high"), level: .warning, title: nil, body: nil, issuedAt: Date()))
        XCTAssertEqual(manager.alertEvent, 0)
    }
}

private final class MockSmartwatchManagerDelegate: SmartwatchManagerDelegate {
    var logEntries: [SmartwatchDeviceLogEntry] = []
    var stateUpdates = 0
    var deletions = 0

    func smartwatchManagerDidUpdateState(_ manager: SmartwatchManager) { stateUpdates += 1 }
    func smartwatchManagerWantsDeletion(_ manager: SmartwatchManager) async { deletions += 1 }
    var refreshRequests = 0
    func smartwatchManagerRequestsRefresh(_ manager: SmartwatchManager) { refreshRequests += 1 }
    func smartwatchManager(_ manager: SmartwatchManager, didLogEvent event: SmartwatchDeviceLogEntry) { logEntries.append(event) }
    var recommendationRequests: [Double] = []
    var recommendation: Result<SmartwatchBolusRecommendation, Error> = .failure(SmartwatchBolusError.notAllowed)
    func smartwatchManager(_ manager: SmartwatchManager, recommendBolusFor request: SmartwatchBolusRecommendationRequest) async throws -> SmartwatchBolusRecommendation {
        recommendationRequests.append(request.grams)
        return try recommendation.get()
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

/// Declares only glucose but asks for more.
private final class GreedySmartwatchManager: SmartwatchManager {
    static var capabilities: SmartwatchCapabilities { [.glucose] }
    var requestedCapabilities: SmartwatchCapabilities { [.glucose, .prediction, .loopStatus] }
    var pluginIdentifier: String { "Greedy" }
    weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?
    init() {}
    init?(rawState: RawStateValue) {}
    var rawState: RawStateValue { [:] }
    func watchDataDidUpdate(_ snapshot: SmartwatchStatusSnapshot) {}
}
