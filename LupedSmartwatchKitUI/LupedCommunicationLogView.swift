//
//  LupedCommunicationLogView.swift
//  LupedSmartwatchKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKitUI
import LupedSmartwatchKit
import SwiftUI

/// The watch communication log, newest first.
struct LupedCommunicationLogView: View {
    @ObservedObject var log: LupedCommunicationLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text(LocalizedString("No watch communication yet.", comment: "Shown when the Pebble communication log is empty"))
                    .foregroundColor(.secondary)
            }
            ForEach(log.entries.reversed()) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: entry.kind))
                        .foregroundColor(color(for: entry.kind))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.timeFormatter.string(from: entry.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        // First line is the headline; the rest are aligned detail rows.
                        let lines = entry.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                        Text(lines.first.map(String.init) ?? entry.message)
                            .font(.caption.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        if lines.count > 1 {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines[1].split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                    LupedLogDetailLine(line: String(line))
                                }
                            }
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Communication Log", comment: "Title of the Pebble communication log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ShareLink(item: log.text)
                    .disabled(log.entries.isEmpty)
                Button(role: .destructive) {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(log.entries.isEmpty)
            }
        }
    }

    private func symbol(for kind: LupedCommunicationLog.Kind) -> String {
        switch kind {
        case .toWatch: return "arrow.up.right"
        case .fromWatch: return "arrow.down.left"
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func color(for kind: LupedCommunicationLog.Kind) -> Color {
        switch kind {
        case .toWatch: return .blue
        case .fromWatch: return .green
        case .info: return .secondary
        case .error: return .red
        }
    }
}

/// One detail line of a log entry. Aligned rows (`  label  value` and
/// `   0:  value  description`) keep their last column in a hanging indent, so a
/// line that wraps on a narrow screen stays in its column instead of running
/// back under the index.
struct LupedLogDetailLine: View {
    let line: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let (lead, last) = Self.columns(line) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lead)
                    Text(last).padding(.leading, 24)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(lead).fixedSize()
                    Text(last).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(line)
        }
    }

    private static let gap = try! NSRegularExpression(pattern: "\\S( {2,})(?=\\S)")

    /// Splits at the last gap of two or more spaces between columns; nil for
    /// lines without columns, such as `raw [`.
    static func columns(_ line: String) -> (String, String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = gap.matches(in: line, range: range).last,
              let cut = Range(match.range(at: 1), in: line)?.upperBound
        else {
            return nil
        }
        return (String(line[..<cut]), String(line[cut...]))
    }
}
