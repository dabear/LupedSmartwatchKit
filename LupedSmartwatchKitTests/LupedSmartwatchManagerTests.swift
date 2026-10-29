//
//  LupedSmartwatchManagerTests.swift
//  LupedSmartwatchKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
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
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .none, loopRing: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        XCTAssertEqual(manager.requestedCapabilities, [.glucose, .history, .alerts])

        manager.settings.loopRing = true
        XCTAssertEqual(manager.requestedCapabilities, [.glucose, .history, .alerts, .loopStatus], "None with the loop ring still needs the loop's age")
        XCTAssertEqual(delegate.refreshRequests, 1)

        manager.settings.statusLine = .iobAndCob
        XCTAssertEqual(delegate.refreshRequests, 1, "same capabilities: no new snapshot needed")

        manager.settings.statusLine = .eventualGlucose
        XCTAssertEqual(manager.requestedCapabilities, [.glucose, .history, .alerts, .loopStatus, .therapy])
        XCTAssertEqual(delegate.refreshRequests, 2)

        manager.settings.loopRing = false
        XCTAssertEqual(manager.requestedCapabilities, [.glucose, .history, .alerts, .loopStatus, .therapy], "a shown line keeps the loop ring")
        XCTAssertTrue(manager.requestedCapabilities.isSubset(of: LupedSmartwatchManager.capabilities))

        manager.settings.fullScreen = true
        XCTAssertEqual(manager.requestedCapabilities, [.glucose, .history, .alerts], "Large Glucose shows no status line or last loop")
        XCTAssertEqual(delegate.refreshRequests, 3)
        manager.settings.fullScreen = false
        XCTAssertEqual(manager.requestedCapabilities, [.glucose, .history, .alerts, .loopStatus, .therapy], "the chosen line comes back")
    }

    // A plugin can't obtain a capability it didn't declare: hosts act only on
    // effectiveCapabilities (declared ∩ requested).
    func testUndeclaredRequestedCapabilitiesAreIgnored() {
        let greedy = GreedySmartwatchManager()
        XCTAssertEqual(greedy.effectiveCapabilities, [.glucose])

        let luped = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false, statusLine: .eventualGlucose))
        XCTAssertEqual(luped.effectiveCapabilities, luped.requestedCapabilities)
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

    /// The plugin's own alert lines show in the in-app log.
    func testAlertNotesShowInCommunicationLog() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: false))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        let log = manager.transport.communicationLog
        log.clear()
        delegate.logEntries.removeAll()

        manager.watchAlertDidIssue(SmartwatchAlert(identifier: SmartwatchAlertIdentifier("glucose.high"), level: .warning, title: "High Glucose", issuedAt: Date()))
        XCTAssertTrue(log.entries.last?.message.hasPrefix("\(LupedSmartwatchManager.hostName) alert issued [warning], event 1: High Glucose") == true, log.text)
        XCTAssertEqual(delegate.logEntries.count, 1)
    }

    /// Delete from the settings screen asks the host to remove the manager and
    /// switches the Bluetooth link off.
    func testDeleteRemovesTheManagerAndStopsTheLink() async {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true))
        let delegate = MockSmartwatchManagerDelegate()
        manager.smartwatchManagerDelegate = delegate
        manager.transportIfStarted = LupedTransport(hostName: LupedSmartwatchManager.hostName, settings: manager.settings)

        let deleted = expectation(description: "delete completes")
        manager.delete { deleted.fulfill() }
        await fulfillment(of: [deleted], timeout: 2)

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
        XCTAssertEqual(snapshot.alertEvent, 0)
    }

    /// Luped declares loop status (IOB/COB and the loop ring) and therapy (the
    /// other status line choices) but handles no URL. Remote actions stay off
    /// until requests are secured.
    func testOptionalHostFeaturesStayOff() throws {
        XCTAssertEqual(LupedSmartwatchManager.capabilities, [.glucose, .history, .alerts, .loopStatus, .therapy])
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

        manager.watchAlertDidIssue(urgentLow)
        XCTAssertEqual(manager.alertEvent, 1)
        XCTAssertEqual(manager.hostAlertState, 2)

        manager.watchAlertDidIssue(urgentLow)  // the host's repeat fire
        XCTAssertEqual(manager.alertEvent, 2)
        XCTAssertEqual(manager.hostAlertState, 2, "A repeat doesn't change the state")
        XCTAssertEqual(delegate.stateUpdates, 2, "Each fire saves the new event")

        let restored = try XCTUnwrap(LupedSmartwatchManager(rawState: manager.rawState))
        XCTAssertEqual(restored.alertEvent, 2)
    }

    /// The event advances while watch alarms are off, so turning them back on
    /// doesn't replay an alert the watch was told to ignore.
    func testAlertEventAdvancesWhileWatchAlarmsOff() {
        let manager = LupedSmartwatchManager(settings: LupedSettings(isEnabled: true, alarmsEnabled: false))
        manager.smartwatchManagerDelegate = MockSmartwatchManagerDelegate()
        manager.watchAlertDidIssue(glucoseAlert("low"))
        XCTAssertEqual(manager.alertEvent, 1)
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
    func smartwatchManager(_ manager: SmartwatchManager, requestBolus request: SmartwatchBolusRequest) async throws -> Double { throw SmartwatchBolusError.notAllowed }
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
    var requestedCapabilities: SmartwatchCapabilities { [.glucose, .remoteBolus, .loopStatus] }
    var pluginIdentifier: String { "Greedy" }
    weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?
    init() {}
    init?(rawState: RawStateValue) {}
    var rawState: RawStateValue { [:] }
    func watchDataDidUpdate(_ snapshot: SmartwatchStatusSnapshot) {}
}
