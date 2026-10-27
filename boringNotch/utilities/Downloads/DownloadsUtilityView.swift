// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), NotchDownloadsView.swift,
// adapted for boring.notch: plain SwiftUI rows sized for the notch's utility page, English
// strings, no folder chooser (it's always ~/Downloads) and no shelf button; finished files can be
// opened, revealed in Finder or dragged out. The closed-notch strip is replaced by the
// UtilityActivity that NotchDownloadService publishes.

import AppKit
import Defaults
import SwiftUI

struct DownloadsUtilityView: View {
    @ObservedObject private var downloads = NotchDownloadService.shared

    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .downloads) {
                if let transfer = downloads.currentTransfer, let fraction = transfer.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
                DownloadsIconButton(symbol: "folder", help: "Open Downloads in Finder") {
                    NSWorkspace.shared.open(downloads.folderURL)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            // In case the launch hook didn't run; does nothing if it did.
            downloads.activate()
        }
    }

    @ViewBuilder
    private var content: some View {
        if downloads.folderUnavailable {
            message(symbol: "exclamationmark.triangle", text: "Can't read your Downloads folder", tint: .orange) {
                Button("Try Again") { downloads.retry() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        } else if downloads.items.isEmpty {
            message(symbol: "arrow.down.circle", text: downloads.isMonitoring
                    ? "Nothing in Downloads yet" : "Starting…", tint: .gray) { EmptyView() }
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(downloads.items) { item in
                        DownloadRow(item: item)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func message<Accessory: View>(symbol: String, text: String, tint: Color,
                                          @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.gray)
            accessory()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DownloadRow: View {
    let item: NotchDownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.completed, let fraction = item.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .controlSize(.mini)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.completed {
                DownloadsIconButton(symbol: "arrow.up.forward.app", help: "Open") { open() }
                DownloadsIconButton(symbol: "magnifyingglass", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            } else if let fraction = item.fraction {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            } else if item.active {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if item.completed { open() } }
        .onDrag {
            item.completed ? (NSItemProvider(contentsOf: item.url) ?? NSItemProvider()) : NSItemProvider()
        }
        .help(item.name)
    }

    @ViewBuilder
    private var icon: some View {
        if item.completed {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 16))
                .foregroundStyle(.blue)
        }
    }

    private var detail: String {
        let size = item.receivedBytes.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil }
        if item.completed {
            let when = Self.relative.localizedString(for: item.date, relativeTo: Date())
            return [size, when].compactMap { $0 }.joined(separator: " · ")
        }
        let state = item.active ? "Downloading" : "Paused"
        if let size {
            return "\(state) · \(size)"
        }
        return item.fraction == nil ? "\(state) · size unknown" : state
    }

    private func open() {
        if !NSWorkspace.shared.open(item.url) { NSSound.beep() }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct DownloadsIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct DownloadsSettingsSection: View {
    @Default(.downloadsShowsInClosedNotch) private var showsInClosedNotch

    var body: some View {
        Toggle("Show download progress in the closed notch", isOn: $showsInClosedNotch)
    }
}
