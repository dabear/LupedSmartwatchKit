//
//  LupedWatchSettingsView.swift
//  LupedSmartwatchKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKitUI
import LupedSmartwatchKit
import SwiftUI

/// Publishes the manager's settings to SwiftUI and saves edits back to it.
@MainActor
final class LupedSettingsModel: ObservableObject {
    let manager: LupedSmartwatchManager

    @Published var settings: LupedSettings {
        didSet { manager.settings = settings }
    }

    init(manager: LupedSmartwatchManager) {
        self.manager = manager
        settings = manager.settings
    }
}

/// Settings → Devices → Pebble: controls the Pebble watchface transport.
struct LupedWatchSettingsView: View {
    @ObservedObject var model: LupedSettingsModel
    var didFinish: () -> Void
    @State private var confirmingDelete = false

    private var transport: LupedTransport { model.manager.transport }

    var body: some View {
        List {
            LupedLinkStatusSection(transport: transport, status: transport.status)

            Section {
                Picker(LocalizedString("Layout", comment: "Picker choosing the Pebble watch layout"), selection: $model.settings.fullScreen) {
                    Text(LocalizedString("Graph", comment: "Pebble layout choice: glucose ring with a trend graph, status line and last loop")).tag(false)
                    Text(LocalizedString("Large Glucose", comment: "Pebble layout choice: a full-screen glucose ring only")).tag(true)
                }
                // Large Glucose shows neither; the choices are kept for Graph.
                if !model.settings.fullScreen {
                    Picker(LocalizedString("Status Line", comment: "Picker choosing what the Pebble status line shows"), selection: $model.settings.statusLine) {
                        ForEach(LupedStatusLine.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    Toggle(LocalizedString("Last Loop", comment: "Toggle showing the minutes since the last loop on the Pebble"), isOn: Binding(
                        get: { model.settings.showsLoopRing },
                        set: { model.settings.loopRing = $0 }
                    ))
                    .disabled(model.settings.statusLine != .none)
                }
            } header: {
                Text(LocalizedString("Display", comment: "Header for the Pebble display settings"))
            } footer: {
                Text(model.settings.displayFooter)
            }

            Section {
                Toggle(LocalizedString("Watch Alarms", comment: "Toggle enabling Pebble watch vibration alarms"), isOn: $model.settings.alarmsEnabled)
                // Only for a watch that reported a speaker (Pebble Time 2).
                if model.settings.watchHasSpeaker {
                    Picker(LocalizedString("Alarm Sound", comment: "Picker choosing which glucose alarms the Pebble also sounds"), selection: $model.settings.alarmSound) {
                        Text(LocalizedString("Off", comment: "Pebble alarm sound choice: no sound")).tag(LupedAlarmSound.off)
                        Text(LocalizedString("Urgent Low Only", comment: "Pebble alarm sound choice: only urgent low alarms")).tag(LupedAlarmSound.urgentLow)
                        Text(LocalizedString("All Glucose Alarms", comment: "Pebble alarm sound choice: every glucose alarm")).tag(LupedAlarmSound.all)
                    }
                    .disabled(!model.settings.alarmsEnabled)
                    if !model.settings.alarmsEnabled {
                        Text(LocalizedString("Turn on Watch Alarms to use Alarm Sound.", comment: "Pebble note: Alarm Sound needs Watch Alarms"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else if model.settings.alarmSound != .off {
                        LupedQuietTimeNote(status: transport.status)
                    }
                }
            } header: {
                Text(LocalizedString("Alarms", comment: "Header for the Pebble alarm settings"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: LocalizedString("The watch buzzes each time %1$@ alerts, and stays silent while %1$@'s alerts are muted. %1$@'s own alerts don't change.", comment: "Footer for the Pebble alarm settings (1: app name)"), LupedSmartwatchManager.hostName))
                    // Only when a sound is chosen, and Watch Alarms is on.
                    if model.settings.watchHasSpeaker, model.settings.alarmsEnabled, model.settings.alarmSound != .off {
                        Text(LocalizedString("The watch also beeps for these alarms. Set its volume on the watch.", comment: "Footer for the Pebble alarm sound, shown while a sound is chosen"))
                    }
                }
            }

            // Only with a remote capability declared (`offersLupedRemote`).
            if LupedSmartwatchManager.offersLupedRemote {
                Section {
                    Toggle(LocalizedString("Luped Remote", comment: "Toggle serving the Luped Remote watchapp"), isOn: $model.settings.remoteEnabled)
                    if model.settings.remoteEnabled {
                        LupedRemoteStatusRow(status: transport.status)
                    } else {
                        Link(LocalizedString("Get Luped Remote from the Pebble app store", comment: "Link to Luped Remote's page in the Pebble app store"), destination: LupedSmartwatchManager.lupedRemoteStoreURL)
                    }
                } header: {
                    Text(LocalizedString("Watch App", comment: "Header for the Luped Remote settings"))
                } footer: {
                    // Short, and only what the user needs for the toggle's state.
                    if model.settings.remoteEnabled {
                        Text(String(format: LocalizedString("Allow each action in %1$@'s Watch Permissions. On the watch, Settings → Quick Launch → Tap Up opens it.", comment: "Footer for the Luped Remote settings while it is on (1: app name)"), LupedSmartwatchManager.hostName))
                    } else {
                        Text(String(format: LocalizedString("A watch app for asking %1$@ to mute alerts, add carbs, use presets or give a bolus.", comment: "Footer for the Luped Remote settings while it is off (1: app name)"), LupedSmartwatchManager.hostName))
                    }
                }
            }

            Section {
                NavigationLink(destination: LupedDiagnosticsView(transport: transport)) {
                    Text(LocalizedString("Diagnostics", comment: "Row opening Pebble diagnostics"))
                }
                NavigationLink(destination: LupedAdvancedSettingsView(model: model)) {
                    Text(LocalizedString("Advanced", comment: "Row opening advanced Pebble settings"))
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text(LocalizedString("Delete Pebble", comment: "Button removing the Pebble smartwatch"))
                        .foregroundColor(.red)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Pebble", comment: "Title of the Pebble smartwatch settings screen"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(LocalizedString("Done", comment: "Button closing the Pebble settings"), action: didFinish)
            }
        }
        .confirmationDialog(LocalizedString("Are you sure you want to delete this Pebble?", comment: "Delete Pebble confirmation title"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(LocalizedString("Delete Pebble", comment: "Button removing the Pebble smartwatch"), role: .destructive) {
                Task {
                    await model.manager.delete()
                    didFinish()
                }
            }
        } message: {
            Text(String(format: LocalizedString("%@ stops sending to the watch and removes the Pebble settings. You can add it again under Devices.", comment: "Delete Pebble confirmation message (1: app name)"), LupedSmartwatchManager.hostName))
        }
    }
}

/// The watchface and Luped Remote UUIDs, which most people never change.
struct LupedAdvancedSettingsView: View {
    @ObservedObject var model: LupedSettingsModel

    var body: some View {
        List {
            LupedUUIDSection(
                title: LocalizedString("Watchface UUID", comment: "Header for the Pebble watchface UUID"),
                restoreTitle: LocalizedString("Use Luped CGM Watchface", comment: "Button restoring the default Pebble watchface UUID"),
                footer: LocalizedString("The UUID from the watchface's package.json. The watchface must use Luped's AppMessage keys and must not use PebbleKit JS.", comment: "Footer explaining the Pebble watchface UUID"),
                defaultUUID: LupedSettings.defaultWatchfaceUUID,
                uuid: $model.settings.watchfaceUUID
            )
            if LupedSmartwatchManager.offersLupedRemote {
                LupedUUIDSection(
                    title: LocalizedString("Luped Remote UUID", comment: "Header for the Luped Remote UUID"),
                    restoreTitle: LocalizedString("Use Luped Remote", comment: "Button restoring the default Luped Remote UUID"),
                    footer: model.settings.remoteUUID == model.settings.watchfaceUUID
                        ? LocalizedString("This is the watchface's UUID, so Luped Remote gets no connection of its own. Use a different one.", comment: "Footer when the Luped Remote UUID equals the watchface UUID")
                        : LocalizedString("The UUID from Luped Remote's package.json, for a build of your own. It must differ from the watchface's.", comment: "Footer explaining the Luped Remote UUID"),
                    defaultUUID: LupedSettings.defaultRemoteUUID,
                    uuid: $model.settings.remoteUUID
                )
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Advanced", comment: "Title of the advanced Pebble settings screen"))
    }
}

/// One app UUID: edit, save, or go back to the default.
struct LupedUUIDSection: View {
    let title: String
    let restoreTitle: String
    let footer: String
    let defaultUUID: UUID
    @Binding var uuid: UUID
    @State private var draft = ""

    private var defaultText: String { defaultUUID.uuidString.lowercased() }

    private var draftUUID: UUID? {
        UUID(uuidString: draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Section {
            TextField(defaultText, text: $draft)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            if draftUUID != uuid {
                Button(LocalizedString("Save", comment: "Button saving the Pebble watchface UUID"), action: save)
                    .disabled(draftUUID == nil)
            }
            if uuid != defaultUUID {
                Button(restoreTitle) {
                    draft = defaultText
                    save()
                }
            }
        } header: {
            Text(title)
        } footer: {
            if draftUUID == nil {
                Text(String(format: LocalizedString("Enter a UUID such as %@.", comment: "Footer shown for an invalid Pebble watchface UUID (1: example UUID)"), defaultText))
                    .foregroundColor(.red)
            } else {
                Text(footer)
            }
        }
        .onAppear { draft = uuid.uuidString.lowercased() }
    }

    private func save() {
        guard let new = draftUUID else { return }
        uuid = new
        draft = new.uuidString.lowercased()
    }
}

/// Luped Remote's watch session, and whether the watch is running it.
struct LupedRemoteStatusRow: View {
    @ObservedObject var status: LupedLinkStatus

    private var text: String {
        switch status.remoteLink {
        case .open:
            // The watch opens Luped Remote's session whether or not it is
            // installed: only a message from it says it is.
            if status.foreground == .remote {
                return LocalizedString("Open on the watch", comment: "Luped Remote status: the watch runs it")
            }
            return status.remoteLastSeen == nil
                ? LocalizedString("Not seen on the watch yet", comment: "Luped Remote status: the watch hasn't run it since the phone app started")
                : LocalizedString("Installed, not open", comment: "Luped Remote status: it has run, but the watch runs the watchface now")
        case .connecting: return LocalizedString("Connecting", comment: "Pebble link status: session handshake in progress")
        case .waitingForWatch: return LocalizedString("Waiting for the watch", comment: "Pebble link status: no watch session")
        case .bluetoothUnavailable: return LocalizedString("Bluetooth unavailable", comment: "Pebble link status: Bluetooth off or unauthorized")
        case .off: return LocalizedString("Off", comment: "Pebble link status: disabled")
        }
    }

    var body: some View {
        LabeledContent(LocalizedString("Status", comment: "Luped Remote status row"), value: text)
    }
}

/// Whether Loop is connected to the watch and when it last delivered a reading.
struct LupedLinkStatusSection: View {
    let transport: LupedTransport
    @ObservedObject var status: LupedLinkStatus

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var watchfaceRejected: Bool {
        guard let rejected = status.lastRejectedAt else { return false }
        return rejected > (status.lastDelivery?.deliveredAt ?? .distantPast)
    }

    private var headline: String {
        switch status.link {
        case .off: return LocalizedString("Off", comment: "Pebble link status: disabled")
        case .bluetoothUnavailable: return LocalizedString("Bluetooth unavailable", comment: "Pebble link status: Bluetooth off or unauthorized")
        case .waitingForWatch: return LocalizedString("Waiting for the watch", comment: "Pebble link status: no watch session")
        case .connecting: return LocalizedString("Connecting", comment: "Pebble link status: session handshake in progress")
        case .open:
            if status.paused {
                return LocalizedString("Connected · Luped CGM not open, sending paused", comment: "Pebble link status: sending paused after repeated rejections")
            }
            if watchfaceRejected {
                return LocalizedString("Connected · Luped CGM not open", comment: "Pebble link status: connected but the watch rejected the reading")
            }
            return status.foreground == .remote
                ? LocalizedString("Connected · Luped Remote open", comment: "Pebble link status: the watch runs Luped Remote")
                : LocalizedString("Connected", comment: "Pebble link status: session open")
        }
    }

    private var color: Color {
        switch status.link {
        case .open: return status.paused || watchfaceRejected ? .orange : .green
        case .connecting, .waitingForWatch: return .orange
        case .bluetoothUnavailable: return .red
        case .off: return .secondary
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status.link {
        case .connecting, .waitingForWatch:
            ProgressView()
        case .open where !status.paused && !watchfaceRejected:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .off:
            Image(systemName: "minus.circle").foregroundColor(.secondary)
        default:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(color)
        }
    }

    /// Device card like the CGM and pump settings screens: picture, model and link state.
    private var deviceCard: some View {
        HStack(spacing: 16) {
            Image(uiImage: PebbleArtwork.image)
                .resizable()
                .scaledToFit()
                .frame(height: 76)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(LupedSmartwatchManager.localizedTitle)
                    .font(.title3.bold())
                HStack(spacing: 6) {
                    statusIcon
                    Text(headline)
                        .font(.subheadline)
                        .foregroundColor(status.link == .open && !status.paused && !watchfaceRejected ? .primary : color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }

    var body: some View {
        Section {
            deviceCard
            if let delivery = status.lastDelivery {
                LabeledContent(LocalizedString("Last Reading", comment: "Pebble status row: time of the last delivered glucose reading"), value: Self.timeFormatter.string(from: delivery.readingDate))
                LabeledContent(LocalizedString("Delivered", comment: "Pebble status row: when the watch acknowledged the reading"), value: Self.timeFormatter.string(from: delivery.deliveredAt))
                LabeledContent(LocalizedString("Round Trip", comment: "Pebble status row: send to acknowledgement time"), value: String(format: LocalizedString("%d ms", comment: "Pebble round trip in milliseconds (1: milliseconds)"), delivery.milliseconds))
            }
            if let retryAt = status.retryAt {
                LabeledContent(LocalizedString("Next Retry", comment: "Pebble status row: time of the next delivery attempt"), value: Self.timeFormatter.string(from: retryAt))
            }
            Button(LocalizedString("Send Now", comment: "Button pushing the current reading to the Pebble watch")) {
                transport.sendNow()
            }
            .disabled(status.link == .off || status.link == .bluetoothUnavailable)
            if let result = status.lastResult {
                Text(result)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            // Whichever Luped app is running buzzes, beeps and lights up for 60 s.
            Button(LocalizedString("Find My Pebble", comment: "Button making the Pebble watch buzz and beep so it can be found")) {
                transport.findPebble()
            }
            .disabled(status.link != .open)
            if let note = status.findNote {
                Text(note)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button(LocalizedString("Stop Finding", comment: "Button stopping Find My Pebble on the watch")) {
                    transport.findPebble(seconds: 0)
                }
                .disabled(status.link != .open)
            }
        } header: {
            Text(LocalizedString("Status", comment: "Header for the Pebble link status section"))
        } footer: {
            Text(String(format: LocalizedString("%@ sends your readings and alerts to the Pebble over Bluetooth.", comment: "Footer explaining the Pebble smartwatch device (1: app name)"), LupedSmartwatchManager.hostName))
        }
    }
}

extension LupedSettings {
    /// The footer under the Display settings: what the watch shows and exactly
    /// what the app sends to it.
    var displayFooter: String {
        let host = LupedSmartwatchManager.hostName
        let explanation: String
        if fullScreen {
            explanation = LocalizedString("A large glucose ring with the reading time inside it, without graph, status line or last loop.", comment: "Footer for the Pebble Large Glucose layout")
        } else if statusLine != .none {
            explanation = String(format: LocalizedString("The status line shows under the glucose ring and dims when %1$@ hasn't looped for 16 minutes. Last Loop is always shown with a status line.", comment: "Footer for the Pebble Graph layout with a status line chosen (1: app name)"), host)
        } else if loopRing {
            explanation = String(format: LocalizedString("No status line. Last Loop shows the minutes since %1$@ last looped.", comment: "Footer for the Pebble Graph layout with status line None and Last Loop on (1: app name)"), host)
        } else {
            explanation = String(format: LocalizedString("No status line or last loop; the watch doesn't show when %1$@ last looped.", comment: "Footer for the Pebble Graph layout with status line None and Last Loop off (1: app name)"), host)
        }
        var sent = [LocalizedString("glucose", comment: "Item in the Pebble 'sent to the watch' list"), LocalizedString("alerts", comment: "Item in the Pebble 'sent to the watch' list")]
        if shownStatusLine == .iobAndCob {
            sent.append(LocalizedString("IOB and COB", comment: "Item in the Pebble 'sent to the watch' list"))
        }
        if showsLoopRing {
            sent.append(LocalizedString("last loop", comment: "Item in the Pebble 'sent to the watch' list"))
        }
        switch shownStatusLine {
        case .tempBasal: sent.append(LocalizedString("temp basal", comment: "Item in the Pebble 'sent to the watch' list"))
        case .eventualGlucose: sent.append(LocalizedString("eventual glucose", comment: "Item in the Pebble 'sent to the watch' list"))
        case .sensitivityAndTarget: sent.append(LocalizedString("ISF and target", comment: "Item in the Pebble 'sent to the watch' list"))
        case .none, .iobAndCob: break
        }
        let sentLine = String(format: LocalizedString("Sent to the watch: %@.", comment: "Pebble footer listing what the app sends to the watch (1: comma-separated list)"), sent.joined(separator: ", "))
        let battery: String
        if shownStatusLine == .iobAndCob {
            battery = String(format: LocalizedString("Uses a little more watch battery.", comment: "Pebble footer: battery note for the IOB & COB status line (1: app name)"), host)
        } else if showsLoopRing {
            battery = LocalizedString("The watch may get an occasional extra update between readings.", comment: "Pebble footer: battery note when loop status or therapy values are sent")
        } else {
            battery = LocalizedString("Only new readings and alerts are sent, which uses the least watch battery.", comment: "Pebble footer: battery note when only glucose and alerts are sent")
        }
        return explanation + "\n\n" + sentLine + " " + battery
    }
}

extension LupedStatusLine {
    /// The name shown in the Status Line picker.
    var title: String {
        switch self {
        case .none: LocalizedString("None", comment: "Pebble status line choice: nothing on the status line")
        case .iobAndCob: LocalizedString("IOB & COB", comment: "Pebble status line choice: insulin and carbs on board")
        case .tempBasal: LocalizedString("Temp Basal", comment: "Pebble status line choice: current temp or scheduled basal rate")
        case .eventualGlucose: LocalizedString("Eventual Glucose", comment: "Pebble status line choice: predicted eventual glucose")
        case .sensitivityAndTarget: LocalizedString("ISF & Target", comment: "Pebble status line choice: insulin sensitivity and correction range")
        }
    }
}

/// Under Alarm Sound, only while the watch says it is in Quiet Time, which
/// can mute the beep.
struct LupedQuietTimeNote: View {
    @ObservedObject var status: LupedLinkStatus

    var body: some View {
        if status.speaker?.quietTime == true {
            Label(LocalizedString("Quiet Time on the watch may silence the beep.", comment: "Pebble note: the watch's Quiet Time is on and may mute the alarm sound"), systemImage: "moon.fill")
                .font(.footnote)
                .foregroundColor(.orange)
        }
    }
}
