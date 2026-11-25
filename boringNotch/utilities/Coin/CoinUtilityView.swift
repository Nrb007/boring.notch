//
//  CoinUtilityView.swift
//  boringNotch
//
//  Flip a coin: click the coin (or Flip) and it spins in the air before landing on heads or
//  tails. A tally of this session's flips sits beside it.
//

import AppKit
import SwiftUI

enum CoinSide {
    case heads, tails

    var title: String {
        switch self {
        case .heads: "Heads"
        case .tails: "Tails"
        }
    }
}

/// The coin's state lives here so the result and tally survive leaving the page.
@MainActor
final class CoinFlipStore: ObservableObject {
    static let shared = CoinFlipStore()
    /// The coin's turn, counted in half-turns: even shows heads, odd shows tails.
    @Published private(set) var halfTurns: Double = 0
    @Published private(set) var lastResult: CoinSide?
    @Published private(set) var isFlipping = false
    @Published private(set) var heads = 0
    @Published private(set) var tails = 0
    /// Where the current flip started, so the coin can rise and fall along the way.
    private(set) var flipStart: Double = 0
    private(set) var flipEnd: Double = 0
    private var landTask: Task<Void, Never>?
    private init() {}

    static let flipDuration: Double = 0.9

    var side: CoinSide { Int(halfTurns).isMultiple(of: 2) ? .heads : .tails }

    func flip() {
        guard !isFlipping else { return }
        let result: CoinSide = Bool.random() ? .heads : .tails
        // A few full spins, plus a half-turn if it lands on the other face
        let spins = Double(Int.random(in: 3...5) * 2)
        let extra: Double = result == side ? 0 : 1
        flipStart = halfTurns
        flipEnd = halfTurns + spins + extra
        isFlipping = true
        withAnimation(.timingCurve(0.25, 0.6, 0.35, 1, duration: Self.flipDuration)) {
            halfTurns = flipEnd
        }
        landTask?.cancel()
        landTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.flipDuration))
            guard !Task.isCancelled, let self else { return }
            self.land(result)
        }
    }

    private func land(_ result: CoinSide) {
        isFlipping = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            lastResult = result
            if result == .heads { heads += 1 } else { tails += 1 }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func reset() {
        guard !isFlipping else { return }
        withAnimation(.smooth(duration: 0.2)) {
            heads = 0
            tails = 0
            lastResult = nil
        }
    }
}

struct CoinUtilityView: View {
    @ObservedObject private var store = CoinFlipStore.shared

    private var total: Int { store.heads + store.tails }

    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .coin) {
                if total > 0 {
                    Button("Reset", action: store.reset)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .disabled(store.isFlipping)
                }
            }
            HStack(spacing: 20) {
                Button(action: store.flip) {
                    FlippingCoin(halfTurns: store.halfTurns, start: store.flipStart, end: store.flipEnd)
                        .frame(width: 84, height: 84)
                        .padding(.vertical, 8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Flip the coin")

                VStack(alignment: .leading, spacing: 8) {
                    Text(resultText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(store.lastResult == nil || store.isFlipping ? .white.opacity(0.5) : .white)
                        .contentTransition(.numericText())
                    tally
                    Button(action: store.flip) {
                        Text("Flip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .frame(height: 24)
                            .background(Capsule().fill(coinGold))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isFlipping)
                    .opacity(store.isFlipping ? 0.5 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resultText: String {
        if store.isFlipping { return "Flipping…" }
        return store.lastResult?.title ?? "Tap to flip"
    }

    private var tally: some View {
        HStack(spacing: 12) {
            tallyItem("Heads", count: store.heads)
            tallyItem("Tails", count: store.tails)
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
    }

    private func tallyItem(_ label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.gray)
            Text("\(count)")
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            if total > 0 {
                Text("(\(Int((Double(count) / Double(total) * 100).rounded()))%)")
                    .foregroundStyle(.gray)
            }
        }
    }
}

let coinGold = Color(red: 0.96, green: 0.76, blue: 0.26)

/// The coin, turned about its horizontal axis by `halfTurns`. It's animatable so the face shown
/// follows the turn mid-flip, and it rises and falls over the course of a flip.
private struct FlippingCoin: View, Animatable {
    var halfTurns: Double
    let start: Double
    let end: Double

    var animatableData: Double {
        get { halfTurns }
        set { halfTurns = newValue }
    }

    var body: some View {
        let angle = halfTurns * 180
        // Facing away from the viewer for the middle half of each turn shows the other side
        let showsTails = cos(angle * .pi / 180) < 0
        // How far through the current flip we are
        let progress = end > start ? min(1, max(0, (halfTurns - start) / (end - start))) : 0
        let lift = sin(progress * .pi)

        CoinFace(side: showsTails ? .tails : .heads)
            // The back face would read upside down after half a turn
            .scaleEffect(x: 1, y: showsTails ? -1 : 1)
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .scaleEffect(1 + 0.18 * lift)
            .shadow(color: .black.opacity(0.4), radius: 4 + 6 * lift, y: 2 + 6 * lift)
    }
}

private struct CoinFace: View {
    let side: CoinSide

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.87, blue: 0.45), coinGold,
                                              Color(red: 0.78, green: 0.55, blue: 0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .strokeBorder(Color(red: 0.7, green: 0.48, blue: 0.08).opacity(0.8), lineWidth: 3)
                .padding(5)
            Text(side == .heads ? "H" : "T")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.36, blue: 0.04))
        }
    }
}
