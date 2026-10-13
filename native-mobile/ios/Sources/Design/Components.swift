import SwiftUI

// Shared building blocks for empty, loading and failure states, matching
// the shared language of Claude, ChatGPT (Codex) and Grok: a centered line
// symbol, a title, one secondary line, a solid capsule CTA and an optional
// text button; shimmering text while work is in flight; small glass status
// capsules for transient connection states.

// MARK: Buttons

/// Solid label-colored capsule (white in dark mode), the primary CTA in
/// all three reference apps.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, fullWidth ? 20 : 22)
            .padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 52 : 44)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(Capsule().fill(Color.primary.opacity(isEnabled ? 1 : 0.3)))
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Outlined capsule, the secondary full-width action (Codex "Pair manually instead").
struct OutlineCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.primary)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    static var primaryCapsule: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle() }
    static var primaryCapsuleWide: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle(fullWidth: true) }
}

extension ButtonStyle where Self == OutlineCapsuleButtonStyle {
    static var outlineCapsule: OutlineCapsuleButtonStyle { OutlineCapsuleButtonStyle() }
}

// MARK: Empty / failure states

/// Centered state: symbol, title, message, primary capsule, text button.
struct StateMessageView<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    var footnote: String?
    @ViewBuilder var actions: Actions
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                    .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                VStack(spacing: 4) { actions }
                    .padding(.top, 14)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { withAnimation(.smooth(duration: 0.35)) { appeared = true } }
    }
}

extension StateMessageView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil, footnote: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message, footnote: footnote) { EmptyView() }
    }
}

/// Codex list-level failure: cloud symbol, "Couldn't load ...", Retry capsule.
struct LoadFailedView: View {
    let title: String
    let message: String
    let onRetry: () -> Void
    @State private var retrying = false

    var body: some View {
        StateMessageView(systemImage: "icloud.slash", title: title, message: message) {
            Button {
                Haptics.tap()
                retrying = true
                onRetry()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    retrying = false
                }
            } label: {
                if retrying { ProgressView().controlSize(.small).tint(Color(uiColor: .systemBackground)) } else { Text(String(localized: "Retry")) }
            }
            .buttonStyle(.primaryCapsule)
            .disabled(retrying)
            .accessibilityIdentifier("state.retry")
        }
    }
}

/// Grok-style inline failure card: icon, title, body, white CTA.
struct FailureCard: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primaryCapsuleWide)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Shimmer and skeletons

/// ChatGPT's "Working" shimmer: a soft highlight sweeping across text.
/// Static under Reduce Motion.
struct ShimmerModifier: ViewModifier {
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if !active || reduceMotion {
            content
        } else {
            content
                .overlay {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.85), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: width)
                        .offset(x: phase * width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -1
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View { modifier(ShimmerModifier(active: active)) }
}

/// Shimmering secondary status text ("Connecting to Mac…").
struct WorkingText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .shimmer()
            .accessibilityLabel(text)
    }
}

/// Placeholder bar for skeleton rows.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
    }
}

/// A list-row-shaped skeleton (icon tile + two lines).
struct SkeletonRow: View {
    var titleWidth: CGFloat = 170
    var subtitleWidth: CGFloat = 120
    var leading: CGFloat = 38

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: leading, height: leading)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: titleWidth, height: 12)
                SkeletonBar(width: subtitleWidth, height: 9)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

/// Shimmering placeholder for a screen's first load: list rows (folders,
/// changed files, references) or code lines (diffs, file previews).
struct LoadingSkeleton: View {
    enum Shape { case list, code }
    var shape: Shape = .list
    let label: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: shape == .list ? 10 : 9) {
                switch shape {
                case .list:
                    ForEach(0..<7, id: \.self) { index in
                        SkeletonRow(titleWidth: [170, 120, 200, 140, 90, 160, 110][index],
                                    subtitleWidth: [110, 80, 130, 70, 100, 90, 60][index], leading: 28)
                    }
                case .code:
                    SkeletonBar(width: 180, height: 14).padding(.bottom, 8)
                    ForEach(0..<16, id: \.self) { index in
                        SkeletonBar(width: CGFloat([280, 220, 310, 160, 250, 90, 300, 200, 130, 270, 240, 110, 290, 180, 230, 150][index]), height: 10)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shimmer()
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Skeleton of the Home list while the first tree loads.
struct HomeSkeleton: View {
    let hostName: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WorkingText(text: hostName.map { String(localized: "Connecting to \($0)…") } ?? String(localized: "Connecting…"))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                ForEach(0..<3, id: \.self) { section in
                    SkeletonBar(width: [90, 60, 110][section], height: 10)
                        .padding(.horizontal, 20)
                        .padding(.top, section == 0 ? 0 : 22)
                        .padding(.bottom, 10)
                    VStack(spacing: 4) {
                        ForEach(0..<(section == 0 ? 2 : 1), id: \.self) { row in
                            SkeletonRow(titleWidth: row == 0 ? 190 : 140, subtitleWidth: row == 0 ? 130 : 160)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .padding(.horizontal, 16)
                }
            }
            .shimmer()
        }
        .scrollDisabled(true)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hostName.map { String(localized: "Connecting to \($0)") } ?? String(localized: "Connecting"))
    }
}

// MARK: Connection status

/// Small glass status capsule for transient states (reconnecting,
/// offline). Unobtrusive, like the reference apps' floating capsules.
struct ConnectionStatusCapsule: View {
    enum Kind: Equatable {
        case connecting(String?)
        case reconnecting
        case offline(String)
    }

    let kind: Kind
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .connecting, .reconnecting:
                ProgressView().controlSize(.mini)
                Text(title).font(.footnote.weight(.medium)).shimmer()
            case .offline:
                Image(systemName: "wifi.slash").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(title).font(.footnote.weight(.medium)).lineLimit(1)
                if let onRetry {
                    Button {
                        Haptics.tap()
                        onRetry()
                    } label: {
                        Text(String(localized: "Retry"))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .background(Capsule().fill(Color.primary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("status.retry")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, kindHasRetry ? 5 : 14)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status.capsule")
    }

    private var kindHasRetry: Bool {
        if case .offline = kind { return onRetry != nil }
        return false
    }

    private var title: String {
        switch kind {
        case .connecting(let name): name.map { String(localized: "Connecting to \($0)…") } ?? String(localized: "Connecting…")
        case .reconnecting: String(localized: "Reconnecting…")
        case .offline(let name): String(localized: "\(name) is offline")
        }
    }
}

extension HostConnection.Phase {
    /// Status capsule for this phase when showing cached content, nil when live.
    func statusKind(hostName: String) -> ConnectionStatusCapsule.Kind? {
        switch self {
        case .connected: nil
        case .connecting: .connecting(nil)
        case .reconnecting: .reconnecting
        case .offline: .offline(hostName)
        }
    }
}

// MARK: Text highlighting

/// Bolds and tints every case-insensitive occurrence of `query` (search results).
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var attributed = AttributedString(text)
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return attributed }
    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
        if let lower = AttributedString.Index(found.lowerBound, within: attributed),
           let upper = AttributedString.Index(found.upperBound, within: attributed) {
            attributed[lower..<upper].foregroundColor = Theme.attention
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        searchRange = found.upperBound..<text.endIndex
    }
    return attributed
}
