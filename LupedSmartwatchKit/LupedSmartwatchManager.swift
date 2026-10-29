//
//  LupedSmartwatchManager.swift
//  LupedSmartwatchKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

@_exported import LupedKit
import Foundation
import LoopKit

/// Shows the host app's glucose on a Pebble running the Luped watchface, over
/// LupedKit's direct Bluetooth link.
///
/// The host sends a snapshot as soon as a new reading is stored; it is
/// forwarded to the watch right away. Alerts are host-issued: the host
/// evaluates its own alerts and forwards them, rather than the watch evaluating
/// thresholds itself.
public final class LupedSmartwatchManager: SmartwatchManager {
    public static let pluginIdentifier = "LupedSmartwatchManager"

    /// The host app's name, for status and log messages.
    public static var hostName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Loop"
    }
    public static let localizedTitle = LocalizedString("Pebble", comment: "Title of the Luped Pebble watch manager")

    /// Remote actions (`.remoteMute`, `.remoteBolus`, `.remoteCarbs`) are not
    /// declared: their request handling below is ready, but the watchface has to
    /// react to `RESULT` and the requests need stronger security first. Without
    /// them, a request from the watch is logged as ignored and never reaches the host.
    /// `.loopStatus` feeds the watch's IOB/COB strip and loop ring; `.therapy`
    /// the other status line choices (temp basal, eventual glucose, ISF & target).
    public static var capabilities: SmartwatchCapabilities { [.glucose, .history, .alerts, .loopStatus, .therapy] }

    /// Only what the watch shows: loop status while the loop ring shows (every
    /// shown line, and None with Last Loop on), therapy values for the lines the
    /// phone formats from them; with the Large Glucose layout neither. History is
    /// always requested: the delta and trend come from it. The host fills nothing
    /// else.
    public var requestedCapabilities: SmartwatchCapabilities {
        var requested: SmartwatchCapabilities = [.glucose, .history, .alerts]
        if settings.needsLoopStatus { requested.insert(.loopStatus) }
        if settings.needsTherapy { requested.insert(.therapy) }
        return requested
    }


    public var pluginIdentifier: String { Self.pluginIdentifier }
    public var localizedTitle: String { Self.localizedTitle }

    public weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?

    /// Luped's settings, saved in `rawState`. Changes apply to the watch link.
    public var settings: LupedSettings {
        get { lockedSettings.value }
        set {
            guard newValue != lockedSettings.value else { return }
            let requestedBefore = requestedCapabilities
            lockedSettings.value = newValue
            Task { @MainActor in
                self.transportIfStarted?.settings = newValue
            }
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
            // The host fills only what is requested; ask it for a snapshot with the new set.
            if requestedCapabilities != requestedBefore {
                smartwatchManagerDelegate?.smartwatchManagerRequestsRefresh(self)
            }
        }
    }
    private let lockedSettings: Locked<LupedSettings>

    /// The watch's alert event (DATA index 9): advanced on every host alert fire,
    /// including repeats of an alert that is still active, so the watch buzzes in
    /// step with the host even when the level doesn't change. Advanced whether or
    /// not watch alarms are on, so re-enabling them doesn't replay an old fire.
    /// Saved in `rawState` so a relaunch can't land on the value the watch last saw.
    var alertEvent: Int { lockedAlertEvent.value }
    private let lockedAlertEvent: Locked<Int>
    /// The alert event wraps here; the watch compares for inequality.
    static let alertEventModulus = 1000

    /// The watch's last diagnostics report. The watchface reports about once an
    /// hour; saving the report in `rawState` lets the watch info show right after a
    /// relaunch instead of waiting up to an hour for the next one.
    struct SavedDiagnostics: Equatable {
        var json: String
        var receivedAt: Date
    }
    var savedDiagnostics: SavedDiagnostics? { lockedDiagnostics.value }
    private let lockedDiagnostics: Locked<SavedDiagnostics?>

    @MainActor var latestSnapshot: SmartwatchStatusSnapshot?
    @MainActor var transportIfStarted: LupedTransport?

    /// Host-issued alerts currently showing, by identifier. The watch colours its
    /// ring and buzzes from them; neither the plugin nor the watch has thresholds.
    @MainActor var activeAlerts: [SmartwatchAlertIdentifier: SmartwatchAlert] = [:]

    /// When this manager started tracking alerts. Alerts the host issued before
    /// then (for example before a relaunch) are only known once it issues them again.
    private let alertTrackingStarted = Date()

    /// The glucose alert states the watch knows (DATA index 8), most important first.
    static let alertStatePriority = [2, 1, 3, 4]

    /// The watch's alert state for a host alert: 1 low, 2 urgent low, 3 high,
    /// 4 predicted low; `nil` for anything that isn't a glucose alert. From the
    /// type the host sets, not its alert identifiers, which differ per host.
    static func alertState(for alert: SmartwatchAlert) -> Int? {
        switch alert.glucoseAlertType {
        case .urgentLow: 2
        case .low: 1
        case .high: 3
        case .predictedLow: 4
        case nil: nil
        }
    }

    /// What the watch sees (DATA index 8): the most important active glucose
    /// alert (urgent low, low, high, predicted low), 0 when none. The watch colours
    /// its ring from it: red for low and urgent low, amber for high, green
    /// otherwise. Negative while the user's Watch Alarms switch is off: the ring
    /// keeps its colour, but the watch only buzzes for a positive state. Host
    /// alert mute is followed on the host side (muted alerts aren't forwarded).
    @MainActor var hostAlertState: Int {
        let active = Set(activeAlerts.values.compactMap(Self.alertState(for:)))
        guard let state = Self.alertStatePriority.first(where: active.contains) else { return 0 }
        return settings.alarmsEnabled ? state : -state
    }

    /// Why `hostAlertState` is what it is, for the communication log.
    @MainActor var hostAlertReason: String {
        guard !activeAlerts.isEmpty else {
            let since = DateFormatter.localizedString(from: alertTrackingStarted, dateStyle: .none, timeStyle: .short)
            return "no active alerts from \(Self.hostName) since \(since); muted alerts aren't sent"
        }
        let priority = { (alert: SmartwatchAlert) in Self.alertState(for: alert).flatMap(Self.alertStatePriority.firstIndex(of:)) ?? Int.max }
        let titles = activeAlerts.values
            .sorted { priority($0) < priority($1) }
            .map { $0.title ?? $0.identifier.value }
            .joined(separator: ", ")
        return titles
    }

    public init(settings: LupedSettings = LupedSettings(isEnabled: true)) {
        lockedSettings = Locked(settings)
        lockedAlertEvent = Locked(0)
        lockedDiagnostics = Locked(nil)
    }

    public init?(rawState: RawStateValue) {
        lockedSettings = Locked(LupedSettings(rawValue: rawState["settings"] as? LupedSettings.RawValue ?? [:]))
        lockedAlertEvent = Locked((rawState["alertEvent"] as? Int ?? 0) % Self.alertEventModulus)
        if let json = rawState["watchDiagnostics"] as? String,
           let receivedAt = rawState["watchDiagnosticsReceivedAt"] as? TimeInterval {
            lockedDiagnostics = Locked(SavedDiagnostics(json: json, receivedAt: Date(timeIntervalSince1970: receivedAt)))
        } else {
            lockedDiagnostics = Locked(nil)
        }
    }

    public var rawState: RawStateValue {
        var state: RawStateValue = ["settings": settings.rawValue, "alertEvent": alertEvent]
        if let saved = savedDiagnostics {
            state["watchDiagnostics"] = saved.json
            state["watchDiagnosticsReceivedAt"] = saved.receivedAt.timeIntervalSince1970
        }
        return state
    }

    public var isOnboarded: Bool { true }
    public var inSignalLoss: Bool { false }
    public var isInoperable: Bool { false }

    /// The watch link, started on first use.
    @MainActor
    public var transport: LupedTransport {
        if let transportIfStarted {
            return transportIfStarted
        }
        let transport = LupedTransport(hostName: Self.hostName, settings: settings)
        transport.diagnosticLog = { [weak self] kind, message in
            self?.logDeviceCommunication(message, kind: kind)
        }
        transport.snapshotProvider = { [weak self] in
            self?.lupedSnapshot()
        }
        transport.diagnosticsDidArrive = { [weak self] json, receivedAt in
            guard let self else { return }
            self.lockedDiagnostics.value = SavedDiagnostics(json: json, receivedAt: receivedAt)
            self.smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
        transport.alertMuteRequested = { [weak self] duration in
            self?.requestAlertMute(duration)
        }
        transport.bolusRequested = { [weak self] units, forced in
            self?.requestBolus(units, forced: forced)
        }
        transport.carbsRequested = { [weak self] grams in
            self?.requestCarbs(grams)
        }
        if let saved = savedDiagnostics {
            transport.restoreDiagnostics(json: saved.json, receivedAt: saved.receivedAt)
        }
        transportIfStarted = transport
        transport.start()
        if !Self.hasBluetoothPeripheralBackgroundMode() {
            logNote("\(Self.hostName) was built without the bluetooth-peripheral background mode: the watch only updates while \(Self.hostName) is in the foreground", kind: .error)
        }
        return transport
    }

    /// Passes the watch's mute request to the host and logs the outcome.
    @MainActor
    func requestAlertMute(_ duration: TimeInterval) {
        // Without `.remoteMute` the host never hears of it.
        guard effectiveCapabilities.contains(.remoteMute) else {
            logNote("Mute request from the watch ignored: remote mute is off for this watch", kind: .info)
            transport.sendResult("mute:ignored")
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Mute request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendResult("mute:failed")
            return
        }
        Task { @MainActor in
            do {
                let end = try await delegate.smartwatchManager(self, requestAlertMute: duration)
                let time = DateFormatter.localizedString(from: end, dateStyle: .none, timeStyle: .short)
                logNote("\(Self.hostName) alerts muted from the watch until \(time)", kind: .info)
                transport.sendResult("mute:ok")
            } catch {
                logNote("\(Self.hostName) refused the watch's mute request (\(error)); check Allow Mute from Watch in \(Self.hostName)'s settings", kind: .error)
                transport.sendResult("mute:refused")
            }
        }
    }

    /// Asks the host for the bolus the watch chose, against the bolus context it
    /// last sent, and logs the outcome. The host's policy decides: permission,
    /// request and context age, maximum bolus, recommendation (skipped when
    /// `forced`) and rate limits.
    @MainActor
    func requestBolus(_ units: Double, forced: Bool = false) {
        let action = forced ? "forcedbolus" : "bolus"
        guard effectiveCapabilities.contains(.remoteBolus) else {
            logNote("Bolus request from the watch ignored: remote bolus is off for this watch", kind: .info)
            transport.sendResult("\(action):ignored")
            return
        }
        guard let delegate = smartwatchManagerDelegate else {
            logNote("Bolus request not passed on: \(Self.hostName) isn't connected to this watch manager", kind: .error)
            transport.sendResult("\(action):failed")
            return
        }
        guard let context = latestSnapshot?.bolusContext else {
            logNote("Bolus request not passed on: \(Self.hostName) hasn't sent a bolus context yet (Allow Boluses from Watch may be off)", kind: .error)
            transport.sendResult("\(action):failed")
            return
        }
        let request = SmartwatchBolusRequest(units: units, contextToken: context.token, requestedAt: Date(), isForced: forced)
        logNote(String(format: "Asking %@ for a %.2f U %@from the watch", Self.hostName, request.units, forced ? "forced bolus (recommendation not checked) " : "bolus "), kind: .info)
        Task { @MainActor in
            do {
                let units = try await delegate.smartwatchManager(self, requestBolus: request)
                logNote(String(format: "%@ delivered %.2f U requested from the watch", Self.hostName, units), kind: .info)
                transport.sendResult("\(action):ok")
            } catch SmartwatchBolusError.inProgress {
                // A repeat of the bolus being delivered: the first request's result follows.
                logNote("\(Self.hostName) is still delivering this bolus; its result follows", kind: .info)
            } catch {
                logNote("\(Self.hostName) refused the watch's bolus request (\(error))", kind: .error)
                transport.sendResult("\(action):refused")
            }
        }
    }

    /// Asks the host to add the carb entry the watch chose, and logs the outcome.
    /// The host decides: permission and rate limit.
    @MainActor
    func requestCarbs(_ grams: Double) {
        guard effectiveCapabilities.contains(.remoteCarbs) else {
            logNote("Carb request from the watch ignored: remote carbs are off for this watch", kind: .info)
            transport.sendResult("carbs:ignored")
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
                let request = SmartwatchCarbEntryRequest(grams: grams, requestedAt: Date())
                let grams = try await delegate.smartwatchManager(self, requestCarbEntry: request)
                logNote(String(format: "%@ added %g g of carbs requested from the watch", Self.hostName, grams), kind: .info)
                transport.sendResult("carbs:ok")
            } catch {
                logNote("\(Self.hostName) refused the watch's carb request (\(error))", kind: .error)
                transport.sendResult("carbs:refused")
            }
        }
    }

    /// Whether the app may keep the watch's Bluetooth service running in the background.
    public static func hasBluetoothPeripheralBackgroundMode() -> Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("bluetooth-peripheral") == true
    }

    @MainActor
    public func watchDataDidUpdate(_ snapshot: SmartwatchStatusSnapshot) {
        latestSnapshot = snapshot
        Task { await transport.refresh() }
    }

    @MainActor
    public func watchAlertDidIssue(_ alert: SmartwatchAlert) {
        activeAlerts[alert.identifier] = alert
        // Every fire (first or repeat) is a new event for the watch to buzz on.
        lockedAlertEvent.value = (lockedAlertEvent.value + 1) % Self.alertEventModulus
        smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        logNote("\(Self.hostName) alert issued [\(alert.level)], event \(alertEvent): \(alert.title ?? "") \(alert.body ?? "")", kind: .info)
        // Resend the snapshot so the watch sees the new alert level/event and buzzes.
        Task { await transport.refresh() }
    }

    @MainActor
    public func watchAlertDidRetract(_ identifier: SmartwatchAlertIdentifier) {
        guard let alert = activeAlerts.removeValue(forKey: identifier) else { return }
        logNote("\(Self.hostName) alert retracted: \(alert.title ?? identifier.value)", kind: .info)
        Task { await transport.refresh() }
    }

    /// Shows the host's alert notes (why an alert wasn't sent, when it repeats)
    /// next to the watch traffic. The host already wrote them to its device log.
    @MainActor
    public func watchHostDidLog(_ message: String) {
        transport.communicationLog.append(.info, "\(Self.hostName): \(message)")
    }

    public func delete(completion: @escaping () -> Void) {
        Task { @MainActor in
            // Removes the Bluetooth service and stops retries.
            transportIfStarted?.settings.isEnabled = false
            notifyDelegateOfDeletion(completion: completion)
        }
    }

    @MainActor
    func lupedSnapshot() -> LupedSnapshot? {
        guard let snapshot = latestSnapshot else {
            return nil
        }
        let start = Date(timeIntervalSinceNow: -LupedPayload.historyInterval)
        let samples = snapshot.glucoseHistory.filter { $0.date >= start }
        let readings = samples
            .filter { !$0.wasUserEntered && !$0.isDisplayOnly }
            .map { sample in
                LupedReading(
                    date: sample.date,
                    milligramsPerDeciliter: sample.milligramsPerDeciliter,
                    trend: sample.trend.map(LupedTrend.init)
                )
            }
        return LupedSnapshot(
            readings: readings,
            storedSampleCount: samples.count,
            unit: snapshot.displayUnit == .millimolesPerLiter ? .millimolesPerLiter : .milligramsPerDeciliter,
            hostAlertState: hostAlertState,
            hostAlertReason: hostAlertReason,
            alertEvent: alertEvent,
            // IOB, COB and the loop's age and mode for the watch's strip and loop ring.
            loopStatus: LupedLoopStatus(
                insulinOnBoard: snapshot.insulinOnBoard,
                carbsOnBoard: snapshot.carbsOnBoard,
                lastLoopCompleted: snapshot.lastLoopCompleted,
                isClosedLoop: snapshot.isClosedLoop
            ),
            therapy: snapshot.therapy.map {
                LupedTherapy(
                    tempBasalRate: $0.tempBasalRate,
                    scheduledBasalRate: $0.scheduledBasalRate,
                    insulinSensitivity: $0.insulinSensitivity,
                    eventualGlucose: $0.eventualGlucose,
                    correctionRange: $0.correctionRange
                )
            }
        )
    }

    /// A note of the plugin's own, for the in-app communication log and the host's
    /// device log. Transport lines reach the in-app log through the transport.
    @MainActor
    func logNote(_ message: String, kind: LupedCommunicationLog.Kind) {
        transport.communicationLog.append(kind, message)
        logDeviceCommunication(message, kind: kind)
    }

    func logDeviceCommunication(_ message: String, kind: LupedCommunicationLog.Kind) {
        let type: SmartwatchDeviceLogEntry.EntryType
        switch kind {
        case .toWatch: type = .send
        case .fromWatch: type = .receive
        case .error: type = .error
        case .info: type = .connection
        }
        smartwatchManagerDelegate?.smartwatchManager(self, didLogEvent: SmartwatchDeviceLogEntry(type: type, message: message, deviceIdentifier: settings.watchfaceUUID.uuidString.lowercased()))
    }
}

// MARK: - CustomDebugStringConvertible

extension LupedSmartwatchManager {
    public var debugDescription: String {
        let settings = settings
        return [
            "## LupedSmartwatchManager",
            "* enabled: \(settings.isEnabled)",
            "* watchfaceUUID: \(settings.watchfaceUUID.uuidString.lowercased())",
            "* alarmsEnabled: \(settings.alarmsEnabled)",
            "* layout: \(settings.fullScreen ? "Large Glucose" : "Graph")",
            "* statusLine: \(settings.statusLine.displayName)",
            "* lastLoop: \(settings.loopRing)",
        ].joined(separator: "\n")
    }
}

// MARK: - DeviceManager

// Loop places the watch under Settings → Devices and routes its logs and alert
// responses through the DeviceManager machinery. This conformance is kept out of
// the core SmartwatchManager protocol so the plugin also builds for hosts (such
// as Trio) that import it statically without a device seam.
extension LupedSmartwatchManager: DeviceManager {
    // Watches don't issue LoopKit alerts. Both AlertResponder forms are defaulted
    // so the plugin builds against LoopKit variants that declare either one.
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws {}
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) { completion(nil) }
    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }
}

private extension LupedTrend {
    init(_ trend: SmartwatchGlucoseTrend) {
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
