//
//  UtilitiesSettings.swift
//  boringNotch
//
//  Settings → Utilities: turn each utility on or off; enabled ones show their own options below.
//

import Defaults
import SwiftUI

struct UtilitiesSettings: View {
    @Default(.enabledUtilities) private var enabledIDs

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

            ForEach(UtilityRegistry.all.filter { enabledIDs.contains($0.id) }) { utility in
                if let makeSettings = utility.makeSettings {
                    Section {
                        makeSettings()
                    } header: {
                        Text(utility.title)
                    }
                }
            }

            Section {
                Text("Timer, Scratchpad, Downloads, Clipboard and Watch are adapted from Vorssaint (github.com/vorssaint/vorssaint-utils), used under the GNU GPL v3.")
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
