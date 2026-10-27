// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), ClipboardHistoryService.swift,
// adapted for boring.notch: polling, capture and privacy checks, the entry operations, the local
// store and the image store are Vorssaint's. Its history window, global shortcut, batch selection,
// menu bar preview, image editor hand-off and legacy UserDefaults migration aren't ported; the
// history is shown by the notch's Clipboard utility, and it only records while that utility is on.

import AppKit
import Carbon.HIToolbox
import Combine
import CryptoKit
import Defaults
import ImageIO

/// Opt-in clipboard history. It records text and, optionally, copied images
/// and files, and keeps a small local history. Confidential pasteboard
/// content is excluded; guessing sensitive text is a separate opt-in.
@MainActor
final class ClipboardHistoryService: ObservableObject {
    static let shared = ClipboardHistoryService()

    @Published private(set) var entries: [ClipboardHistoryEntry] = [] {
        didSet {
            entriesStamp &+= 1
            searchCache.prune(keeping: entries)
            // The result array holds full entry texts, so a cleared history's
            // content must not linger in it until the next search.
            filterCache = nil
            if let current = latestPasteboardEntry {
                latestPasteboardEntry = entries.first { $0.id == current.id && $0.text == current.text }
            }
        }
    }
    @Published private(set) var isRunning = false
    /// Whether the history file could be read; a failed read never lets a
    /// later save overwrite it.
    @Published private(set) var loadFailed = false

    /// The entry most recently put on the pasteboard, from a copy or a reuse.
    /// Only used to recognize a dictation app putting it back.
    private var latestPasteboardEntry: ClipboardHistoryEntry?
    private var timer: Timer?
    /// Entries age out with nothing new copied, so the retention window is
    /// also checked on its own clock.
    private var retentionTimer: Timer?
    private var lastChangeCount = 0
    /// Only an explicitly temporary write can make the previous clipboard's
    /// return silent.
    private var pendingRestore: (previous: ClipboardHistoryEntry, at: Date)?
    /// The poll reads the pasteboard off the main thread: while a password
    /// prompt is up the pasteboard server can take seconds to answer.
    private var captureState = ClipboardHistoryCaptureState()
    /// At most one history write queued or executing.
    private var copyInFlight = false
    private static let pasteboardTimeout: TimeInterval = 5
    private var hasLoaded = false
    private var activated = false
    private var observers: [Task<Void, Never>] = []

    /// Writes coalesce per mutation cycle; the JSON encode and the disk write
    /// stay off the main thread, serialized so they land in mutation order.
    private nonisolated static let persistQueue = DispatchQueue(label: "boringNotch.clipboard.persist", qos: .utility)
    private var persistScheduled = false
    private var persistenceGeneration = 0

    private var entriesStamp = 0
    private var filterCache: (query: String, stamp: Int, result: [ClipboardHistoryEntry])?
    private var searchCache = ClipboardHistorySearchCache()

    private init() {}

    // MARK: - Lifecycle

