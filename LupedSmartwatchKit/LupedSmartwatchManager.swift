//
//  LupedSmartwatchManager.swift
//  LupedSmartwatchKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

@_exported import LupedKit
import Foundation
import LoopKit
import UIKit

/// Shows the host app's glucose on a Pebble running the Luped watchface, over
/// LupedKit's direct Bluetooth link.
///
/// The host says what changed (`hostDataDidChange`) as soon as a new reading is
/// stored and again after the loop runs; the plugin reads what the watch shows
/// and forwards it to the watch right away. Alerts are host-issued: the host
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

    /// Whether Luped Remote is offered: its requests, each confirmed on the
    /// watch, need the user's switch in the Pebble settings for each action.
    /// Set to false, its settings are hidden and its watch session never opens.
    public static let offersLupedRemote = true

    /// The settings the watch link uses: Luped Remote off when it isn't offered,
    /// whatever was saved.
    static func linkSettings(_ settings: LupedSettings, offersLupedRemote: Bool = offersLupedRemote) -> LupedSettings {
        var settings = settings
        settings.remoteEnabled = settings.remoteEnabled && offersLupedRemote
        return settings
    }

    /// What the plugin reads from the host: only what the watch shows.
    struct HostReads: Equatable {
        /// The loop state, while the loop ring shows (every shown line, and None
        /// with Last Loop on), Luped Remote is on (it always shows IOB and COB),
        /// or the status line shows eventual glucose.
        var loopState: Bool
        /// Therapy values for the status lines the phone formats from them.
        var therapy: Bool
        /// Luped Remote's preset lists and bolus context, while it is on.
        var remote: Bool
    }

    /// With the Large Glucose layout and Luped Remote off, neither loop state
    /// nor therapy. Glucose is always read: the delta and trend come from it.
    static func hostReads(for settings: LupedSettings) -> HostReads {
        let linkSettings = linkSettings(settings)
        return HostReads(
            loopState: linkSettings.hostNeedsLoopStatus || settings.needsTherapy,
            therapy: settings.needsTherapy,
            remote: linkSettings.remoteEnabled
        )
    }

    var hostReads: HostReads { Self.hostReads(for: settings) }

    public var pluginIdentifier: String { Self.pluginIdentifier }
    public var localizedTitle: String { Self.localizedTitle }

    public weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?

    /// Luped's settings, saved in `rawState`. Changes apply to the watch link.
    public var settings: LupedSettings {
        get { lockedSettings.value }
        set {
            var newValue = newValue
            // Learned from the watch, not chosen: a settings screen opened
            // before the report mustn't clear it.
            newValue.watchHasSpeaker = newValue.watchHasSpeaker || lockedSettings.value.watchHasSpeaker
            guard newValue != lockedSettings.value else { return }
            let readsBefore = hostReads
            lockedSettings.value = newValue
            // Only what the watch shows is read: read again for what it shows now.
            let readsChanged = hostReads != readsBefore
            Task { @MainActor in
                self.transportIfStarted?.settings = Self.linkSettings(newValue)
                self.transportIfStarted?.issuesBolusKey = self.bolusKeyAllowed
                if readsChanged {
                    self.hostDataDidChange(.all)
                }
            }
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }
    private let lockedSettings: Locked<LupedSettings>

    /// Which Luped Remote requests the user allows, saved in `rawState`. All off
    /// until turned on, and off again when the watch is deleted.
    public var remotePermissions: LupedRemotePermissions {
        get { lockedRemotePermissions.value }
        set {
            guard newValue != lockedRemotePermissions.value else { return }
            lockedRemotePermissions.value = newValue
            Task { @MainActor in
                self.transportIfStarted?.issuesBolusKey = self.bolusKeyAllowed
                self.logNote("Allowed from Luped Remote: \(newValue.allowedDescription)", kind: .info)
            }
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }
    private let lockedRemotePermissions: Locked<LupedRemotePermissions>

    /// The watch's alert event (DATA index 9): advanced on every host alert fire,
    /// including repeats of an alert that is still active, so the watch buzzes in
    /// step with the host even when the level doesn't change. Advanced whether or
    /// not watch alarms are on, so re-enabling them doesn't replay an old fire.
    /// Saved in `rawState` so a relaunch can't land on the value the watch last saw.
    var alertEvent: Int { lockedAlertEvent.value }
    private let lockedAlertEvent: Locked<Int>
    /// Alert events run from 1 to `alertEventModulus - 1` and wrap back to 1; the
    /// watch compares for inequality. 0 means no alert yet and is never an
    /// event: the alarm sound is asked for by sending the event negative.
    static let alertEventModulus = 1000

    /// The event after `event`: 1 after 0 and after the last one.
    static func nextAlertEvent(after event: Int) -> Int {
        event % (alertEventModulus - 1) + 1
    }

    /// The watch's last diagnostics report. The watchface reports about once an
    /// hour; saving the report in `rawState` lets the watch info show right after a
    /// relaunch instead of waiting up to an hour for the next one.
    struct SavedDiagnostics: Equatable {
        var json: String
        var receivedAt: Date
    }
    var savedDiagnostics: SavedDiagnostics? { lockedDiagnostics.value }
    private let lockedDiagnostics: Locked<SavedDiagnostics?>

    /// Whether the watch gets a bolus key: Luped Remote is on and the user
    /// allows boluses from it, so the remote dims Bolus otherwise.
    @MainActor var bolusKeyAllowed: Bool {
        Self.linkSettings(settings).remoteEnabled && remotePermissions.bolus
    }

    /// What the plugin last read from the host, for the next `LupedSnapshot`.
    @MainActor var hostData = LupedHostData()
    /// The host reads queued so far; each runs after the previous one.
    @MainActor var hostReadTask: Task<Void, Never>?
    /// Changes the host signalled that aren't read yet, and the timer that reads them.
    @MainActor var pendingHostChanges: SmartwatchHostDataChange = []
    @MainActor var pendingHostChangesTask: Task<Void, Never>?
    /// Hands out the bolus context and tracks the watch bolus being delivered.
    @MainActor var bolusContextIssuer = SmartwatchBolusContextIssuer()
    /// The context last issued, which a bolus request quotes. It stays after a
    /// bolus spent it, so a resend of that bolus is recognised as in progress.
    @MainActor var bolusContext: SmartwatchBolusContext?
    /// Luped Remote's recent boluses and last carb entry, for the rate limits.
    @MainActor var remoteHistory = LupedRemoteHistory(defaults: .standard)
    @MainActor var transportIfStarted: LupedTransport?

    /// Host-issued alerts currently showing, by identifier. The watch colours its
    /// ring and buzzes from them; neither the plugin nor the watch has thresholds.
    /// Saved in `rawState`: after a relaunch the host doesn't issue an alert again
    /// for an episode it already alerted on, but it still retracts it.
    @MainActor var activeAlerts: [String: LupedHostAlert] {
        get { lockedActiveAlerts.value }
        set { lockedActiveAlerts.value = newValue }
    }
    private let lockedActiveAlerts: Locked<[String: LupedHostAlert]>

    /// When this manager started tracking alerts, for the communication log.
    /// Alerts active at a relaunch come back from `rawState`.
    private let alertTrackingStarted = Date()

    /// The glucose alert states the watch knows (DATA index 8), most important first.
    static let alertStatePriority = [2, 1, 3, 4]

    /// The watch's alert state for a host alert: 1 low, 2 urgent low, 3 high,
    /// 4 predicted low; `nil` for anything that isn't a glucose alert. From the
    /// type the host sets, not its alert identifiers, which differ per host.
    static func alertState(for alert: LupedHostAlert) -> Int? {
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
        let priority = { (alert: LupedHostAlert) in Self.alertState(for: alert).flatMap(Self.alertStatePriority.firstIndex(of:)) ?? Int.max }
        let titles = activeAlerts.values
            .sorted { priority($0) < priority($1) }
            .map { $0.title ?? $0.identifier }
            .joined(separator: ", ")
        return titles
    }

    /// A new manager (a watch added again) starts its alert event at a random
    /// value: the watch may still hold the previous manager's, and a first alert
    /// landing on it would not buzz.
    public init(settings: LupedSettings = LupedSettings(isEnabled: true)) {
        lockedSettings = Locked(settings)
        lockedRemotePermissions = Locked(.none)
        lockedAlertEvent = Locked(Int.random(in: 1..<Self.alertEventModulus))
        lockedDiagnostics = Locked(nil)
        lockedActiveAlerts = Locked([:])
    }

    public init?(rawState: RawStateValue) {
        lockedSettings = Locked(LupedSettings(rawValue: rawState["settings"] as? LupedSettings.RawValue ?? [:]))
        lockedRemotePermissions = Locked(LupedRemotePermissions(rawValue: rawState["remotePermissions"] as? LupedRemotePermissions.RawValue ?? [:]))
        lockedAlertEvent = Locked((rawState["alertEvent"] as? Int ?? 0) % Self.alertEventModulus)
        if let json = rawState["watchDiagnostics"] as? String,
           let receivedAt = rawState["watchDiagnosticsReceivedAt"] as? TimeInterval {
            lockedDiagnostics = Locked(SavedDiagnostics(json: json, receivedAt: Date(timeIntervalSince1970: receivedAt)))
        } else {
            lockedDiagnostics = Locked(nil)
        }
        let savedAlerts = (rawState["activeAlerts"] as? [[String: Any]] ?? []).compactMap(LupedHostAlert.init(savedState:))
        lockedActiveAlerts = Locked(Dictionary(savedAlerts.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last }))
    }

    public var rawState: RawStateValue {
        var state: RawStateValue = ["settings": settings.rawValue, "remotePermissions": remotePermissions.rawValue, "alertEvent": alertEvent]
        if let saved = savedDiagnostics {
            state["watchDiagnostics"] = saved.json
            state["watchDiagnosticsReceivedAt"] = saved.receivedAt.timeIntervalSince1970
        }
        let alerts = lockedActiveAlerts.value
        if !alerts.isEmpty {
            state["activeAlerts"] = alerts.values.sorted { $0.issuedAt < $1.issuedAt }.map(\.savedState)
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
        let transport = LupedTransport(hostName: Self.hostName, settings: Self.linkSettings(settings))
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
        // Until a Luped app has reported a speaker, ask the watchface once per
        // session: it may have started before this watch was added.
        transport.asksForSpeaker = !settings.watchHasSpeaker
        // While a reading waits for the loop result, iOS mustn't suspend the app,
        // or the watch gets it only when the app is opened again.
        transport.beginBackgroundTask = { name in
            let task = BackgroundTask(name: name)
            return { task.end() }
        }
        // A Luped app reported a speaker: offer the alarm sound from now on.
        transport.speakerDidReport = { [weak self] _ in
            guard let self, !self.settings.watchHasSpeaker else { return }
            self.settings.watchHasSpeaker = true
        }
        transport.alertMuteRequested = { [weak self] duration, requestedAt in
            self?.requestAlertMute(duration, requestedAt: requestedAt)
        }
        transport.bolusRequested = { [weak self] units, forced, grams, absorption, requestedAt in
            self?.requestBolus(units, forced: forced, grams: grams, absorption: absorption, requestedAt: requestedAt)
        }
        transport.bolusRecommendationRequested = { [weak self] grams, absorption in
            self?.requestBolusRecommendation(grams, absorption: absorption)
        }
        // A session key only while the user allows boluses from this watch.
        transport.issuesBolusKey = bolusKeyAllowed
        transport.carbsRequested = { [weak self] grams, absorption, requestedAt in
            self?.requestCarbs(grams, absorption: absorption, requestedAt: requestedAt)
        }
        transport.overrideRequested = { [weak self] action, requestedAt in
            self?.requestOverride(action, requestedAt: requestedAt)
        }
        transport.tempTargetRequested = { [weak self] action, requestedAt in
            self?.requestTempTarget(action, requestedAt: requestedAt)
        }
        transport.linkStalledDidChange = { [weak self] stalled in
            self?.watchLinkStalledDidChange(stalled)
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

    /// Luped Remote's page in the Pebble app store.
    public static let lupedRemoteStoreURL = URL(string: "https://apps.rePebble.com/a7e1cad620804edbb52ee761")!

    /// Whether the app may keep the watch's Bluetooth service running in the background.
    public static func hasBluetoothPeripheralBackgroundMode() -> Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("bluetooth-peripheral") == true
    }

    static let linkStalledAlertIdentifier = "watchLinkStalled"

    /// The alert asking the user to close and open the host app again: the
    /// services were published again several times while a Pebble stayed
    /// connected, and no watch opened a session. A restart has fixed it; nothing
    /// else tried has. About the watch itself, never about glucose.
    static func linkStalledAlert(pluginIdentifier: String, hostName: String) -> Alert {
        let content = Alert.Content(
            title: LocalizedString("Watch not connected", comment: "Alert title: the watch doesn't open a session with the app"),
            body: String(format: LocalizedString("The watch is connected to the iPhone but not to %1$@, so it isn't getting new data. Close %1$@ completely and open it again.", comment: "Alert body: %1$@ is the app name"), hostName),
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledge button")
        )
        return Alert(
            identifier: Alert.Identifier(managerIdentifier: pluginIdentifier, alertIdentifier: linkStalledAlertIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .timeSensitive
        )
    }

    /// Issues the "close and open the app again" alert while the link is stalled
    /// and withdraws it when a watch session opens (or the app has restarted).
    @MainActor
    func watchLinkStalledDidChange(_ stalled: Bool) {
        guard let delegate = smartwatchManagerDelegate else { return }
        let alert = Self.linkStalledAlert(pluginIdentifier: pluginIdentifier, hostName: Self.hostName)
        if stalled {
            logNote("Asking the user to close and open \(Self.hostName) again: the watch doesn't open a session", kind: .error)
            Task { await delegate.issueAlert(alert) }
        } else {
            Task { await delegate.retractAlert(identifier: alert.identifier) }
        }
    }

    @MainActor
    public func watchAlertDidIssue(_ alert: Alert, glucoseAlertType: SmartwatchGlucoseAlertType?, issuedAt: Date) {
        let alert = LupedHostAlert(alert, glucoseAlertType: glucoseAlertType, issuedAt: issuedAt)
        activeAlerts[alert.identifier] = alert
        // Every fire (first or repeat) is a new event for the watch to buzz on.
        lockedAlertEvent.value = Self.nextAlertEvent(after: lockedAlertEvent.value)
        smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        logNote("\(Self.hostName) alert issued [\(alert.level)], event \(alertEvent): \(alert.title ?? "") \(alert.body ?? "")", kind: .info)
        // Resend the snapshot so the watch sees the new alert level/event and buzzes.
        Task { await transport.refresh() }
    }

    @MainActor
    public func watchAlertDidRetract(_ identifier: Alert.Identifier) {
        guard let alert = activeAlerts.removeValue(forKey: identifier.value) else { return }
        smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        logNote("\(Self.hostName) alert retracted: \(alert.title ?? identifier.value)", kind: .info)
        Task { await transport.refresh() }
    }

    /// Shows the host's alert notes (why an alert wasn't sent, when it repeats)
    /// next to the watch traffic. The host already wrote them to its device log.
    @MainActor
    public func watchHostDidLog(_ message: String) {
        transport.communicationLog.append(.info, "\(Self.hostName): \(message)")
    }

    /// Stops the link and turns every Luped Remote request off, so a watch added
    /// later starts with none allowed. The rate-limit history is kept
    /// (`LupedRemoteHistory`). The plugin issues no alerts of its own, so there
    /// are none to retract.
    public func delete() async {
        // First, so a switch change still on its way can't give the key back.
        lockedRemotePermissions.value = .none
        smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        // Removes the Bluetooth service and stops retries.
        await MainActor.run {
            // No read after the host dropped the manager.
            pendingHostChangesTask?.cancel()
            pendingHostChangesTask = nil
            pendingHostChanges = []
            transportIfStarted?.issuesBolusKey = false
            transportIfStarted?.settings.isEnabled = false
        }
        await smartwatchManagerDelegate?.smartwatchManagerWantsDeletion(self)
    }

    /// A note of the plugin's own, for the in-app communication log and the host's
    /// device log. Transport lines reach the in-app log through the transport.
    @MainActor
    func logNote(_ message: String, kind: LupedCommunicationLog.Kind) {
        transport.communicationLog.append(kind, message)
        logDeviceCommunication(message, kind: kind)
    }

    func logDeviceCommunication(_ message: String, kind: LupedCommunicationLog.Kind) {
        let type: DeviceLogEntryType
        switch kind {
        case .toWatch: type = .send
        case .fromWatch: type = .receive
        case .error: type = .error
        case .info: type = .connection
        }
        smartwatchManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: settings.watchfaceUUID.uuidString.lowercased(), type: type, message: message, completion: nil)
    }
}

/// One iOS background task, ended once: by its owner, or when iOS takes the time back.
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
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
            "* lupedRemote: \(settings.remoteEnabled)",
            "* allowedFromLupedRemote: \(remotePermissions.allowedDescription)",
        ].joined(separator: "\n")
    }
}

