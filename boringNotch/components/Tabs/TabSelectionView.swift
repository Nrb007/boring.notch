//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

import Defaults

/// Home always shows; Shelf and Utilities only when they're turned on.
var tabs: [TabModel] {
    var visible = [TabModel(label: "Home", icon: "house.fill", view: .home)]
    if Defaults[.boringShelf] {
        visible.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
    }
    if !UtilityRegistry.enabled.isEmpty {
        visible.append(TabModel(label: "Utilities", icon: "square.grid.2x2.fill", view: .utilities))
    }
    return visible
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        // Clicking Utilities again goes back to its grid
                        if tab.view == .utilities && coordinator.currentView == .utilities {
                            UtilitiesState.shared.close()
                        }
                        coordinator.switchTab(to: tab.view)
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
