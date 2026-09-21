import SwiftUI
import UsageCore

// MARK: - Shared style

private extension View {
    /// The frosted card used throughout the popover.
    func card() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
    }
}

private let secondary = Color.white.opacity(0.62)

extension UsageLevel {
    /// Green below half, then yellow, orange, red.
    var color: Color {
        switch self {
        case .normal:   return Color(red: 0.30, green: 0.78, blue: 0.47)
        case .elevated: return Color(red: 0.95, green: 0.80, blue: 0.25)
        case .high:     return Color(red: 0.96, green: 0.58, blue: 0.20)
        case .critical: return Color(red: 0.93, green: 0.33, blue: 0.31)
        }
    }
}

// MARK: - Bar

struct QuotaBar: View {
    let window: QuotaWindow

    private var fill: Color { window.level.color }

    private var resetText: String {
        guard let seconds = window.secondsUntilReset() else { return "—" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label).font(.system(size: 12)).foregroundStyle(secondary)
                Spacer()
                Text("\(Int(window.usedPercent))%")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(fill)
                Text("· \(resetText)").font(.system(size: 12)).foregroundStyle(secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(fill)
                        .frame(width: max(3, geo.size.width * window.usedPercent / 100))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Provider card

struct ProviderCard: View {
    let state: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Circle().fill(state.accent).frame(width: 9, height: 9)
                Text(state.name).font(.system(size: 14, weight: .bold))
                if let plan = state.snapshot?.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(secondary)
                }
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }

            if let error = state.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.30))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snap = state.snapshot {
                let main = snap.windows.filter { $0.kind == .fiveHour || $0.kind == .weekly }
                ForEach(Array(main.enumerated()), id: \.offset) { _, w in
                    QuotaBar(window: w)
                }

                let models = snap.modelWindows
                if !models.isEmpty {
                    Divider().overlay(Color.white.opacity(0.1))
                    ForEach(Array(models.enumerated()), id: \.offset) { _, w in
                        QuotaBar(window: w)
                    }
                }

                if !snap.breakdown.isEmpty {
                    Divider().overlay(Color.white.opacity(0.1))
                    Text("Weekly went to").font(.system(size: 11)).foregroundStyle(secondary)
                    ForEach(snap.breakdown.filter { $0.percent > 0 }, id: \.key) { row in
                        HStack {
                            Text(row.label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text("\(Int(row.percent))%")
                                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(secondary)
                        }
                    }
                }
            } else if state.error == nil {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(secondary)
            }
        }
        .card()
    }
}

// MARK: - Root

struct PopoverView: View {
    @ObservedObject var model: UsageViewModel
    var onQuit: () -> Void

    private var updatedText: String {
        guard let d = model.lastUpdated else { return "never" }
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("LLM Usage").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("Updated \(updatedText)").font(.system(size: 11)).foregroundStyle(secondary)
            }
            .padding(.horizontal, 4)

            ForEach(model.providers) { ProviderCard(state: $0) }

            HStack(spacing: 8) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 12))
                }
                Spacer()
                Button(role: .destructive, action: onQuit) {
                    Label("Quit", systemImage: "power").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(red: 0.09, green: 0.07, blue: 0.16))
        .preferredColorScheme(.dark)
    }
}
