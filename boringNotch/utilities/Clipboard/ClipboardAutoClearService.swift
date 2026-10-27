// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), ClipboardAutoClearService.swift
// and ClipboardAutoClearSupport.swift, adapted for boring.notch: the triggers follow the Clipboard
// utility's switch as well as their own settings, which live in Defaults.

import AppKit
import Defaults

/// What the auto clear poll should do with the change count it just read.
enum ClipboardAutoClearDecision: Equatable {
    case noteChange
    case clear
    case wait
}

enum ClipboardAutoClearSupport {
    /// - Parameters:
    ///   - changeCount: the count just read from the pasteboard.
    ///   - lastChangeCount: the count this service last acted on.
    ///   - lastClearedChangeCount: the count our own clear produced.
    ///   - lastChangeDate: when `lastChangeCount` was first seen.
    ///   - delay: seconds of stillness before content is cleared.
    static func decide(changeCount: Int, lastChangeCount: Int, lastClearedChangeCount: Int,
                       lastChangeDate: Date, now: Date, delay: TimeInterval) -> ClipboardAutoClearDecision {
        guard changeCount == lastChangeCount else { return .noteChange }
        // Our own clear bumps the change count. Without this, the next delay
        // would read that bump as fresh content and clear again, forever.
        guard changeCount != lastClearedChangeCount else { return .wait }
        return now.timeIntervalSince(lastChangeDate) >= delay ? .clear : .wait
    }
}

/// Wipes the system pasteboard on opt-in triggers: a delay after the last
/// copy, computer sleep, display sleep and screen lock. Saved history entries
/// are never touched, only the pasteboard.
@MainActor
final class ClipboardAutoClearService {
    static let shared = ClipboardAutoClearService()

    private var timer: Timer?
    /// The change count last acted on, and when it first appeared. Wall clock
    /// rather than ticks: timers don't fire while the Mac sleeps, so a machine
    /// asleep past the delay clears on the first tick after waking.
    private var lastChangeCount = 0
    private var lastChangeDate = Date()
    /// The count our own clear produced, so a clear is never mistaken for a copy.
    private var lastClearedChangeCount = -1
    private var readInFlight = false
    private var readGeneration = 0
    /// Bumped on every settings change, so a clear queued under the old
    /// settings doesn't run under the new ones. Read on the pasteboard lane.
    private let configuration = ClipboardAutoClearGeneration()

    private var sleepObserver: NSObjectProtocol?
    private var displaySleepObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private static let screenLockNotification = Notification.Name("com.apple.screenIsLocked")
    private var settingsObserver: Task<Void, Never>?

    private init() {
        settingsObserver = Task { @MainActor [weak self] in
            for await _ in Defaults.updates([.clipboardAutoClearOnDelay, .clipboardAutoClearOnSleep,
                                             .clipboardAutoClearOnDisplaySleep, .clipboardAutoClearOnScreenLock],
                                            initial: false) {
                self?.syncWithPreferences()
            }
        }
    }

    private nonisolated static func isWanted(_ key: Defaults.Key<Bool>) -> Bool {
        UtilityRegistry.isEnabled(.clipboard) && Defaults[key]
    }

    func syncWithPreferences() {
        configuration.bump()
        if Self.isWanted(.clipboardAutoClearOnDelay) {
            startTimer()
        } else {
            stopTimer()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        syncObserver(&sleepObserver, key: .clipboardAutoClearOnSleep,
                     name: NSWorkspace.willSleepNotification, center: workspaceCenter)
        syncObserver(&displaySleepObserver, key: .clipboardAutoClearOnDisplaySleep,
                     name: NSWorkspace.screensDidSleepNotification, center: workspaceCenter)
        syncObserver(&screenLockObserver, key: .clipboardAutoClearOnScreenLock,
                     name: Self.screenLockNotification, center: DistributedNotificationCenter.default())
    }

    /// Each trigger holds its own observer, so it works with the others off.
    private func syncObserver(_ token: inout NSObjectProtocol?, key: Defaults.Key<Bool>,
                              name: Notification.Name, center: NotificationCenter) {
        if Self.isWanted(key) {
            guard token == nil else { return }
            token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearNow(trigger: key) }
            }
        } else if let existing = token {
            center.removeObserver(existing)
            token = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // Whatever is already on the pasteboard gets a full delay: turning
        // the setting on never wipes something copied seconds earlier.
        lastChangeDate = Date()
        readChangeCount { [weak self] count in self?.lastChangeCount = count }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        readGeneration &+= 1
        readInFlight = false
    }