// MARK: - AlertResponder, AlertSoundVendor

// Loop registers the watch with its alert manager like a CGM or pump. The
// plugin issues no alerts of its own (watch problems show in its settings and
// log), so there is nothing to acknowledge and no sound to vendor.
extension LupedSmartwatchManager {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws {}
    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }
}

extension LupedRemotePermissions {
    /// The allowed requests, for logs, for example "bolus, carbs"; "none" when none is.
    var allowedDescription: String {
        let allowed = [(bolus, "bolus"), (carbs, "carbs"), (mute, "mute"), (overrides, "presets"), (tempTargets, "temp targets")]
            .filter(\.0)
            .map(\.1)
        return allowed.isEmpty ? "none" : allowed.joined(separator: ", ")
    }
}

/// A host alert showing on the watch.
struct LupedHostAlert: Equatable {
    /// How urgent the host made it, from its interruption level; saved as the raw value.
    enum Level: Int, Equatable {
        case informational
        case warning
        case critical

        init(_ level: Alert.InterruptionLevel) {
            switch level {
            case .active: self = .informational
            case .timeSensitive: self = .warning
            case .critical: self = .critical
            }
        }
    }

    /// The host's `Alert.Identifier.value`, which the retraction names.
    var identifier: String
    var level: Level
    var title: String?
    var body: String?
    /// When the host issued the alert.
    var issuedAt: Date
    /// Set by the host for glucose alerts; `nil` for any other alert.
    var glucoseAlertType: SmartwatchGlucoseAlertType?

