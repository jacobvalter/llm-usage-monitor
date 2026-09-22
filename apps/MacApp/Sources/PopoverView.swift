import AppKit
import SwiftUI
import UsageCore

// MARK: - Palette

private let secondary = Color.white.opacity(0.60)
private let hairline = Color.white.opacity(0.10)

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

// MARK: - Background

/// Real macOS blur behind the popover.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Blur, then a faint colour wash so the panel reads as dark glass.
private struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(
                colors: [
                    Color(red: 0.36, green: 0.20, blue: 0.62).opacity(0.38),
                    Color(red: 0.10, green: 0.08, blue: 0.18).opacity(0.62),
                    Color(red: 0.62, green: 0.24, blue: 0.22).opacity(0.22),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private extension View {
    /// The frosted card used throughout the popover.
    func card() -> some View {
        self
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }
}

// MARK: - Small pieces

/// Trend of the 5-hour window over the session. Memory only, so it starts empty.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count < 2 {
                Text("collecting…")
                    .font(.system(size: 9))
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            } else {
                let maxV = max(values.max() ?? 1, 1)
                let step = geo.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step,
                            y: geo.size.height * (1 - CGFloat(v / maxV)))
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

/// Where the weekly window went, as one stacked bar.
struct StackedBreakdownBar: View {
    let rows: [QuotaBreakdownRow]

    private static let palette: [Color] = [
        Color(red: 0.88, green: 0.54, blue: 0.42),
        Color(red: 0.45, green: 0.62, blue: 0.92),
        Color(red: 0.62, green: 0.52, blue: 0.90),
        Color(red: 0.55, green: 0.58, blue: 0.66),
    ]

    private var visible: [(row: QuotaBreakdownRow, color: Color)] {
        rows.filter { $0.percent > 0 }
            .enumerated()
            .map { ($0.element, Self.palette[$0.offset % Self.palette.count]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Weekly went to").font(.system(size: 11)).foregroundStyle(secondary)

            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                        Capsule()
                            .fill(item.color)
                            .frame(width: max(2, geo.size.width * item.row.percent / 100))
                    }
                }
            }
            .frame(height: 6)

            FlowRow(spacing: 10) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.row.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        Text("\(Int(item.row.percent))%")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(secondary)
                    }
                }
            }
        }
    }
}

/// Wraps its children onto more lines when they do not fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 8022064 -> "8.0M". Keeps the panel narrow.
func compactTokens(_ n: Int64) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

/// Today's tokens from the local session logs, with the split underneath.
struct TodayTokens: View {
    let totals: TokenTotals
    let hourly: [Int64]
    let accent: Color
    @Binding var range: String
    var onRangeChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(compactTokens(totals.totalTokens))
                    .font(.system(size: 22, weight: .bold)).monospacedDigit()
                Text((TokenRange(rawValue: range) ?? .today).caption)
                    .font(.system(size: 11)).foregroundStyle(secondary)
                Spacer()
                Text("\(totals.messageCount) msgs")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
            }

            Picker("", selection: $range) {
                ForEach(TokenRange.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .onChange(of: range) { _, _ in onRangeChange() }

            if hourly.contains(where: { $0 > 0 }) {
                HourlyBars(values: hourly, accent: accent).frame(height: 22)
            }

            HStack(spacing: 0) {
                split("In", totals.inputTokens)
                split("Out", totals.outputTokens)
                split("Cache rd", totals.cacheReadTokens)
                split("Cache wr", totals.cacheCreationTokens)
            }
        }
    }

    private func split(_ label: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(secondary)
            Text(compactTokens(value))
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tokens per hour for the last 12 hours.
struct HourlyBars: View {
    let values: [Int64]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 1, 1)
            let width = (geo.size.width - CGFloat(values.count - 1) * 2) / CGFloat(values.count)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(v == 0 ? Color.white.opacity(0.10) : accent.opacity(0.85))
                        .frame(width: max(2, width),
                               height: v == 0 ? 2 : max(2, geo.size.height * CGFloat(v) / CGFloat(peak)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Bar

struct QuotaBar: View {
    let window: QuotaWindow
    var compact = false
    var thresholds: LevelThresholds = .standard

    private var fill: Color { window.level(thresholds: thresholds).color }

    private var resetText: String {
        guard let seconds = window.secondsUntilReset() else { return "—" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if window.kind == .monthly, let at = window.resetsAt {
            let f = DateFormatter()
            f.dateFormat = "d MMM"
            return "resets \(f.string(from: at))"
        }
        if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
        return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(window.label).font(.system(size: 12)).foregroundStyle(secondary)
                Spacer(minLength: 6)
                Text("\(Int(window.usedPercent))%")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(fill)
                if !compact {
                    Text("· \(resetText)").font(.system(size: 11)).foregroundStyle(secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.28))
                    Capsule()
                        .fill(LinearGradient(colors: [fill.opacity(0.75), fill],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geo.size.width * window.usedPercent / 100))
                        .shadow(color: fill.opacity(0.45), radius: 3)
                }
            }
            .frame(height: 6)
        }
    }
}

/// A titled list of "name ... share bar ... tokens" rows.
struct UsageRows: View {
    let title: String
    let rows: [(label: String, totals: TokenTotals)]
    let total: Int64
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    ShareBar(fraction: share(row.totals.totalTokens), accent: accent)
                        .frame(width: 44, height: 4)
                    Text("\(row.totals.messageCount)")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
                        .frame(minWidth: 26, alignment: .trailing)
                    Text(compactTokens(row.totals.totalTokens))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
        }
    }

    private func share(_ value: Int64) -> Double {
        total > 0 ? Double(value) / Double(total) : 0
    }
}

