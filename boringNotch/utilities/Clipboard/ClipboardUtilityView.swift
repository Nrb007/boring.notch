//
//  ClipboardUtilityView.swift
//  boringNotch
//
//  Placeholder until the Clipboard utility is ported.
//

import SwiftUI

struct ClipboardUtilityView: View {
    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .clipboard)
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ClipboardSettingsSection: View {
    var body: some View {
        EmptyView()
    }
}
