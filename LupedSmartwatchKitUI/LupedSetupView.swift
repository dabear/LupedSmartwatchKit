//
//  LupedSetupView.swift
//  LupedSmartwatchKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKitUI
import LupedSmartwatchKit
import SwiftUI
import UIKit

/// Where to get the Luped CGM watchface.
let lupedWatchfaceStoreURL = URL(string: "https://apps.repebble.com/luped-cgm_d47105a3c7c1489895b067ff")!

/// Adds a Pebble. The Pebble app already pairs the watch, so setup only sets
/// expectations, adds the watch, and confirms that a reading reached it.
final class LupedSetupNavigationController: UINavigationController, SmartwatchManagerOnboarding, CompletionNotifying {
    weak var smartwatchManagerOnboardingDelegate: SmartwatchManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    init() {
        super.init(nibName: nil, bundle: nil)
        let model = LupedSetupModel()
        model.didAdd = { [weak self] manager in
            // The watch manager is onboarded as soon as it exists; the host
            // starts sending it snapshots right away.
            self?.smartwatchManagerOnboardingDelegate?.smartwatchManagerOnboarding(didCreateSmartwatchManager: manager)
            self?.smartwatchManagerOnboardingDelegate?.smartwatchManagerOnboarding(didOnboardSmartwatchManager: manager)
        }
        let view = LupedSetupView(model: model) { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        setViewControllers([UIHostingController(rootView: view)], animated: false)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class LupedSetupModel: ObservableObject {
    @Published private(set) var manager: LupedSmartwatchManager?
    var didAdd: (LupedSmartwatchManager) -> Void = { _ in }

    func add() {
        guard manager == nil else { return }
        let manager = LupedSmartwatchManager()
        self.manager = manager
        didAdd(manager)
    }
}

struct LupedSetupView: View {
    @ObservedObject var model: LupedSetupModel
    var finish: () -> Void

    var body: some View {
        if let manager = model.manager {
            LupedSetupProgressView(transport: manager.transport, status: manager.transport.status, finish: finish)
        } else {
            LupedSetupIntroView(add: model.add, cancel: finish)
        }
    }
}

/// What Loop sends to the watch, and what the user needs before adding it.
struct LupedSetupIntroView: View {
    var add: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(uiImage: PebbleArtwork.image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 110)
                            .accessibilityHidden(true)
                        Text(String(format: LocalizedString("%1$@ sends each new glucose reading to your Pebble as soon as it arrives, and the watch buzzes when %1$@ raises a glucose alert.", comment: "Pebble setup introduction (1: app name)"), LupedSmartwatchManager.hostName))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    LupedChecklistRow(number: 1, text: LocalizedString("Pair a Core Devices Pebble Time 2 or Pebble Round 2 in the Pebble app. Older Pebbles can't run Luped CGM.", comment: "Pebble setup checklist: pair a supported watch"))
                    LupedChecklistRow(number: 2, text: LocalizedString("Install the Luped CGM watchface.", comment: "Pebble setup checklist: install the watchface")) {
                        Link(LocalizedString("Get Luped CGM", comment: "Link to the Luped CGM watchface in the Pebble app store"), destination: lupedWatchfaceStoreURL)
                            .font(.subheadline.weight(.semibold))
                    }
                    LupedChecklistRow(number: 3, text: LocalizedString("Make Luped CGM your watchface.", comment: "Pebble setup checklist: select the watchface"))
                    LupedChecklistRow(number: 4, text: LocalizedString("If another diabetes app on this iPhone also has this Pebble added as a watch, remove it there first: the watch can only follow one of them. Keep the watch paired in the Pebble app.", comment: "Pebble setup checklist: only one diabetes app may use the watch; the Pebble app pairing stays"))
                } header: {
                    Text(LocalizedString("Before You Start", comment: "Header for the Pebble setup checklist"))
                } footer: {
                    Text(String(format: LocalizedString("There is nothing to pair in %1$@: the watch finds %1$@ over the Pebble app's Bluetooth connection.", comment: "Footer for the Pebble setup checklist (1: app name)"), LupedSmartwatchManager.hostName))
                }

                Section {
                    EmptyView()
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: LocalizedString("You can turn Watch Alarms off later in the Pebble settings; %@'s own alerts are unaffected.", comment: "Pebble setup note about watch alarms (1: app name)"), LupedSmartwatchManager.hostName))
                        if !LupedSmartwatchManager.hasBluetoothPeripheralBackgroundMode() {
                            Text(String(format: LocalizedString("This build of %1$@ can only update the watch while %1$@ is open.", comment: "Pebble setup warning when the app lacks the bluetooth-peripheral background mode (1: app name)"), LupedSmartwatchManager.hostName))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .insetGroupedListStyle()

            Button(LocalizedString("Add Pebble", comment: "Button adding the Pebble watch"), action: add)
                .buttonStyle(ActionButtonStyle())
                .padding()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(LocalizedString("Pebble", comment: "Title of the Pebble setup screen"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(LocalizedString("Cancel", comment: "Button cancelling Pebble setup"), action: cancel)
            }
        }
    }
}

struct LupedChecklistRow<Accessory: View>: View {
    var number: Int
    var text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                accessory()
            }
        } icon: {
            Image(systemName: "\(number).circle")
                .foregroundColor(.accentColor)
        }
    }
}

extension LupedChecklistRow where Accessory == EmptyView {
    init(number: Int, text: String) {
        self.init(number: number, text: text) { EmptyView() }
    }
}

