// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), NotchDownloadService.swift,
// adapted for boring.notch: it always watches ~/Downloads (the app holds the downloads
// entitlement), so Vorssaint's folder chooser, security-scoped bookmarks and island plumbing are
// gone. It runs while the Downloads utility is switched on and reports the transfer in progress
// to the closed notch through UtilityActivityCenter.

import AppKit
import Combine
import Darwin
import Defaults
import SwiftUI

/// All state lives on the main thread; file reads and progress bookkeeping run on `queue`.
final class NotchDownloadService: ObservableObject {
    static let shared = NotchDownloadService()

    /// Progress may unpublish on any queue. Only this main-actor boundary
    /// holds the weak owner; native callbacks carry a Sendable reference.
    @MainActor private final class ProgressCallbacks {
        weak var owner: NotchDownloadService?
        let generation: UUID

        init(owner: NotchDownloadService, generation: UUID) {
            self.owner = owner
            self.generation = generation
        }

        func published(_ progress: Progress, id: UUID) {
            guard let owner, owner.generation == generation else { return }
            owner.progressObserver?.add(progress, id: id)
        }

        func unpublished(_ id: UUID) {
            guard let owner, owner.generation == generation else { return }
            owner.progressObserver?.remove(id)
        }
    }

    @Published private(set) var items: [NotchDownloadItem] = []
    @Published private(set) var isMonitoring = false
    @Published private(set) var folderUnavailable = false

    let folderURL = NotchDownloadSupport.downloadsFolder

    private var folder: URL?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources: [URL: DispatchSourceFileSystemObject] = [:]
    private var subscriber: Any?
    private var announcements: NSObjectProtocol?
    private var progressObserver: NotchDownloadProgressObserver?
    private var progressItems: [NotchDownloadItem] = []
    private var folderItems: [NotchDownloadItem] = []
    private var partials: [URL: NotchPartialDownload] = [:]
    private var finished: [NotchDownloadItem] = []
    private var expiry: DispatchWorkItem?
    private var inactivityExpiry: DispatchWorkItem?
    private var scanWork: DispatchWorkItem?
    private var arrivalNotice: DispatchWorkItem?
    private var showsArrival = false
    private var generation = UUID()
    private var scanning = false
    private var rescan = false
    private var preferenceObservers: [Task<Void, Never>] = []
    private let queue = DispatchQueue(label: "boringNotch.utilities.downloads", qos: .utility)

    private init() {}

    /// Starts following the utility's switch. Safe to call any number of times; the app calls it
    /// at launch, and the page calls it too.
    func activate() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard preferenceObservers.isEmpty else { return }
        preferenceObservers = [
            Task { @MainActor [weak self] in
                for await _ in Defaults.updates(.enabledUtilities) {
                    self?.syncWithPreferences()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in Defaults.updates(.downloadsShowsInClosedNotch, initial: false) {
                    self?.updateActivity()
                }
            },
        ]
    }

    func syncWithPreferences() {
        guard UtilityRegistry.isEnabled(.downloads) else { stop(); folderUnavailable = false; return }
        guard folder == nil else { return }
        start(folderURL)
    }

    /// Tries the folder again after it went missing or couldn't be read.
    func retry() {
        stop()
        syncWithPreferences()
    }

    func stop() {
        generation = UUID()
        scanWork?.cancel(); scanWork = nil
        expiry?.cancel(); expiry = nil
        inactivityExpiry?.cancel(); inactivityExpiry = nil
        arrivalNotice?.cancel(); arrivalNotice = nil
        showsArrival = false
        directorySource?.cancel(); directorySource = nil
        fileSources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        progressObserver?.stop(); progressObserver = nil
        progressItems = []
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        if let announcements { DistributedNotificationCenter.default().removeObserver(announcements) }
        announcements = nil
        folder = nil
        folderItems.removeAll()
        partials.removeAll()
        finished.removeAll()
        if !items.isEmpty { items = [] }
        if isMonitoring { isMonitoring = false }
        scanning = false
        rescan = false
        updateActivity()
    }

    private func start(_ url: URL) {
        guard url.isFileURL, let source = watch(url, directory: true) else {
            folderUnavailable = true
            return
        }
        folder = url.standardizedFileURL
        folderUnavailable = false
        isMonitoring = true
        directorySource = source
        let requested = generation
        progressObserver = NotchDownloadProgressObserver(folder: url.standardizedFileURL, queue: queue) { [weak self] items, completed in
            DispatchQueue.main.async {
                guard let self, self.generation == requested else { return }
                self.progressItems = items
                completed.forEach(self.recordCompletion)
                self.refreshItems()
            }
        }
        let callbacks = MainActor.assumeIsolated { ProgressCallbacks(owner: self, generation: generation) }
        // Browsers publish an NSProgress for each file they download; this follows the ones
        // headed for ~/Downloads.
        subscriber = Progress.addSubscriber(forFileURL: url) { published in
            let id = UUID()
            DispatchQueue.main.async {
                callbacks.published(published, id: id)
            }
            return {
                DispatchQueue.main.async {
                    callbacks.unpublished(id)
                }
            }
        }
        announcements = DistributedNotificationCenter.default().addObserver(
            forName: NotchDownloadSupport.finishedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.generation == requested, let folder = self.folder,
                  let path = note.object as? String else { return }
            self.queue.async { [weak self] in
                let item = NotchDownloadSupport.announcedItem(atPath: path, folder: folder)
                DispatchQueue.main.async {
                    guard let self, self.generation == requested, let item else { return }
                    self.recordCompletion(item)
                    self.refreshItems()
                }
            }
        }
        scheduleScan()
    }

