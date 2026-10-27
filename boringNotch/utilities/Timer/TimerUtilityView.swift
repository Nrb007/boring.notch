// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils), NotchTimerView.swift.
// Adapted for boring.notch: the island's top row became the utility header, menus are native
// SwiftUI menus, and strings are English.

import Defaults
import SwiftUI

struct TimerUtilityView: View {
    @ObservedObject private var service = NotchTimerService.shared
    @Default(.timerMode) private var mode
    @Default(.timerMinutes) private var savedMinutes
    @Default(.pomodoroFocusMinutes) private var focusMinutes
    @Namespace private var modeSelection

    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .timer, title: service.session.hasSession ? phaseTitle : nil) {
                if service.session.hasSession {
                    sessionProgress
                    headerButton(service.session.completed ? "Done" : "Cancel", action: service.cancel)
                } else {
                    modePicker
                    startButton
                }
            }
            Group {
                if service.session.hasSession { activeTimer }
                else { setup }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(.orange)
    }

    // MARK: Setup

    /// The timer and the Pomodoro's focus set on the ruler beside their clock;
    /// the stopwatch's clock stands alone. The Pomodoro adds a row of readouts.
    private var setup: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                switch mode {
                case .timer:
                    NotchTimerRuler(minutes: timerMinutes, label: "Timer")
                case .pomodoro:
                    NotchTimerRuler(minutes: binding(.focus), label: "Focus")
                case .stopwatch:
                    Spacer(minLength: 0)
                }
                clock(setupClock, size: 30)
            }
            .frame(height: mode == .pomodoro ? 64 : 84)
            if mode == .pomodoro {
                pomodoroSettings
                    .frame(height: 30)
            }
        }
    }

    private var startButton: some View {
        Button { service.start(mode: mode, minutes: timerMinutes.wrappedValue) } label: {
            Text("Start")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .foregroundStyle(.orange)
                .background(.orange.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode == .pomodoro ? "Start a focus session" : "Start")
    }

    /// Three words in a row, the current one underlined in the ruler's orange.
    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(NotchTimerMode.allCases, id: \.self) { candidate in
                let selected = mode == candidate
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = candidate }
                } label: {
                    Text(NotchTimerSupport.title(for: candidate))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 4)
                        .frame(height: 22)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule().fill(.orange).frame(height: 2)
                                    .padding(.horizontal, 4)
                                    .matchedGeometryEffect(id: "selection", in: modeSelection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var setupClock: String {
        switch mode {
        case .timer: return NotchTimerSupport.clockText(Double(timerMinutes.wrappedValue) * 60)
        case .pomodoro: return NotchTimerSupport.clockText(Double(binding(.focus).wrappedValue) * 60)
        case .stopwatch: return NotchTimerSupport.stopwatchText(0)
        }
    }

    /// The breaks and the sessions as readouts: the name small and dim, the
    /// value in orange, the choices behind a native menu.
    private var pomodoroSettings: some View {
        HStack(spacing: 0) {
            ForEach(NotchPomodoroOption.allCases.filter { $0 != .focus }) { option in
                readout(option).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func readout(_ option: NotchPomodoroOption) -> some View {
        let value = binding(option)
        let current = value.wrappedValue
        return Menu {
            ForEach(Array(option.range), id: \.self) { choice in
                Button {
                    value.wrappedValue = choice
                } label: {
                    if choice == current {
                        Label(display(option, choice), systemImage: "checkmark")
                    } else {
                        Text(display(option, choice))
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                    .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(display(option, current))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.orange)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(option.title)
    }

    // MARK: Running

    private var phaseTitle: String {
        service.session.cycleFinished ? "Pomodoro finished"
            : service.session.completed ? "Finished" : NotchTimerSupport.title(for: service.session.phase)
    }

    @ViewBuilder
    private var sessionProgress: some View {
        if service.session.mode == .pomodoro {
            Text("\(service.session.sessionNumber) of \(service.session.configuration.totalSessions)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The primary button and the clock.
    private var activeTimer: some View {
        HStack(spacing: 16) {
            if !service.session.completed {
                roundButton(symbol: service.session.isPaused ? "play.fill" : "pause.fill",
                            title: service.session.isPaused ? "Resume" : "Pause",
                            action: service.pauseOrResume)
            } else if service.session.canStartNext {
                roundButton(symbol: "play.fill",
                            title: "Start " + NotchTimerSupport.title(for: service.session.nextPhase).lowercased(),
                            action: service.startNext)
            }
            Spacer(minLength: 0)
            if service.session.isRunning {
                TimelineView(.periodic(from: Date(timeIntervalSinceNow: NotchTimerSupport.tickScheduleOffset(
                    for: service.session, at: service.now)), by: 1)) { _ in reading }
            } else {
                reading
            }
        }
        .padding(.horizontal, 8)
    }

    private var reading: some View {
        let value = NotchTimerSupport.clockText(for: service.session, at: service.now)
        return clock(value, size: 62)
            .contentTransition(.numericText(countsDown: !service.session.countsUp))
            .animation(.smooth(duration: 0.25), value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phaseTitle)
            .accessibilityValue(value)
    }

    // MARK: Helpers

    private var timerMinutes: Binding<Int> {
        Binding(get: { NotchTimerSupport.timerMinutes(savedMinutes) },
                set: { savedMinutes = NotchTimerSupport.timerMinutes($0) })
    }

    private func binding(_ option: NotchPomodoroOption) -> Binding<Int> {
        let range = option.range
        return Binding(get: { min(range.upperBound, max(range.lowerBound, Defaults[option.key])) },
                       set: { Defaults[option.key] = min(range.upperBound, max(range.lowerBound, $0)) })
    }

    private func display(_ option: NotchPomodoroOption, _ value: Int) -> String {
        option.isDuration ? NotchTimerSupport.compactText(Double(value) * 60) : String(value)
    }

    private func clock(_ value: String, size: CGFloat) -> some View {
        Text(value)
            .font(.system(size: size, weight: .thin)).monospacedDigit()
            .foregroundStyle(.orange)
            .lineLimit(1).minimumScaleFactor(0.5)
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .foregroundStyle(.white.opacity(0.85))
                .background(Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func roundButton(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 52, height: 52)
                .background(Color.orange.opacity(0.28), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}
