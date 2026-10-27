// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), NotchWatchService.swift.
// Adapted for boring.notch: the reading shows in the closed notch through UtilityActivityCenter,
// the "rule met" alert is a sound plus the closed-notch text (no island notice, mascot or
// system notification), captures go through ScreenCaptureKit only, and the area is chosen with
// Watch's own overlay.

import AppKit
import Combine
import Defaults

/// The area a watch reads: a part of one window, followed wherever the window goes, even
/// covered, or a fixed part of a display when no window was under it.
struct NotchWatchTarget: Equatable {
    let windowID: CGWindowID?
    let displayID: CGDirectDisplayID
    /// In points from the window's top-left corner; for a display, in points from the
    /// display's top-left corner.
    let crop: CGRect
    let appName: String
    let processID: pid_t?
    let windowTitle: String?

    var appIcon: NSImage? {
        processID.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
    }
}

enum NotchWatchState: Equatable {
    case idle
    case watching
    /// The window is there but cannot be read now, as when it is minimized, on another Space
    /// or the screen is locked. Watching continues when it can.
    case hidden
    case finished(NotchWatchOutcome)
}

/// Turns any part of any window into a live activity: reads it every second or two on the Mac
/// itself, shows the reading in the closed notch and alerts once the chosen rule is met.
@MainActor
final class WatchService: ObservableObject {
    static let shared = WatchService()

    @Published private(set) var target: NotchWatchTarget?
    @Published private(set) var state: NotchWatchState = .idle
    @Published private(set) var preview: CGImage?
    @Published private(set) var text = ""
    @Published private(set) var headline = ""
    /// The line chosen to show in the closed notch; nil picks one automatically.
    @Published private(set) var headlineLine: Int?
    @Published private(set) var startedAt: Date?
    @Published private(set) var condition: NotchWatchCondition = Defaults[.watchCondition]
    @Published private(set) var matchText = ""
    @Published private(set) var matchNumber: Double?
    /// Screen Recording was turned off while watching: the area stays hidden until it is
    /// allowed again.
    @Published private(set) var permissionMissing = false
    @Published private(set) var isChoosing = false

    /// The page is on screen: read more often so the preview feels live.
    var pageVisible = false {
        didSet { if pageVisible, !oldValue, isActive { restartLoop() } }
    }

    var isActive: Bool { target != nil && (state == .watching || state == .hidden) }

