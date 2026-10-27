//
//  DownloadsUtilityView.swift
//  boringNotch
//
//  Placeholder until the Downloads utility is ported.
//

import SwiftUI

struct DownloadsUtilityView: View {
    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .downloads)
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DownloadsSettingsSection: View {
    var body: some View {
        EmptyView()
    }
}