    /// Starts following the utility's switch. Safe to call more than once;
    /// called at launch and again whenever the page or its settings show.
    func activate() {
        guard !activated else { return }
        activated = true
        observers.append(Task { @MainActor [weak self] in
            for await _ in Defaults.updates(.enabledUtilities) {
                self?.syncWithPreferences()
            }
        })
        observers.append(Task { @MainActor [weak self] in
            for await _ in Defaults.updates([.clipboardHistoryLimit, .clipboardHistoryRetentionDays], initial: false) {
                self?.trimToLimit()
            }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func applicationWillTerminate() {
        flushBeforeTermination()
    }

    var isEnabled: Bool { UtilityRegistry.isEnabled(.clipboard) }

    func syncWithPreferences() {
        if isEnabled {
            load()
            start()
        } else {
            stop()
            unload()
        }
        ClipboardAutoClearService.shared.syncWithPreferences()
    }

    /// Skips capturing pasteboard changes up to the given change count.
    func ignoreNextChange(upTo changeCount: Int) {
        lastChangeCount = max(lastChangeCount, changeCount)
    }

    /// Called once the auto clear actually emptied the pasteboard.
    func pasteboardWasCleared() {
        latestPasteboardEntry = nil
    }

    // MARK: - Using entries

    func copy(_ entry: ClipboardHistoryEntry, completion: @escaping (Bool) -> Void) {
        guard !copyInFlight, let write = Self.plannedWrite(for: entry) else {
            completion(false)
            return
        }
        copyInFlight = true
        ClipboardPasteboardAccess.shared.async(timeout: Self.pasteboardTimeout, Self.writeWork(write), then: { [weak self] result in
            let copied = result?.succeeded == true
            if copied {
                self?.touch(entry.id)
                self?.latestPasteboardEntry = entry
            }
            completion(copied)
        }, didFinish: { [weak self] result in
            guard let self else { return }
            self.copyInFlight = false
            // Consume our own mutation even if result delivery already expired.
            if let result { self.lastChangeCount = max(self.lastChangeCount, result.changeCount) }
        })
    }

    private nonisolated static func writeWork(_ write: ClipboardHistoryWrite)
        -> (() -> Bool) -> ClipboardHistoryWriteResult? {
        { isExpired in write.write(to: NSPasteboard.general, isExpired: isExpired) }
    }

    /// Whether a click may type ⌘V into the app in front. The notch already
    /// asks for Accessibility for its HUD; without it a click only copies.
    static var canPaste: Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    /// Copies the entry, then pastes it into `target` once the write has
    /// landed: pasting before would paste whatever was there before. A stale
    /// entry leaves the clipboard untouched and pastes nothing at all.
    func paste(_ entry: ClipboardHistoryEntry, into target: NSRunningApplication?,
               completion: @escaping (Bool) -> Void) {
        copy(entry) { copied in
            completion(copied)
            guard copied else {
                NSSound.beep()
                return
            }
            guard let target, !target.isTerminated, Self.canPaste else { return }
            target.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Self.postPasteShortcut()
            }
        }
    }

    /// The app a click pastes into: the one in front, unless that's this app
    /// itself or one without a Dock icon, where a click only copies.
    static func pasteTarget() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular,
              !app.isTerminated else { return nil }
        return app
    }

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// What to put on the pasteboard, or nil when the content is gone (image
    /// purged from the store, files deleted or on an ejected volume) and the
    /// copy must abort with the user's clipboard intact.
    private static func plannedWrite(for entry: ClipboardHistoryEntry) -> ClipboardHistoryWrite? {
        switch entry.kind {
        case .text:
            return .text(entry.text)
        case .image:
            guard let name = entry.imageFile, let data = ClipboardImageStore.imageData(named: name) else { return nil }
            // TIFF alongside PNG: some paste targets only take TIFF.
            return .image(png: data, tiff: NSBitmapImageRep(data: data)?.tiffRepresentation)
        case .files:
            let urls = entry.filePaths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return nil }
            return .files(urls as [NSURL])
        }
    }

    /// A reused recent entry moves to the top of the recent ones, the way a
    /// fresh copy of the same content does. A pinned entry keeps its place.
    private func touch(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        var entry = updated.remove(at: index)
        entry.copiedAt = Date()
        if entry.isPinned {
            updated.insert(entry, at: index)
        } else {
            updated.insert(entry, at: updated.firstIndex { !$0.isPinned } ?? updated.endIndex)
        }
        entries = updated
        save()
    }

    func togglePin(_ entry: ClipboardHistoryEntry) {
        guard hasLoaded, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let previousEntries = entries
        var updated = entries
        var changed = updated.remove(at: index)
        let pinning = !changed.isPinned
        if changed.isPinned {
            changed = ClipboardHistoryEditing.unpinned(changed)
            updated.insert(changed, at: updated.firstIndex { !$0.isPinned } ?? updated.endIndex)
        } else {
            changed.pinnedAt = Date()
            updated.insert(changed, at: 0)
        }
        entries = updated.filter(\.isPinned) + updated.filter { !$0.isPinned }
        trimToLimit(saving: false)
        // The saved file drops whatever it can't hold, pinned items included,
        // so a pin that would push them past it is refused instead.
        guard entries.contains(where: { $0.id == entry.id }),
              ClipboardHistoryEditing.preservesPinnedEntries(from: previousEntries, in: entries),
              !pinning || ClipboardHistoryEditing.pinnedEntriesFit(entries) else {
            entries = previousEntries
            NSSound.beep()
            return
        }
        save()
    }

