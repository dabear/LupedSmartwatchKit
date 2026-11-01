//
//  LupedDiagnosticsView.swift
//  LupedSmartwatchKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKitUI
import LupedSmartwatchKit
import SwiftUI

/// Watch info and the communication log, for troubleshooting.
struct LupedDiagnosticsView: View {
    let transport: LupedTransport

    var body: some View {
        List {
            LupedWatchInfoSection(transport: transport, status: transport.status)

            Section {
                NavigationLink(destination: LupedCommunicationLogView(log: transport.communicationLog)) {
                    Text(LocalizedString("Communication Log", comment: "Row opening the Pebble communication log"))
                }
            } footer: {
                Text(String(format: LocalizedString("Everything %1$@ sends to and receives from the watch since %1$@ started, newest first. The same lines are kept in %1$@'s device log for issue reports.", comment: "Footer for the Pebble log section (1: app name)"), LupedSmartwatchManager.hostName))
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Diagnostics", comment: "Title of the Pebble diagnostics screen"))
    }
}

/// Battery and counters reported by the watchface.
struct LupedWatchInfoSection: View {
    let transport: LupedTransport
    @ObservedObject var status: LupedLinkStatus

    var body: some View {
        Section {
            if let info = status.diagnostics {
                row(LocalizedString("Battery", comment: "Pebble watch info: battery"), info.battery.map { "\($0)%" })
                row(LocalizedString("Readings received", comment: "Pebble watch info: DATA messages received"), info.readingsReceived.map(String.init))
                row(LocalizedString("Refresh requests", comment: "Pebble watch info: refresh requests sent"), info.refreshRequests.map(String.init))
                row(LocalizedString("Times data went stale", comment: "Pebble watch info: stale transitions"), info.staleTransitions.map(String.init))
                row(LocalizedString("Phone disconnects", comment: "Pebble watch info: disconnects and total time"), disconnects(info))
                row(LocalizedString("Counting since", comment: "Pebble watch info: diagnostics window start"), info.countingSince.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) })
                row(LocalizedString("Updated", comment: "Pebble watch info: time the snapshot arrived"), updatedText(info.receivedAt))
            } else {
                Text(LocalizedString("No watch info yet.", comment: "Shown before the Pebble watch has sent its first diagnostics report"))
                    .foregroundColor(.secondary)
            }
            if let note = status.watchInfoNote {
                Text(note)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            Button(LocalizedString("Refresh Watch Info", comment: "Button requesting Pebble watch diagnostics")) {
                transport.requestDiagnostics()
            }
            .disabled(status.link != .open)
        } header: {
            Text(LocalizedString("Watch", comment: "Header for the Pebble watch info section"))
        } footer: {
            Text(LocalizedString("The watch reports this about once an hour, covering at most the last 48 hours. Refresh Watch Info asks now; the reply can take up to 30 seconds.", comment: "Footer for the Pebble watch info section"))
        }
    }

    private func updatedText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            : DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label, value: value)
        }
    }

    private func disconnects(_ info: LupedWatchDiagnostics) -> String? {
        guard let count = info.phoneDisconnects else { return nil }
        let seconds = info.phoneDisconnectedSeconds ?? 0
        return String(format: LocalizedString("%1$d (%2$d min total)", comment: "Pebble watch info: disconnect count and total minutes"), count, seconds / 60)
    }
}
