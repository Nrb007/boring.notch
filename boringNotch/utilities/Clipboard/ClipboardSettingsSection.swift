// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), ClipboardSettings.swift and
// ClipboardIgnoredAppsList.swift, adapted for boring.notch: the options that apply to the notch page.
// Vorssaint's history shortcut and window layout, menu bar preview, panel toggle, Finder image paste
// and Paste as Plain Text aren't ported. The on/off switch is the utility's own in Settings → Utilities.

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsSection: View {
    @ObservedObject private var history = ClipboardHistoryService.shared
    @Default(.enabledUtilities) private var enabledUtilities
    @Default(.clipboardHistoryIncludeImagesFiles) private var includeImagesFiles
    @Default(.clipboardHistoryFilterSensitiveText) private var skipSensitive
    @Default(.clipboardHistoryLimit) private var limit
    @Default(.clipboardHistoryRetentionDays) private var retentionDays
    @Default(.clipboardAutoClearOnDelay) private var autoClearOnDelay
    @Default(.clipboardAutoClearDelay) private var autoClearDelay
    @Default(.clipboardAutoClearOnSleep) private var autoClearOnSleep
    @Default(.clipboardAutoClearOnDisplaySleep) private var autoClearOnDisplaySleep
    @Default(.clipboardAutoClearOnScreenLock) private var autoClearOnScreenLock
    @State private var canPaste = ClipboardHistoryService.canPaste
    @State private var confirmingClearRecent = false
    @State private var confirmingClearAll = false

    private var enabled: Bool { enabledUtilities.contains(.clipboard) }

    var body: some View {
        Group {
            options
                .disabled(!enabled)
            stats
        }
        .onAppear {
            history.activate()
            canPaste = ClipboardHistoryService.canPaste
            let sanitizedLimit = ClipboardHistoryLimits.sanitizedLimit(limit)
            if sanitizedLimit != limit { limit = sanitizedLimit }
            let sanitizedDays = ClipboardHistoryLimits.sanitizedRetentionDays(retentionDays)
            if sanitizedDays != retentionDays { retentionDays = sanitizedDays }
            let sanitizedDelay = ClipboardHistoryLimits.sanitizedAutoClearDelay(autoClearDelay)
            if sanitizedDelay != autoClearDelay { autoClearDelay = sanitizedDelay }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { _ in
            canPaste = ClipboardHistoryService.canPaste
        }
    }

    @ViewBuilder
    private var options: some View {
        Text("Saves what you copy so you can reuse it from the notch. Everything stays on this Mac. "
             + "Content its app marks as confidential, such as a password manager's, is never saved.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Also save copied images and files", isOn: $includeImagesFiles)
        Toggle("Skip text that looks sensitive", isOn: $skipSensitive)
        Text("May skip ordinary text that resembles passwords or tokens.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Keep up to", selection: $limit) {
            ForEach(ClipboardHistoryLimits.allowedLimits, id: \.self) { value in
                Text("\(value) items").tag(value)
            }
        }
        Picker("Keep items for", selection: $retentionDays) {
            ForEach(ClipboardHistoryLimits.allowedRetentionDays, id: \.self) { value in
                Text(ClipboardHistoryLimits.retentionLabel(days: value)).tag(value)
            }
        }
        Text("Older items are removed even below the limit. Pinned items are always kept.")
            .font(.caption)
            .foregroundStyle(.secondary)

        ClipboardIgnoredAppsList()

        autoClear
        pasting
    }

    @ViewBuilder
    private var autoClear: some View {
        HStack {
            Toggle("Clear the clipboard after", isOn: $autoClearOnDelay)
            TextField("", value: $autoClearDelay, formatter: Self.delayFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .disabled(!autoClearOnDelay)
            Text("seconds")
                .foregroundStyle(.secondary)
        }
        Toggle("Clear the clipboard when the Mac sleeps", isOn: $autoClearOnSleep)
        Toggle("Clear the clipboard when the display sleeps", isOn: $autoClearOnDisplaySleep)
        Toggle("Clear the clipboard when the screen locks", isOn: $autoClearOnScreenLock)
        Text("Clears the system clipboard only. Items already saved stay in the history.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private static let delayFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: ClipboardHistoryLimits.autoClearDelayRange.lowerBound)
        formatter.maximum = NSNumber(value: ClipboardHistoryLimits.autoClearDelayRange.upperBound)
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    @ViewBuilder
    private var pasting: some View {
        if canPaste {
            Text("Clicking an item pastes it into the app in front.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Clicking an item copies it. Allow Accessibility access to paste it into the app in front as well.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Allow…") {
                    XPCHelperClient.shared.requestAccessibilityAuthorization()
                }
                .controlSize(.small)
            }
        }
    }

    private var stats: some View {
        HStack {
            if enabled {
                Text("\(history.pinnedEntries.count) pinned · \(history.recentEntries.count) recent")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear Unpinned") { confirmingClearRecent = true }
                .disabled(history.recentEntries.isEmpty)
                .confirmationDialog("Clear unpinned items?", isPresented: $confirmingClearRecent) {
                    Button("Clear Unpinned", role: .destructive) {
                        history.clearRecent(history.recentEntriesSnapshot)
                    }
                } message: {
                    Text("Pinned items stay. This can't be undone.")
                }
            Button("Clear All") { confirmingClearAll = true }
                .confirmationDialog("Clear the whole clipboard history?", isPresented: $confirmingClearAll) {
                    Button("Clear All", role: .destructive) { history.clearAll() }
                } message: {
                    Text("Pinned items are removed too. This can't be undone.")
                }
        }
    }
}

/// The apps the clipboard history never saves from. A single quiet row until
/// there is an app in it.
private struct ClipboardIgnoredAppsList: View {
    @ObservedObject private var ignored = ClipboardIgnoredApps.shared
    @State private var isExpanded = !Defaults[.clipboardHistoryIgnoredApps].isEmpty

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(sortedApps, id: \.self) { bundleID in
                HStack(spacing: 9) {
                    if let app = ClipboardAppInfo.app(for: bundleID) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed")
                            .frame(width: 18, height: 18)
                    }
                    Text(ClipboardAppInfo.name(for: bundleID))
                        .lineLimit(1)
                        .help(bundleID)
                    Spacer(minLength: 8)
                    Button {
                        ignored.remove(bundleID)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove")
                }
            }

            Menu {
                let running = runningApps
                if !running.isEmpty {
                    Section("Running apps") {
                        ForEach(running, id: \.bundleID) { app in
                            Button(app.name) { ignored.add(app.bundleID) }
                        }
                    }
                }
                Button("Choose an App…", action: chooseApp)
            } label: {
                Label("Add an app…", systemImage: "plus")
            }
            .controlSize(.small)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Nothing you copy in these apps is saved to the history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Apps to skip")
                Spacer()
                if !ignored.apps.isEmpty {
                    Text("\(ignored.apps.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var sortedApps: [String] {
        ignored.apps.sorted {
            let byName = ClipboardAppInfo.name(for: $0).localizedCaseInsensitiveCompare(ClipboardAppInfo.name(for: $1))
            return byName == .orderedSame ? $0 < $1 : byName == .orderedAscending
        }
    }

    private var runningApps: [(bundleID: String, name: String)] {
        let listed = Set(ignored.apps)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      !listed.contains(id), seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Skip App"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        ignored.add(bundleID)
    }
}