    func remove(_ entry: ClipboardHistoryEntry) {
        guard hasLoaded else { return }
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Deletes only the unpinned entries counted when the clear was asked
    /// for, as they were then, so a copy that lands meanwhile survives.
    func clearRecent(_ confirmed: [UUID: Date]) {
        guard hasLoaded else { return }
        entries.removeAll { !$0.isPinned && confirmed[$0.id] == $0.copiedAt }
        save()
    }

    /// Everything, pinned included, from memory and disk. Works with the
    /// utility off as well, when nothing is loaded.
    func clearAll() {
        entries = []
        latestPasteboardEntry = nil
        pendingRestore = nil
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        ClipboardImageStore.clearThumbnails()
        Self.persistQueue.async {
            Self.removeStore()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = ClipboardHistoryService.shared
                    // A copy that landed meanwhile is saved again.
                    if service.persistenceGeneration != generation { service.save() }
                }
            }
        }
    }

    private nonisolated static func removeStore() {
        if let url = storeURL { try? FileManager.default.removeItem(at: url) }
        if let directory = ClipboardImageStore.directory { try? FileManager.default.removeItem(at: directory) }
    }

    var pinnedEntries: [ClipboardHistoryEntry] { entries.filter(\.isPinned) }
    var recentEntries: [ClipboardHistoryEntry] { entries.filter { !$0.isPinned } }

    /// What a "Clear unpinned" confirmation counts.
    var recentEntriesSnapshot: [UUID: Date] {
        Dictionary(recentEntries.map { ($0.id, $0.copiedAt) }, uniquingKeysWith: { first, _ in first })
    }

    /// One ranking pass over a large history of long texts costs real time,
    /// and SwiftUI asks for the list many times per render, so the last
    /// result is reused until the query or the history changes.
    func filteredEntries(matching query: String) -> [ClipboardHistoryEntry] {
        if let cache = filterCache, cache.query == query, cache.stamp == entriesStamp {
            return cache.result
        }
        let result: [ClipboardHistoryEntry]
        if entries.isEmpty || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = entries
        } else {
            let candidates = searchCache.candidates(for: entries, stamp: entriesStamp)
            result = ClipboardHistorySearch.rankedIndexes(candidates: candidates, matching: query)
                .compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        }
        filterCache = (query, entriesStamp, result)
        return result
    }

    // MARK: - Polling

    private func start() {
        guard !loadFailed else { return }
        guard timer == nil else {
            isRunning = true
            return
        }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureIfChanged() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let retentionTimer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimToLimit() }
        }
        retentionTimer.tolerance = 600
        RunLoop.main.add(retentionTimer, forMode: .common)
        self.retentionTimer = retentionTimer
        isRunning = true
        ClipboardIgnoredApps.shared.setHistoryRunning(true)
        captureState.restart()
        captureIfChanged()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        isRunning = false
        ClipboardIgnoredApps.shared.setHistoryRunning(false)
        captureState.invalidate()
        pendingRestore = nil
        latestPasteboardEntry = nil
    }

    /// What the background pasteboard read hands back to the main thread.
    fileprivate enum CapturedContent {
        case transient
        case files([String])
        case image(CapturedImage)
        case text(String)
    }

    fileprivate struct CapturedImage {
        let data: Data
        let width: Int
        let height: Int
    }

    fileprivate struct PasteboardRead {
        let changeCount: Int
        let content: CapturedContent?
        let declaredSource: String?
        let remote: Bool
    }

    private nonisolated static func readWork(baseline: Bool, since: Int, includeImagesFiles: Bool)
        -> (() -> Bool) -> PasteboardRead? {
        { isExpired in
            let pasteboard = NSPasteboard.general
            let changeCount = pasteboard.changeCount
            guard !isExpired() else { return nil }
            // A fresh baseline reads the content too, to match it against the
            // saved entries; otherwise only a changed count is read.
            let content = (baseline || changeCount != since) ? readPasteboard(includeImagesFiles: includeImagesFiles) : nil
            return PasteboardRead(changeCount: changeCount,
                                  content: content,
                                  declaredSource: content == nil ? nil : pasteboard.string(forType: .clipboardHistorySource),
                                  remote: content != nil && pasteboard.types?.contains(.clipboardHistoryRemote) == true)
        }
    }

    private func captureIfChanged() {
        guard isRunning, let generation = captureState.begin() else { return }
        // On start, establish a fresh baseline before capturing.
        let baseline = captureState.needsBaseline
        let sinceChangeCount = lastChangeCount
        let work = Self.readWork(baseline: baseline, since: sinceChangeCount,
                                 includeImagesFiles: Defaults[.clipboardHistoryIncludeImagesFiles])
        ClipboardPasteboardAccess.shared.async(timeout: Self.pasteboardTimeout, work, then: { [weak self] result in
            guard let self else { return }
            guard let result else {
                // A deadline invalidates immediately, not at the next poll.
                self.captureState.expire(generation)
                return
            }
            guard self.isRunning, self.captureState.accepts(generation) else { return }
            self.handle(result, baseline: baseline, since: sinceChangeCount)
        }, didFinish: { [weak self] _ in
            self?.captureState.finish()
        })
    }

    private func handle(_ result: PasteboardRead, baseline: Bool, since sinceChangeCount: Int) {
        if baseline {
            lastChangeCount = max(lastChangeCount, result.changeCount)
            captureState.didBaseline()
            latestPasteboardEntry = result.content.flatMap(matchingEntry)
            return
        }
        // Exclusion covers the whole time since the previous accepted check.
        let source = ClipboardIgnoredApps.shared.sourceSinceLastCheck(declared: result.declaredSource,
                                                                       remote: result.remote)
        guard let accepted = ClipboardHistoryChangeCount.accepted(read: result.changeCount, since: sinceChangeCount,
                                                                  last: lastChangeCount) else { return }
        lastChangeCount = accepted
        // A restarted pasteboard server cannot finish an old restore.
        let advanced = result.changeCount > sinceChangeCount
        let previous = advanced ? latestPasteboardEntry : nil
        let pending = advanced ? pendingRestore : nil
        pendingRestore = nil
        latestPasteboardEntry = nil
        if case .transient? = result.content {
            // Keep the first deadline instead of extending it indefinitely.
            pendingRestore = previous.map { (previous: $0, at: Date()) } ?? pending
            return
        }
        guard !source.excluded, let content = result.content else { return }
        if let pending, let restored = matchingEntry(for: content), restored.id == pending.previous.id,
           ClipboardHistoryPasteRestore.isWithinWindow(capturedAt: pending.at, now: Date()) {
            // A restored entry still faces today's capture preferences.
            if case .text(let raw) = content {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= ClipboardHistoryEditing.maxCharacters,
                      !(Defaults[.clipboardHistoryFilterSensitiveText]
                        && ClipboardHistorySensitiveText.looksSensitive(text)) else { return }
            }
            touch(restored.id)
            latestPasteboardEntry = entries.first { $0.id == restored.id }
            return
        }
        switch content {
        case .transient: break
        case .files(let paths): promoteFiles(paths, source: source.bundleID)
        case .image(let image): promoteImage(image, source: source.bundleID)
        case .text(let text): promote(text, source: source.bundleID)
        }
    }

    /// The saved entry, if any, whose content is exactly what was just read.
    private func matchingEntry(for content: CapturedContent) -> ClipboardHistoryEntry? {
        switch content {
        case .transient: return nil
        case .text(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return entries.first { $0.kind == .text && $0.text == text }
        case .image(let image):
            let hash = Self.sha256Hex(image.data)
            return entries.first { $0.kind == .image && $0.imageHash == hash }
        case .files(let paths):
            return entries.first { $0.kind == .files && $0.filePaths == paths }
        }
    }

    /// Runs on the pasteboard lane: everything here may block behind the
    /// pasteboard server, which is why it stays off the main thread.
    private nonisolated static func readPasteboard(includeImagesFiles: Bool) -> CapturedContent? {
        let pasteboard = NSPasteboard.general
        // An app that marks its content as a secret (a password manager
        // handing one over) is taken at its word: the content is never read.
        // Content its app is about to take back (a dictation app typing) is
        // no copy either.
        let types = (pasteboard.types ?? []).map(\.rawValue)
        if ClipboardHistorySensitiveText.isConcealed(types) { return nil }
        if ClipboardHistorySensitiveText.isTransient(types) { return .transient }
        // Files first: a Finder copy also carries name strings, and a browser
        // image copy also carries URL text.
        if includeImagesFiles {
            if let paths = copiedFilePaths(from: pasteboard) { return .files(paths) }
            if let image = copiedPNGImage(from: pasteboard) { return .image(image) }
        }
        guard let text = ClipboardHistoryPasteboardText.preferredText(
            webURLString: webURLString(from: pasteboard),
            plainText: pasteboard.string(forType: .string)
        ) else { return nil }
        return .text(text)
    }

    private nonisolated static let maxCopiedFiles = 100
    private nonisolated static let maxImageBytes = 16 * 1024 * 1024
    private nonisolated static let maxRawImageBytes = 64 * 1024 * 1024

    private nonisolated static func copiedFilePaths(from pasteboard: NSPasteboard) -> [String]? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, urls.count <= maxCopiedFiles else { return nil }
        return urls.map { $0.standardizedFileURL.path }
    }

    private nonisolated static func copiedPNGImage(from pasteboard: NSPasteboard) -> CapturedImage? {
        let png = pasteboard.data(forType: .png)
        guard let source = png ?? pasteboard.data(forType: .tiff),
              source.count <= (png == nil ? maxRawImageBytes : maxImageBytes),
              let rep = NSBitmapImageRep(data: source),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let data: Data
        if let png {
            data = png
        } else if let converted = rep.representation(using: .png, properties: [:]) {
            data = converted
        } else {
            return nil
        }
        guard data.count <= maxImageBytes else { return nil }
        return CapturedImage(data: data, width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private nonisolated static func webURLString(from pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        if let url = urls?.first(where: isWebURL) { return url.absoluteString }
        for type in [NSPasteboard.PasteboardType("public.url"), NSPasteboard.PasteboardType("NSURLPboardType")] {
            if let value = pasteboard.string(forType: type), let url = URL(string: value), isWebURL(url) {
                return url.absoluteString
            }
        }
        return nil
    }

    private nonisolated static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Recording

    private func promoteImage(_ image: CapturedImage, source: String?) {
        let hash = Self.sha256Hex(image.data)
        if let existing = entries.first(where: { $0.kind == .image && $0.imageHash == hash }) {
            entries.removeAll { $0.id == existing.id }
            insertPromoted(ClipboardHistoryEntry(id: existing.id, text: "", copiedAt: Date(), pinnedAt: existing.pinnedAt,
                                                 kind: .image, imageFile: existing.imageFile, imageHash: hash,
                                                 imageWidth: existing.imageWidth, imageHeight: existing.imageHeight),
                           source: source)
        } else {
            guard let name = ClipboardImageStore.store(image.data) else { return }
            insertPromoted(ClipboardHistoryEntry(text: "", kind: .image, imageFile: name, imageHash: hash,
                                                 imageWidth: image.width, imageHeight: image.height),
                           source: source)
        }
        trimToLimit(saving: false)
        save()
    }

    private func promoteFiles(_ paths: [String], source: String?) {
        let existing = entries.first { $0.kind == .files && $0.filePaths == paths }
        entries.removeAll { $0.kind == .files && $0.filePaths == paths }
        if let existing {
            insertPromoted(ClipboardHistoryEntry(id: existing.id, text: "", copiedAt: Date(), pinnedAt: existing.pinnedAt,
                                                 kind: .files, filePaths: paths),
                           source: source)
        } else {
            insertPromoted(ClipboardHistoryEntry(text: "", kind: .files, filePaths: paths), source: source)
        }
        trimToLimit(saving: false)
        save()
    }

    private func promote(_ raw: String, source: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= ClipboardHistoryEditing.maxCharacters else { return }
        if Defaults[.clipboardHistoryFilterSensitiveText], ClipboardHistorySensitiveText.looksSensitive(text) {
            return
        }
        let existing = entries.first { $0.kind == .text && $0.text == text }
        entries.removeAll { $0.kind == .text && $0.text == text }
        if let existing {
            insertPromoted(ClipboardHistoryEntry(id: existing.id, text: text, copiedAt: Date(), pinnedAt: existing.pinnedAt),
                           source: source)
        } else {
            insertPromoted(ClipboardHistoryEntry(text: text), source: source)
        }
        trimToLimit(saving: false)
        save()
    }

    /// A copy taken again takes the app it came from this time.
    private func insertPromoted(_ entry: ClipboardHistoryEntry, source: String?) {
        var entry = entry
        entry.sourceBundleID = source
        var updated = entries
        if entry.isPinned {
            updated.insert(entry, at: 0)
        } else {
            updated.insert(entry, at: updated.firstIndex { !$0.isPinned } ?? updated.endIndex)
        }
        entries = updated.filter(\.isPinned) + updated.filter { !$0.isPinned }
        latestPasteboardEntry = entry
    }

    func trimToLimit() {
        trimToLimit(saving: true)
    }

    private func trimToLimit(saving: Bool) {
        guard hasLoaded else { return }
        let trimmed = ClipboardHistoryEditing.retainedEntries(
            entries,
            recentLimit: ClipboardHistoryLimits.sanitizedLimit(Defaults[.clipboardHistoryLimit]),
            retentionDays: ClipboardHistoryLimits.sanitizedRetentionDays(Defaults[.clipboardHistoryRetentionDays]))
        if trimmed != entries {
            entries = trimmed
            if saving { save() }
        }
    }

    // MARK: - Store

    private nonisolated static var storeURL: URL? {
        ClipboardFileStore.directory?.appendingPathComponent("ClipboardHistory.json")
    }

    private nonisolated static func storedHistoryData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              ClipboardHistoryEditing.canLoadEncodedHistory(byteCount: values.fileSize) else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Reads the history the first time recording starts or the page shows.
    func load() {
        guard !hasLoaded else { return }
        loadFailed = false
        guard let url = Self.storeURL else {
            loadFailed = true
            return
        }
        var decoded: [ClipboardHistoryEntry] = []
        do {
            if let data = try Self.storedHistoryData(at: url) {
                decoded = try JSONDecoder().decode([ClipboardHistoryEntry].self, from: data)
            }
        } catch {
            // Never overwrite a history this version could not read.
            loadFailed = true
            return
        }
        hasLoaded = true
        entries = decoded.filter(\.isPinned) + decoded.filter { !$0.isPinned }
        trimToLimit()
        // Sweep image files that lost their entry (crash between write and save).
        let keep = Set(entries.compactMap(\.imageFile))
        Self.persistQueue.async { ClipboardImageStore.cleanup(keeping: keep) }
    }

    /// Turning the utility off keeps the history on disk but out of memory.
    private func unload() {
        guard hasLoaded else { return }
        flushBeforeTermination()
        hasLoaded = false
        entries = []
        searchCache.clear()
        ClipboardImageStore.clearThumbnails()
    }

    /// Coalesces the saves of one mutation cycle into a single persist.
    private func save() {
        guard hasLoaded else { return }
        persistenceGeneration &+= 1
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let service = ClipboardHistoryService.shared
                guard service.persistScheduled else { return }
                service.persistScheduled = false
                service.persist()
            }
        }
    }

    private func persist() {
        let snapshot = entries
        let generation = persistenceGeneration
        Self.persistQueue.async {
            guard let retained = Self.write(snapshot) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = ClipboardHistoryService.shared
                    // What didn't fit the file is dropped from memory too.
                    if service.persistenceGeneration == generation, retained != snapshot {
                        service.entries = retained
                    }
                    let keep = Set(service.entries.compactMap(\.imageFile))
                    Self.persistQueue.async { ClipboardImageStore.cleanup(keeping: keep) }
                }
            }
        }
    }

    /// Encodes and writes on the persist queue; the entries that fit, or nil
    /// when nothing was written.
    private nonisolated static func write(_ snapshot: [ClipboardHistoryEntry]) -> [ClipboardHistoryEntry]? {
        guard let url = storeURL, let encoded = ClipboardHistoryEditing.encodedHistory(snapshot) else { return nil }
        ClipboardFileStore.createDirectory(at: url.deletingLastPathComponent())
        guard ClipboardFileStore.write(encoded.data, to: url) else { return nil }
        return encoded.entries
    }

    /// Runs any deferred persist now and waits for it, so the last change of
    /// a session (often a privacy-minded Clear) is on disk before quitting.
    func flushBeforeTermination() {
        if persistScheduled {
            persistScheduled = false
            persist()
        }
        Self.persistQueue.sync {}
    }
}

