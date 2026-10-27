// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), NotchTimerService.swift
// and NotchTimerAlert.swift, without Vorssaint's mascot and island notices: a finished timer
// shows in the closed notch and rings until dismissed.

import AppKit
import Combine
import Defaults

/// Session state is intentionally memory-only: a relaunch must never
/// resurrect a timer from a different day.
final class NotchTimerService: ObservableObject {
    static let shared = NotchTimerService()
    @Published private(set) var session = NotchTimerSession()
    private let origin = ContinuousClock.now
    private var completionTask: Task<Void, Never>?
    private var enabledObserver: Task<Void, Never>?
    private let alert = NotchTimerAlert()

    private init() {
        // Turning the utility off stops a running timer and its alarm.
        enabledObserver = Task { @MainActor [weak self] in
            for await _ in Defaults.updates(.enabledUtilities, initial: false) {
                if !NotchTimerSupport.isEnabled() { self?.cancel() }
            }
        }
    }

    var now: TimeInterval {
        let parts = origin.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func start(mode: NotchTimerMode, minutes: Int) {
        guard NotchTimerSupport.isEnabled(), !session.hasSession else { return }
        alert.stop()
        session.start(mode: mode, minutes: minutes, now: now, configuration: .load())
        scheduleCompletion()
    }

    func pauseOrResume() {
        guard NotchTimerSupport.isEnabled() else { return }
        finishIfDue()
        if session.isRunning { session.pause(at: now) }
        else if session.isPaused { session.resume(at: now) }
        scheduleCompletion()
    }

    func startNext() {
        guard NotchTimerSupport.isEnabled(), session.canStartNext else { return }
        alert.stop()
        session.startNext(at: now)
        scheduleCompletion()
    }

    func cancel() {
        alert.stop()
        completionTask?.cancel(); completionTask = nil
        session.cancel()
    }

    /// Stops the alarm without ending a Pomodoro, so its next phase can still start.
    func silence() {
        alert.stop()
    }

    private func finishIfDue() {
        guard session.finishIfDue(at: now) else { return }
        alert.start(enabled: Defaults[.timerSoundEnabled])
    }

    private func scheduleCompletion() {
        completionTask?.cancel(); completionTask = nil
        guard let deadline = session.deadline else { return }
        let remaining = max(0, deadline - now)
        completionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining), clock: .continuous) }
            catch { return }
            guard let self, !Task.isCancelled, NotchTimerSupport.isEnabled() else { return }
            self.completionTask = nil
            self.finishIfDue()
        }
    }
}

/// The deadline survives preference changes and suspension, so a completed
/// alarm cannot be restarted by a redraw, device change or return from sleep.
final class NotchTimerAlert {
    static let maximumDuration: Duration = .seconds(5 * 60)
    private var task: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private let interval: Duration
    private let now: () -> ContinuousClock.Instant
    private let sound: () -> Void
    private let stopSound: () -> Void

    convenience init() {
        let tone = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: false)
        self.init(sound: {
            if let tone { tone.stop(); tone.play() }
            else { NSSound.beep() }
        }, stopSound: { tone?.stop() })
    }

    init(interval: Duration = .seconds(2), now: @escaping () -> ContinuousClock.Instant = { .now },
         sound: @escaping () -> Void, stopSound: @escaping () -> Void) {
        self.interval = interval
        self.now = now
        self.sound = sound
        self.stopSound = stopSound
    }

    func start(enabled: Bool) {
        let current = now()
        let deadline = self.deadline ?? current.advanced(by: Self.maximumDuration)
        self.deadline = deadline
        guard enabled, current < deadline else { suspend(); return }
        guard task == nil else { return }
        sound()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.delay(until: deadline) else { return }
                do { try await Task.sleep(for: delay, clock: .continuous) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                guard self.now() < deadline else { self.suspend(); return }
                self.sound()
            }
        }
    }

    func suspend() {
        task?.cancel(); task = nil
        stopSound()
    }

    func stop() {
        suspend()
        deadline = nil
    }

    private func delay(until deadline: ContinuousClock.Instant) -> Duration {
        max(.zero, min(interval, now().duration(to: deadline)))
    }

    deinit { task?.cancel(); stopSound() }
}