    private func tick() {
        let delay = ClipboardHistoryLimits.sanitizedAutoClearDelay(Defaults[.clipboardAutoClearDelay])
        readChangeCount { [weak self] count in
            guard let self else { return }
            switch ClipboardAutoClearSupport.decide(changeCount: count, lastChangeCount: self.lastChangeCount,
                                                    lastClearedChangeCount: self.lastClearedChangeCount,
                                                    lastChangeDate: self.lastChangeDate, now: Date(),
                                                    delay: TimeInterval(delay)) {
            case .noteChange:
                self.lastChangeCount = count
                self.lastChangeDate = Date()
            case .clear:
                self.clearNow(expecting: count, trigger: .clipboardAutoClearOnDelay)
            case .wait:
                break
            }
        }
    }

    /// Reads the change count on the pasteboard lane and answers on main.
    private func readChangeCount(_ completion: @escaping (Int) -> Void) {
        guard !readInFlight else { return }
        readInFlight = true
        readGeneration &+= 1
        let generation = readGeneration
        // A read wedged behind a password prompt frees the flag after a while;
        // its stale generation drops it whenever it finally returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                let service = ClipboardAutoClearService.shared
                if service.readGeneration == generation { service.readInFlight = false }
            }
        }
        ClipboardPasteboardAccess.shared.async(Self.changeCountWork) { [weak self] count in
            guard let self, self.readGeneration == generation else { return }
            self.readInFlight = false
            completion(count)
        }
    }

    private nonisolated static func changeCountWork() -> Int { NSPasteboard.general.changeCount }

    /// Clears the pasteboard and records the count the clear produced.
    /// `expectedChangeCount` clears only if nothing was copied since the
    /// tick that decided to; the event triggers clear whatever is there.
    private func clearNow(expecting expectedChangeCount: Int? = nil, trigger: Defaults.Key<Bool>) {
        guard Self.isWanted(trigger) else { return }
        let work = Self.clearWork(expecting: expectedChangeCount, alreadyCleared: lastClearedChangeCount,
                                  trigger: trigger, generation: configuration.current, configuration: configuration)
        ClipboardPasteboardAccess.shared.async(work) { [weak self] count in
            guard let self, let count else { return }
            self.lastChangeCount = count
            self.lastClearedChangeCount = count
            self.lastChangeDate = Date()
            // Keeps the history poll from reading the empty pasteboard as a copy.
            ClipboardHistoryService.shared.ignoreNextChange(upTo: count)
            ClipboardHistoryService.shared.pasteboardWasCleared()
        }
    }

    private nonisolated static func clearWork(expecting expectedChangeCount: Int?, alreadyCleared: Int,
                                              trigger: Defaults.Key<Bool>, generation: Int,
                                              configuration: ClipboardAutoClearGeneration) -> () -> Int? {
        {
            // Settings changed, or the trigger went off, while this was queued.
            guard configuration.current == generation, isWanted(trigger) else { return nil }
            let pasteboard = NSPasteboard.general
            let changeCount = pasteboard.changeCount
            // Locking fires display sleep and screen lock together: with
            // nothing copied since our last clear there is nothing to clear.
            guard changeCount != alreadyCleared else { return nil }
            // A copy that landed after the tick decided is owed its own delay.
            if let expectedChangeCount, changeCount != expectedChangeCount { return nil }
            return pasteboard.clearContents()
        }
    }
}

/// The settings generation, shared with the pasteboard lane.
final class ClipboardAutoClearGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int { lock.withLock { value } }

    func bump() {
        lock.withLock { value &+= 1 }
    }
}