/// File-backed storage for copied images: PNGs named by UUID in the
/// clipboard folder, swept against the live entry list after every save.
enum ClipboardImageStore {
    /// Decoded thumbnails retained between page uses; NSCache is thread-safe.
    private nonisolated(unsafe) static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static var directory: URL? {
        ClipboardFileStore.directory?.appendingPathComponent("Images", isDirectory: true)
    }

    static func store(_ data: Data) -> String? {
        guard let directory, ClipboardFileStore.createDirectory(at: directory) else { return nil }
        let name = UUID().uuidString + ".png"
        guard ClipboardFileStore.write(data, to: directory.appendingPathComponent(name)) else { return nil }
        return name
    }

    static func imageData(named name: String) -> Data? {
        guard let directory, (name as NSString).lastPathComponent == name else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// Where a row's thumbnail comes from; also its identity.
    enum ThumbnailSource: Hashable, Sendable {
        case stored(name: String)
        case file(path: String)

        fileprivate var key: NSString {
            switch self {
            case .stored(let name): return name as NSString
            case .file(let path): return "file:\(path)" as NSString
            }
        }
    }

    static func cachedThumbnail(_ source: ThumbnailSource) -> NSImage? {
        thumbnails.object(forKey: source.key)
    }

    /// Downsamples off the main thread: a screenshot PNG takes tens of
    /// milliseconds to decode, and rows that decoded while drawing would
    /// freeze the search field.
    static func loadThumbnail(_ source: ThumbnailSource, maxPixelSize: Int = 240) async -> NSImage? {
        if let cached = cachedThumbnail(source) { return cached }
        let url: URL?
        switch source {
        case .stored(let name): url = directory?.appendingPathComponent(name)
        case .file(let path): url = ClipboardHistoryImageSupport.isImageFilePath(path) ? URL(fileURLWithPath: path) : nil
        }
        guard let url else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { () -> ThumbnailBox? in
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else { return nil }
            return ThumbnailBox(image: cgImage)
        }.value
        guard let cgImage = decoded?.image, !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        thumbnails.setObject(image, forKey: source.key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    private struct ThumbnailBox: @unchecked Sendable {
        let image: CGImage
    }

    static func clearThumbnails() {
        thumbnails.removeAllObjects()
    }

    /// Removes stored PNGs no entry refers to any more.
    nonisolated static func cleanup(keeping names: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
            thumbnails.removeObject(forKey: file.lastPathComponent as NSString)
        }
    }
}

/// Lets the Objective-C launch hook (ClipboardLaunchHook.m) start the history
/// once the app has finished launching, so it records from launch and not
/// only once the page has been opened.
@objc(BNClipboardHistoryLaunch)
final class ClipboardHistoryLaunch: NSObject {
    @objc static func start() {
        MainActor.assumeIsolated {
            ClipboardHistoryService.shared.activate()
        }
    }
}