    init(identifier: String, level: Level, title: String?, body: String?, issuedAt: Date, glucoseAlertType: SmartwatchGlucoseAlertType?) {
        self.identifier = identifier
        self.level = level
        self.title = title
        self.body = body
        self.issuedAt = issuedAt
        self.glucoseAlertType = glucoseAlertType
    }

    init(_ alert: Alert, glucoseAlertType: SmartwatchGlucoseAlertType?, issuedAt: Date) {
        let content = alert.foregroundContent ?? alert.backgroundContent
        self.init(
            identifier: alert.identifier.value,
            level: Level(alert.interruptionLevel),
            title: content.title,
            body: content.body,
            issuedAt: issuedAt,
            glucoseAlertType: glucoseAlertType
        )
    }

    /// How an active alert is saved in the manager's `rawState`.
    var savedState: [String: Any] {
        var state: [String: Any] = ["identifier": identifier, "level": level.rawValue, "issuedAt": issuedAt.timeIntervalSince1970]
        state["title"] = title
        state["body"] = body
        state["glucoseAlertType"] = glucoseAlertType?.rawValue
        return state
    }

    init?(savedState: [String: Any]) {
        guard let identifier = savedState["identifier"] as? String,
              let level = (savedState["level"] as? Int).flatMap(Level.init(rawValue:)),
              let issuedAt = savedState["issuedAt"] as? TimeInterval
        else {
            return nil
        }
        self.init(
            identifier: identifier,
            level: level,
            title: savedState["title"] as? String,
            body: savedState["body"] as? String,
            issuedAt: Date(timeIntervalSince1970: issuedAt),
            glucoseAlertType: (savedState["glucoseAlertType"] as? String).flatMap(SmartwatchGlucoseAlertType.init(rawValue:))
        )
    }
}