/// Live progress after the watch is added, until the watch confirms a reading.
struct LupedSetupProgressView: View {
    let transport: LupedTransport
    @ObservedObject var status: LupedLinkStatus
    var finish: () -> Void

    private var progress: LupedSetupProgress { LupedSetupProgress(status) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(spacing: 12) {
                        icon
                            .font(.system(size: 56, weight: .light))
                            .frame(height: 64)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(detail)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    LupedStepRow(done: progress != .bluetoothUnavailable, text: String(format: LocalizedString("%@ is ready for the watch", comment: "Pebble setup step: Bluetooth service published (1: app name)"), LupedSmartwatchManager.hostName))
                    LupedStepRow(done: watchConnected, text: LocalizedString("Watch connected", comment: "Pebble setup step: watch connected"))
                    LupedStepRow(done: progress.isComplete, text: LocalizedString("Reading shown on the watch", comment: "Pebble setup step: reading delivered"))
                }

                if progress == .waitingForReading || progress == .watchfaceNotRunning {
                    Section {
                        Button(LocalizedString("Send Now", comment: "Button pushing the current reading to the Pebble watch"), action: transport.sendNow)
                        if progress == .watchfaceNotRunning {
                            Link(destination: lupedWatchfaceStoreURL) {
                                Label(LocalizedString("Get Luped CGM", comment: "Link to the Luped CGM watchface in the Pebble app store"), systemImage: "arrow.down.app")
                            }
                        }
                    } footer: {
                        if let result = status.lastResult {
                            Text(result)
                        }
                    }
                }
            }
            .insetGroupedListStyle()

            VStack(spacing: 8) {
                Button(LocalizedString("Done", comment: "Button finishing Pebble setup"), action: finish)
                    .buttonStyle(ActionButtonStyle(progress.isComplete ? .primary : .secondary))
                if !progress.isComplete {
                    Text(String(format: LocalizedString("You can finish now. %@ keeps connecting in the background, and Settings → Devices → Pebble shows the status.", comment: "Note below the Done button while Pebble setup is still in progress (1: app name)"), LupedSmartwatchManager.hostName))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(LocalizedString("Pebble", comment: "Title of the Pebble setup screen"))
        .navigationBarBackButtonHidden(true)
        .animation(.default, value: progress)
    }

    private var watchConnected: Bool {
        status.link == .open || progress.isComplete
    }

    @ViewBuilder
    private var icon: some View {
        switch progress {
        case .delivered:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .bluetoothUnavailable, .watchfaceNotRunning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .waitingForWatch, .connecting, .waitingForReading:
            ProgressView().controlSize(.large)
        }
    }

    private var title: String {
        switch progress {
        case .bluetoothUnavailable:
            return LocalizedString("Bluetooth Is Off", comment: "Pebble setup title: Bluetooth unavailable")
        case .waitingForWatch:
            return LocalizedString("Waiting for Your Pebble", comment: "Pebble setup title: waiting for the watch")
        case .connecting:
            return LocalizedString("Connecting", comment: "Pebble setup title: connecting")
        case .waitingForReading:
            return LocalizedString("Connected", comment: "Pebble setup title: connected, no reading yet")
        case .watchfaceNotRunning:
            return LocalizedString("Open Luped CGM on Your Watch", comment: "Pebble setup title: watchface not running")
        case .delivered:
            return LocalizedString("Your Pebble Is Set Up", comment: "Pebble setup title: done")
        }
    }

    private var detail: String {
        switch progress {
        case .bluetoothUnavailable:
            return String(format: LocalizedString("Turn on Bluetooth and allow %@ to use it in the Settings app.", comment: "Pebble setup detail: Bluetooth unavailable (1: app name)"), LupedSmartwatchManager.hostName)
        case .waitingForWatch:
            return String(format: LocalizedString("Keep the watch nearby with the Pebble app running. The watch finds %@ by itself; this can take a minute.", comment: "Pebble setup detail: waiting for the watch (1: app name)"), LupedSmartwatchManager.hostName)
        case .connecting:
            return String(format: LocalizedString("The watch found %@.", comment: "Pebble setup detail: connecting (1: app name)"), LupedSmartwatchManager.hostName)
        case .waitingForReading:
            return String(format: LocalizedString("%@ sends the next glucose reading as soon as it arrives. Tap Send Now to send the latest one.", comment: "Pebble setup detail: connected, no reading yet (1: app name)"), LupedSmartwatchManager.hostName)
        case .watchfaceNotRunning:
            return String(format: LocalizedString("The watch is connected, but Luped CGM isn't the active watchface, so it can't show readings. Select it on the watch; %@ tries again by itself.", comment: "Pebble setup detail: watchface not running (1: app name)"), LupedSmartwatchManager.hostName)
        case .delivered(let readingDate):
            return String(format: LocalizedString("The reading from %1$@ is on your watch. New readings appear as soon as %2$@ receives them.", comment: "Pebble setup detail: done (1: reading time, 2: app name)"), Self.timeFormatter.string(from: readingDate), LupedSmartwatchManager.hostName)
        }
    }
}

struct LupedStepRow: View {
    var done: Bool
    var text: String

    var body: some View {
        Label {
            Text(text)
                .foregroundColor(done ? .primary : .secondary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .secondary)
        }
        .accessibilityValue(done ? LocalizedString("Done", comment: "Accessibility value for a completed Pebble setup step") : LocalizedString("Not yet", comment: "Accessibility value for a pending Pebble setup step"))
    }
}
