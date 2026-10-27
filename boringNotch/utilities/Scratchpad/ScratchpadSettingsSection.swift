//
//  ScratchpadSettingsSection.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct ScratchpadSettingsSection: View {
    @Default(.scratchpadRetention) private var scratchpadRetention
    @Default(.scratchpadTextSize) private var scratchpadTextSize

    var body: some View {
        Picker("Clear notes left unedited", selection: $scratchpadRetention) {
            ForEach(ScratchpadRetention.allCases, id: \.self) { retention in
                Text(retention.title).tag(retention)
            }
        }
        Slider(value: $scratchpadTextSize, in: 11...18, step: 1) {
            Text("Text size - \(Int(scratchpadTextSize))")
        }
    }
}
