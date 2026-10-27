//
//  WatchUtilityView.swift
//  boringNotch
//
//  Placeholder until the Watch utility is ported.
//

import SwiftUI

struct WatchUtilityView: View {
    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .watch)
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WatchSettingsSection: View {
    var body: some View {
        EmptyView()
    }
}