private struct ShareBar: View {
    let fraction: Double
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(accent.opacity(0.85))
                    .frame(width: max(1, geo.size.width * fraction))
            }
        }
    }
}

// MARK: - Provider card

struct ProviderCard: View {
    let state: ProviderState
    var thresholds: LevelThresholds = .standard
    var rangeBinding: Binding<String>? = nil
    var onRangeChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Circle().fill(state.accent).frame(width: 9, height: 9)
                    .shadow(color: state.accent.opacity(0.7), radius: 3)
                Text(state.name).font(.system(size: 14, weight: .bold))
                if let plan = state.snapshot?.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                if state.snapshot != nil {
                    Sparkline(values: state.history,
                              color: state.snapshot?.tightest?.level(thresholds: thresholds).color ?? state.accent)
                        .frame(width: 56, height: 18)
                }
                if state.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                }
            }

            if let error = state.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageLevel.high.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let totals = state.tokenTotals, totals.messageCount > 0, let rangeBinding {
                TodayTokens(totals: totals, hourly: state.tokenBuckets, accent: state.accent,
                            range: rangeBinding, onRangeChange: onRangeChange)
                Divider().overlay(hairline)
            }

            if let snap = state.snapshot {
                ForEach(Array(snap.measuredWindows.filter {
                    $0.kind == .fiveHour || $0.kind == .weekly || $0.kind == .monthly
                }.enumerated()), id: \.offset) { _, w in
                    QuotaBar(window: w, thresholds: thresholds)
                }

                if !snap.unlimitedWindows.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "infinity").font(.system(size: 10))
                        Text(snap.unlimitedWindows.map(\.label).joined(separator: ", ") + " · unlimited")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(secondary)
                }

                let models = snap.modelWindows
                if !models.isEmpty {
                    Divider().overlay(hairline)
                    ForEach(Array(models.enumerated()), id: \.offset) { _, w in
                        QuotaBar(window: w, compact: true, thresholds: thresholds)
                    }
                }

                if !state.tokensByProject.isEmpty {
                    Divider().overlay(hairline)
                    UsageRows(
                        title: "Tokens by project",
                        rows: state.tokensByProject.prefix(5).map {
                            (label: $0.project, totals: $0.totals)
                        },
                        total: state.tokenTotals?.totalTokens ?? 0,
                        accent: state.accent
                    )
                }

                if !state.tokensByModel.isEmpty {
                    Divider().overlay(hairline)
                    UsageRows(
                        title: "Tokens by model",
                        rows: state.tokensByModel.prefix(4).map {
                            (label: $0.model, totals: $0.totals)
                        },
                        total: state.tokenTotals?.totalTokens ?? 0,
                        accent: state.accent
                    )
                }

                if !snap.breakdown.isEmpty {
                    Divider().overlay(hairline)
                    StackedBreakdownBar(rows: snap.breakdown)
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
    @ObservedObject var settings: AppSettings
    var onSettings: () -> Void
    var onQuit: () -> Void

    private var updatedText: String {
        guard let d = model.lastUpdated else { return "never" }
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }

    /// A scroll view has no natural height, so the popover would pick an
    /// arbitrary small one. Measure the content and ask for exactly that,
    /// capped to what fits on screen.
    @State private var contentHeight: CGFloat = 320

    private var maxHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, visible - 120)
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            if height > 0 { contentHeight = height }
        }
        .frame(width: 340, height: min(contentHeight, maxHeight))
        .background(GlassBackdrop())
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("LLM Usage").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("Updated \(updatedText)").font(.system(size: 11)).foregroundStyle(secondary)
            }
            .padding(.horizontal, 4)

            if model.providers.isEmpty {
                Text("Every provider is switched off. Open Settings to turn one on.")
                    .font(.system(size: 12)).foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else {
                ForEach(model.providers) { provider in
                    ProviderCard(
                        state: provider,
                        thresholds: settings.thresholds,
                        // Only Claude has local logs, so only it gets the period picker.
                        rangeBinding: provider.provider == .anthropic ? $settings.tokenRange : nil,
                        onRangeChange: { Task { await model.reloadLocalTokens() } }
                    )
                }
            }

            HStack(spacing: 12) {
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 12))
                }
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gearshape").font(.system(size: 12))
                }
                Spacer()
                Button(role: .destructive, action: onQuit) {
                    Label("Quit", systemImage: "power").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.top, 1)
        }
        .padding(14)
    }
}


private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
