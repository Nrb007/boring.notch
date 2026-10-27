//
//  TimerSettingsSection.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct TimerSettingsSection: View {
    @Default(.timerSoundEnabled) private var timerSoundEnabled
    @Default(.timerShowsInClosedNotch) private var timerShowsInClosedNotch

    var body: some View {
        Toggle("Ring when a timer finishes", isOn: $timerSoundEnabled)
        Toggle("Show the countdown in the closed notch", isOn: $timerShowsInClosedNotch)
    }
}
