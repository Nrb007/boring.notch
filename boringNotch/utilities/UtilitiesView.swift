//
//  UtilitiesView.swift
//  boringNotch
//
//  The Utilities tab: a grid of tiles, or the open utility's page.
//

import Defaults
import SwiftUI

struct UtilitiesView: View {
    @ObservedObject private var state = UtilitiesState.shared
    @Default(.enabledUtilities) private var enabledIDs

    private var enabled: [NotchUtility] {
        UtilityRegistry.all.filter { enabledIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if let id = state.openUtility, enabledIDs.contains(id), let utility = UtilityRegistry.utility(id) {
                utility.makePage()
                    .id(id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            } else if enabled.isEmpty {
                emptyState
            } else {
                grid
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
    }

    private static let tileMinWidth: CGFloat = 104
    private static let tileMinHeight: CGFloat = 64
    private static let tileSpacing: CGFloat = 8

    /// As many columns as fit (never more than there are tiles), and tiles that stretch to fill
    /// the page: a single row takes the whole height.
    private var grid: some View {
        GeometryReader { geo in
            let spacing = Self.tileSpacing
            let fitting = max(1, Int((geo.size.width + spacing) / (Self.tileMinWidth + spacing)))
            let columns = min(enabled.count, fitting)
            let rows = Int(ceil(Double(enabled.count) / Double(columns)))
            let tileHeight = max(Self.tileMinHeight,
                                 (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                          spacing: spacing) {
                    ForEach(enabled) { utility in
                        UtilityTile(utility: utility, height: tileHeight) {
                            state.open(utility.id)
                        }
                    }
                }
            }
            .scrollDisabled(tileHeight > Self.tileMinHeight)
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.title2)
                .foregroundStyle(.gray)
            Text("No utilities enabled")
                .font(.subheadline)
                .foregroundStyle(.white)
            Text("Turn some on in Settings → Utilities")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UtilityTile: View {
    let utility: NotchUtility
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    // Tiles that grew to fill the page get a larger icon, with the name at the bottom
    private var isLarge: Bool { height >= 96 }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: utility.symbol)
                    .font(.system(size: isLarge ? 26 : 18, weight: .semibold))
                    .foregroundStyle(utility.tint)
                Spacer(minLength: 0)
                Text(utility.title)
                    .font(isLarge ? .headline : .subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(isLarge ? 14 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.14 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The top row of a utility page: a way back to the grid, the utility's name, and room on the
/// trailing side for the page's own controls.
struct UtilityHeader<Trailing: View>: View {
    let utility: UtilityID
    var title: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let info = UtilityRegistry.utility(utility)
        HStack(spacing: 6) {
            Button {
                UtilitiesState.shared.close()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back to utilities")

            if let info {
                Image(systemName: info.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(info.tint)
                Text(title ?? info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(height: 24)
    }
}

extension UtilityHeader where Trailing == EmptyView {
    init(utility: UtilityID, title: String? = nil) {
        self.init(utility: utility, title: title, trailing: { EmptyView() })
    }
}