    private func watch(_ url: URL, directory: Bool) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if directory, let source = self.directorySource,
               !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                self.stop()
                self.folderUnavailable = true
            } else { self.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleScan() {
        guard folder != nil, scanWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.scanWork = nil
            self?.scan()
        }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scan() {
        guard let folder else { return }
        guard !scanning else { rescan = true; return }
        scanning = true
        let id = generation
        let previous = partials
        queue.async { [weak self] in
            let current = NotchDownloadSupport.scanFolder(folder)
            let completed = previous.values.compactMap { old -> NotchDownloadItem? in
                guard current?.partials[old.url] == nil,
                      !FileManager.default.fileExists(atPath: old.url.path),
                      let values = try? old.expectedURL.resourceValues(forKeys: NotchDownloadSupport.keys),
                      values.isRegularFile == true,
                      NotchDownloadSupport.didFinish(old, at: old.expectedURL,
                          resourceID: NotchDownloadSupport.fileIdentity(at: old.expectedURL)) else { return nil }
                return NotchDownloadItem(id: old.expectedURL.path, url: old.expectedURL,
                    name: old.expectedURL.lastPathComponent, receivedBytes: Int64(values.fileSize ?? 0),
                    fraction: 1, completed: true, active: false, date: Date())
            }
            DispatchQueue.main.async {
                guard let self, self.generation == id else { return }
                self.scanning = false
                guard let current else {
                    self.stop(); self.folderUnavailable = true; return
                }
                self.partials = current.partials
                self.folderItems = current.files
                let watched = Set(current.partials.values.flatMap { [$0.url] + [$0.contentURL].compactMap { $0 } })
                let removed = Set(self.fileSources.keys).subtracting(watched)
                for url in removed { self.fileSources.removeValue(forKey: url)?.cancel() }
                for url in watched where self.fileSources[url] == nil {
                    self.fileSources[url] = self.watch(url, directory: false)
                }
                completed.forEach(self.recordCompletion)
                self.progressObserver?.requestRefresh()
                self.refreshItems()
                if self.rescan { self.rescan = false; self.scheduleScan() }
            }
        }
    }

    private func recordCompletion(_ item: NotchDownloadItem) {
        guard !finished.contains(where: { $0.id == item.id }) else { return }
        finished.insert(item, at: 0)
        finished = Array(finished.prefix(5))
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finished.removeAll(); self?.expiry = nil; self?.refreshItems()
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        showArrival()
    }

    /// A finished download shows a short "Done" in the closed notch.
    private func showArrival() {
        arrivalNotice?.cancel()
        showsArrival = true
        let work = DispatchWorkItem { [weak self] in
            self?.showsArrival = false
            self?.arrivalNotice = nil
            self?.updateActivity()
        }
        arrivalNotice = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        updateActivity()
    }

    private func refreshItems() {
        guard folder != nil else { return }
        inactivityExpiry?.cancel(); inactivityExpiry = nil
        if let next = partials.values.map({ $0.modified.addingTimeInterval(120) })
            .filter({ $0 > Date() }).min() {
            let work = DispatchWorkItem { [weak self] in self?.refreshItems() }
            inactivityExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, next.timeIntervalSinceNow), execute: work)
        }
        var active = progressItems
        var seen = Set<String>()
        active = active.filter { seen.insert($0.id).inserted }
        let represented = Set(active.map { $0.url.standardizedFileURL })
        for partial in partials.values where !represented.contains(partial.url.standardizedFileURL)
            && !represented.contains(partial.expectedURL.standardizedFileURL) {
            active.append(NotchDownloadItem(id: partial.url.path, url: partial.url,
                name: partial.expectedURL.lastPathComponent, receivedBytes: partial.bytes,
                fraction: nil, completed: false, active: Date().timeIntervalSince(partial.modified) < 120,
                date: partial.modified))
        }
        let updated = NotchDownloadSupport.mergedItems(active: active, files: folderItems, finished: finished)
        if items != updated { items = updated }
        updateActivity()
    }

    // MARK: Closed notch

    /// The transfer the closed notch follows: the newest one still moving.
    var currentTransfer: NotchDownloadItem? {
        items.first { $0.active && !$0.completed }
    }

    private func updateActivity() {
        let activity = closedNotchActivity()
        MainActor.assumeIsolated {
            UtilityActivityCenter.shared.set(activity, for: .downloads)
        }
    }

    private func closedNotchActivity() -> UtilityActivity? {
        guard folder != nil, Defaults[.downloadsShowsInClosedNotch] else { return nil }
        let transfers = items.filter { $0.active && !$0.completed }
        if let item = transfers.first {
            let text: String
            if let fraction = item.fraction {
                text = fraction.formatted(.percent.precision(.fractionLength(0)))
            } else if let bytes = item.receivedBytes, bytes > 0 {
                text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            } else {
                text = "…"
            }
            return UtilityActivity(id: .downloads, symbol: "arrow.down", tint: .blue, text: text,
                                   progress: item.fraction, priority: 10)
        }
        if showsArrival {
            return UtilityActivity(id: .downloads, symbol: "checkmark", tint: .green, text: "Done",
                                   progress: nil, priority: 10)
        }
        return nil
    }
}