    private var tracker = NotchWatchTracker(condition: .changes)
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var fingerprint: [UInt8]?
    private var signature: String?
    private var readAt: Date?
    private var regionCapture: WatchCapture.RegionCapture?
    private var picker: WatchAreaPicker?
    /// A chosen area can still be preparing after the picker closes. Stopping or choosing
    /// again makes that preparation stale.
    private var choiceGeneration = UUID()
    private var enabledObserver: Task<Void, Never>?
    private lazy var tone = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: false)

    private init() {
        // Turning the utility off stops watching, and closes the picker if it is up.
        enabledObserver = Task { @MainActor [weak self] in
            for await _ in Defaults.updates(.enabledUtilities, initial: false) {
                if !NotchWatchSupport.isEnabled() { self?.stop() }
            }
        }
    }

    // MARK: Choosing

    func chooseArea() {
        guard NotchWatchSupport.isEnabled(), picker == nil, !WatchAreaPicker.isOnScreen else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }
        let choice = UUID()
        choiceGeneration = choice
        let picker = WatchAreaPicker()
        self.picker = picker
        isChoosing = true
        picker.begin { [weak self] pick in
            guard let self, self.choiceGeneration == choice else { return }
            self.picker = nil
            self.isChoosing = false
            guard let pick else { return }
            Task { @MainActor [weak self] in await self?.watch(pick, choice: choice) }
        }
    }

    private func watch(_ pick: WatchPick, choice: UUID) async {
        guard choiceGeneration == choice, NotchWatchSupport.isEnabled() else { return }
        let picked: (id: CGWindowID, crop: CGRect)?
        var displayID: CGDirectDisplayID = CGMainDisplayID()
        switch pick {
        case .window(let id):
            picked = WatchCapture.windowInfo(id).map { (id, CGRect(origin: .zero, size: $0.bounds.size)) }
        case .area(let globalRect, let display, _, _):
            displayID = display
            picked = NotchWatchSupport.windowCrop(for: globalRect, windows: WatchCapture.pickableWindows())
        }
        let target: NotchWatchTarget
        if let picked, let info = WatchCapture.windowInfo(picked.id) {
            regionCapture = nil
            target = NotchWatchTarget(windowID: picked.id, displayID: displayID, crop: picked.crop,
                                      appName: info.appName, processID: info.processID, windowTitle: info.title)
        } else if case .area(_, let display, let displayRect, let scale) = pick {
            // Nothing but the desktop or the menu bar under it: read that part of the display
            // as it is.
            guard let capture = await WatchCapture.prepareDisplayRegion(displayID: display, pointRect: displayRect,
                                                                        scale: scale) else { return }
            guard choiceGeneration == choice, NotchWatchSupport.isEnabled() else { return }
            regionCapture = capture
            target = NotchWatchTarget(windowID: nil, displayID: display, crop: displayRect,
                                      appName: "Screen area", processID: nil, windowTitle: nil)
        } else {
            return
        }
        // Another area has other lines: its reading starts automatic again.
        headlineLine = nil
        begin(target)
        UtilitiesState.shared.openUtility = .watch
    }

    // MARK: Watching

    func watchAgain() {
        guard let target, NotchWatchSupport.isEnabled() else { return }
        if let windowID = target.windowID, WatchCapture.windowInfo(windowID) == nil { return }
        begin(target)
    }

    var canWatchAgain: Bool {
        guard let target, case .finished = state else { return false }
        return target.windowID.map { WatchCapture.windowInfo($0) != nil } ?? (regionCapture != nil)
    }

    func stop() {
        choiceGeneration = UUID()
        let choosing = picker
        picker = nil
        isChoosing = false
        choosing?.cancel()
        cancelLoop()
        target = nil
        state = .idle
        preview = nil
        text = ""
        headline = ""
        startedAt = nil
        headlineLine = nil
        regionCapture = nil
        fingerprint = nil
        signature = nil
        readAt = nil
        permissionMissing = false
        publishActivity()
    }

    func setHeadlineLine(_ line: Int?) {
        guard line != headlineLine else { return }
        headlineLine = line
        headline = NotchWatchSupport.headline(from: text, line: line)
        publishActivity()
    }

    func setCondition(_ condition: NotchWatchCondition) {
        guard condition != self.condition else { return }
        self.condition = condition
        Defaults[.watchCondition] = condition
        resetTracker()
    }

    /// Typed words and numbers apply once confirmed, so a half-typed "1" on the way to 100
    /// cannot end the watch early.
    func setMatchText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != matchText else { return }
        matchText = trimmed
        if condition == .contains { resetTracker() }
    }

    /// Read as the Mac's region writes numbers, so 1.000 is a thousand where a comma starts
    /// the decimals.
    func setMatchNumber(_ text: String) {
        let value = NotchWatchSupport.typedNumber(text, locale: .autoupdatingCurrent)
        guard value != matchNumber else { return }
        matchNumber = value
        if condition == .reaches { resetTracker() }
    }

    private func begin(_ target: NotchWatchTarget) {
        // Another area must not show the last one's picture while it is first read.
        if target != self.target { preview = nil }
        self.target = target
        state = .watching
        startedAt = Date()
        fingerprint = nil
        signature = nil
        readAt = nil
        permissionMissing = false
        text = ""
        headline = ""
        tracker = makeTracker()
        publishActivity()
        restartLoop()
    }

    /// A new rule starts from what the area shows now.
    private func resetTracker() {
        tracker = makeTracker()
        guard isActive, state == .watching, signature != nil else { return }
        if let outcome = tracker.observe(signature: signature, reading: text, at: Date()) { finish(outcome) }
    }

    private func makeTracker() -> NotchWatchTracker {
        NotchWatchTracker(condition: condition, text: matchText, target: matchNumber, locale: .autoupdatingCurrent)
    }

    private func restartLoop() {
        cancelLoop()
        let generation = UUID()
        self.generation = generation
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation, self.isActive else { return }
                await self.read()
                guard self.generation == generation, self.isActive else { return }
                let interval = self.pageVisible ? NotchWatchSupport.visibleInterval : NotchWatchSupport.backgroundInterval
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    private func cancelLoop() {
        loop?.cancel()
        loop = nil
        generation = UUID()
    }

    private func setState(_ new: NotchWatchState) {
        guard state != new else { return }
        state = new
        publishActivity()
    }

    private func read() async {
        guard let target else { return }
        guard NotchWatchSupport.isEnabled() else { stop(); return }
        let generation = self.generation
        var window: WatchWindowInfo?
        if let windowID = target.windowID {
            guard let info = WatchCapture.windowInfo(windowID) else { finish(.closed); return }
            window = info
        }
        // Turned off in System Settings: nothing can be read, and asking the capture again
        // would only raise the system's prompt.
        guard CGPreflightScreenCaptureAccess() else {
            setState(.hidden)
            if !permissionMissing { permissionMissing = true }
            return
        }
        if permissionMissing { permissionMissing = false }
        // ScreenCaptureKit draws nothing from sleeping displays.
        let displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let image: CGImage?
        if let window {
            if window.onScreen, !displaysAsleep {
                let scale = NSScreen.screens.first { $0.watchDisplayID == target.displayID }?.backingScaleFactor
                    ?? NSScreen.main?.backingScaleFactor ?? 2
                let size = window.bounds.size
                let full = await WatchCapture.captureWindow(window.id, scale: scale)
                    .flatMap { WatchCapture.coversWindow($0, size: size) ? $0 : nil }
                image = full.flatMap { full in
                    NotchWatchSupport.pixelCrop(target.crop, windowSize: size,
                                                imageSize: CGSize(width: full.width, height: full.height))
                        .flatMap { full.cropping(to: $0) }
                }
            } else {
                image = nil
            }
        } else {
            guard !displaysAsleep, let region = regionCapture else { return }
            image = await region.image()
        }
        guard self.generation == generation, isActive else { return }
        guard let image else {
            setState(.hidden)
            return
        }
        setState(.watching)
        // A whole window can be large: its picture is summed up off the main thread.
        let picture = await Task.detached(priority: .utility) { NotchWatchSupport.fingerprint(image) }.value
        guard self.generation == generation, isActive else { return }
        if signature != nil, NotchWatchSupport.sameFingerprint(picture, fingerprint),
           let readAt, Date().timeIntervalSince(readAt) < NotchWatchSupport.rereadInterval {
            // The area looks as it did: no need to read it again, but it confirms a change and
            // lets time settle it.
            if let outcome = tracker.observe(signature: signature, reading: text, at: Date()) { finish(outcome) }
            return
        }
        let (area, recognized) = await Task.detached(priority: .utility) { () -> (CGImage, String) in
            let area = NotchWatchSupport.standalone(image)
            let source = WatchCapture.scaledForRecognition(area) ?? area
            return (area, WatchCapture.recognizeText(in: source))
        }.value
        // Kept only once read: a reading dropped halfway must not leave the area marked as
        // read, or a still area would never be read again.
        guard self.generation == generation, isActive else { return }
        fingerprint = picture
        readAt = Date()
        preview = area
        text = recognized
        let headline = NotchWatchSupport.headline(from: recognized, line: headlineLine)
        if headline != self.headline { self.headline = headline }
        signature = NotchWatchSupport.signature(text: recognized, fingerprint: picture)
        publishActivity()
        if let outcome = tracker.observe(signature: signature, reading: recognized, at: Date()) { finish(outcome) }
    }

    private func finish(_ outcome: NotchWatchOutcome) {
        guard target != nil, isActive else { return }
        cancelLoop()
        state = .finished(outcome)
        publishActivity()
        if Defaults[.watchSoundEnabled] {
            if let tone { tone.stop(); tone.play() } else { NSSound.beep() }
        }
    }

    // MARK: Closed notch

    /// The reading while watching, the outcome once a rule is met, nothing when idle.
    private func publishActivity() {
        let center = UtilityActivityCenter.shared
        guard target != nil, NotchWatchSupport.isEnabled() else { center.set(nil, for: .watch); return }
        let text: String
        var progress: Double?
        switch state {
        case .idle:
            center.set(nil, for: .watch)
            return
        case .finished(let outcome):
            text = outcome.title
        case .hidden:
            text = permissionMissing ? "No access" : (headline.isEmpty ? "Hidden" : headline)
        case .watching:
            text = headline.isEmpty ? (preview == nil ? "…" : "No text") : headline
            progress = Self.percentage(in: headline)
        }
        center.set(UtilityActivity(id: .watch, symbol: "eye", tint: .purple, text: text,
                                   progress: progress, priority: 5), for: .watch)
    }

    /// 0...1 when the reading is a percentage, as a progress bar's label usually is.
    private static func percentage(in headline: String) -> Double? {
        guard headline.hasSuffix("%"),
              let value = NotchWatchSupport.number(in: headline, decimalSeparator: Locale.autoupdatingCurrent.decimalSeparator ?? "."),
              value >= 0, value <= 100 else { return nil }
        return value / 100
    }
}
