//
//  UtilitiesSettings.swift
//  boringNotch
//
//  Settings → Utilities: turn each utility on or off, plus each utility's own options.
//

import Defaults
import SwiftUI

struct UtilitiesSettings: View {
    @Default(.enabledUtilities) private var enabledIDs
    @Default(.timerSoundEnabled) private var timerSoundEnabled
    @Default(.timerShowsInClosedNotch) private var timerShowsInClosedNotch
    @Default(.scratchpadRetention) private var scratchpadRetention
    @Default(.scratchpadTextSize) private var scratchpadTextSize

    var body: some View {
        Form {
            Section {
                ForEach(UtilityRegistry.all) { utility in
                    Toggle(isOn: binding(for: utility.id)) {
                        Label {
                            Text(utility.title)
                        } icon: {
                            Image(systemName: utility.symbol)
                                .foregroundStyle(utility.tint)
                        }
                    }
                }
            } header: {
                Text("Utilities")
            } footer: {
                Text("Enabled utilities appear in the Utilities tab of the open notch.")
                    .foregroundStyle(.secondary)
            }

            if enabledIDs.contains(.timer) {
                Section {
                    Toggle("Ring when a timer finishes", isOn: $timerSoundEnabled)
                    Toggle("Show the countdown in the closed notch", isOn: $timerShowsInClosedNotch)
                } header: {
                    Text("Timer")
                }
            }

            if enabledIDs.contains(.scratchpad) {
                Section {
                    Picker("Clear notes left unedited", selection: $scratchpadRetention) {
                        ForEach(ScratchpadRetention.allCases, id: \.self) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                    Slider(value: $scratchpadTextSize, in: 11...18, step: 1) {
                        Text("Text size - \(Int(scratchpadTextSize))")
                    }
                } header: {
                    Text("Scratchpad")
                }
            }

            Section {
                Text("Timer and Scratchpad are adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), used under the GNU GPL v3.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Utilities")
    }

    private func binding(for id: UtilityID) -> Binding<Bool> {
        Binding(
            get: { enabledIDs.contains(id) },
            set: { isOn in
                if isOn { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
            }
        )
    }
}
