// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), ClipboardIgnoredApps.swift,
// adapted for boring.notch: the list lives in Defaults, and boring.notch has no history window of
// its own that could hold the keys, so the "copied in the history panel" case is gone.

import AppKit
import Defaults

/// Apps whose copies never reach the clipboard history.
///
/// The pasteboard says what was copied, never who copied it, so the app has to
/// be worked out from who had the screen at the time. The history reads the
/// pasteboard on a timer, so a copy is only noticed some time after it
/// happened, and by then the person may already be in the app they went to
/// paste into. Password windows usually close the instant something is copied.
///
/// So instead of one guess, every app that came to the front since the last
/// look is kept, and the copy is left out when any of them is on the list.
/// Leaving out one copy too many is the harmless side of being wrong here. The
/// same window names the app a copy came from, but only when a single app held
/// the front through it.
@MainActor
final class ClipboardIgnoredApps: ObservableObject {
    static let shared = ClipboardIgnoredApps()

    @Published private(set) var apps: [String] = []
    private var lookup: Set<String> = []
    /// Every app that held the front since the history last looked.
    private var candidates: Set<String> = []
    private var activationObserver: NSObjectProtocol?
    private var historyIsRunning = false
    private let ownBundleID = Bundle.main.bundleIdentifier
    private var listObserver: Task<Void, Never>?

    private init() {
        reload()
        listObserver = Task { @MainActor [weak self] in
            for await _ in Defaults.updates(.clipboardHistoryIgnoredApps, initial: false) {
                self?.reload()
            }
        }
    }

    // MARK: - The list

    func reload() {
        let raw = Defaults[.clipboardHistoryIgnoredApps]
        let sanitized = ClipboardHistoryLimits.sanitizedBundleIdentifierList(raw)
        if raw != sanitized { Defaults[.clipboardHistoryIgnoredApps] = sanitized }
        if apps != sanitized { apps = sanitized }
        lookup = Set(sanitized)
    }

    func add(_ bundleID: String) {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty, !apps.contains(bundleID) else { return }
        Defaults[.clipboardHistoryIgnoredApps] = apps + [bundleID]
        reload()
    }

    func remove(_ bundleID: String) {
        guard apps.contains(bundleID) else { return }
        Defaults[.clipboardHistoryIgnoredApps] = apps.filter { $0 != bundleID }
        reload()
    }

    // MARK: - Watching

    /// Follows the history: the observer is only installed while it runs.
    func setHistoryRunning(_ running: Bool) {
        guard historyIsRunning != running else { return }
        historyIsRunning = running
        if running {
            guard activationObserver == nil else { return }
            candidates = Self.frontmostBundleID().map { [$0] } ?? []
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                MainActor.assumeIsolated { _ = self?.candidates.insert(bundleID) }
            }
        } else if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
            candidates = []
        }
    }

    // MARK: - The question the history asks

    /// Whether a copy noticed right now could have come from a listed app, and
    /// the app it came from when only one held the front; opens the next
    /// window. Called once per pasteboard check, whether or not anything was
    /// copied, so the window never stretches past the check it belongs to. An
    /// app that names itself on the pasteboard is believed over the guess, and
    /// left out just the same when listed. A copy from another device names no app.
    func sourceSinceLastCheck(declared: String?, remote: Bool) -> (excluded: Bool, bundleID: String?) {
        guard historyIsRunning else { return (false, nil) }
        // An empty mark is the convention for a writer that does not know,
        // and nothing longer than 255 bytes is a bundle identifier.
        let trimmed = declared?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mark = trimmed.isEmpty || trimmed.utf8.count > 255 ? nil : trimmed
        let guessed = candidates.count == 1 ? candidates.first : nil
        let named: String? = mark.map { $0 == ownBundleID ? nil : $0 } ?? guessed
        let excluded = !candidates.isDisjoint(with: lookup) || mark.map { lookup.contains($0) } == true
        candidates = Self.frontmostBundleID().map { [$0] } ?? []
        return (excluded, remote ? nil : named)
    }

    private static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

/// Name and icon of an app by bundle identifier, looked up once each. A miss
/// isn't kept, so an app installed later shows up without a restart.
@MainActor
enum ClipboardAppInfo {
    struct App {
        let name: String
        let icon: NSImage
    }

    private static var cache: [String: App] = [:]

    static func app(for bundleID: String) -> App? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        let app = App(name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        if cache.count >= 256 { cache.removeAll() }
        cache[bundleID] = app
        return app
    }

    static func name(for bundleID: String) -> String {
        app(for: bundleID)?.name ?? bundleID
    }
}
