#if os(iOS)
import SwiftUI
import UIKit

// Ported from cmux iOS (ios/CmuxiOS/Sources/CmuxiOSAuth/SignIn and
// Packages/iOS/CmuxMobileSupport). Layout, copy and glass styles are kept
// identical so the two apps' sign-in screens match.

/// Platform-resolved system colors used by the sign-in chrome.
struct PlatformPalette {
    private init() {}
    static var systemBackground: Color { Color(uiColor: .systemBackground) }
    static var separator: Color { Color(uiColor: .separator) }
    static func gameOfLifeCell(colorScheme: ColorScheme) -> Color {
        Color(uiColor: colorScheme == .dark ? .systemGray4 : .systemGray2)
    }
}

struct DividerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            dividerLine
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
                .layoutPriority(1)
            dividerLine
        }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(PlatformPalette.separator.opacity(0.4))
            .frame(height: 1)
    }
}

struct GlassInputPill<Content: View>: View {
    let height: CGFloat
    let alignment: Alignment
    let content: Content
    let onTap: () -> Void

    init(height: CGFloat, alignment: Alignment, @ViewBuilder content: () -> Content, onTap: @escaping () -> Void) {
        self.height = height
        self.alignment = alignment
        self.content = content()
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(height: height)
        .mobileGlassPill()
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct GameOfLifeHeader: View {
    private let columns = 36
    private let rows = 52
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GameOfLifeGrid(columns: columns, rows: rows)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)

                LinearGradient(
                    colors: [
                        PlatformPalette.systemBackground.opacity(0.0),
                        PlatformPalette.systemBackground.opacity(colorScheme == .dark ? 0.82 : 0.70),
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }
}

struct GameOfLifeGrid: View {
    let columns: Int
    let rows: Int

    @State private var cells: [Bool] = []
    @State private var stepCount = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tick = Int(time / 0.08)

            GeometryReader { _ in
                Canvas { context, size in
                    let cellWidth = size.width / CGFloat(columns)
                    let cellHeight = size.height / CGFloat(rows)
                    let cellSize = min(cellWidth, cellHeight) * 0.52
                    let yOffset = (cellHeight - cellSize) * 0.5
                    let xOffset = (cellWidth - cellSize) * 0.5
                    let scale = max(1, displayScale)

                    func snapToPixel(_ value: CGFloat) -> CGFloat {
                        (value * scale).rounded(.toNearestOrAwayFromZero) / scale
                    }

                    for row in 0..<rows {
                        for col in 0..<columns where isAlive(row: row, col: col) {
                            let baseOpacity = colorScheme == .dark ? 0.10 : 0.16
                            let flicker = baseOpacity + 0.10 * sin(time * 2.0 + Double(row * 3 + col) * 0.22)
                            let rect = CGRect(
                                x: snapToPixel(CGFloat(col) * cellWidth + xOffset),
                                y: snapToPixel(CGFloat(row) * cellHeight + yOffset),
                                width: snapToPixel(cellSize),
                                height: snapToPixel(cellSize)
                            )
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: rect.width * 0.5),
                                with: .color(PlatformPalette.gameOfLifeCell(colorScheme: colorScheme).opacity(max(0.0, flicker)))
                            )
                        }
                    }
                }
            }
            .onChange(of: tick) { _, _ in
                step()
            }
            .onAppear {
                if cells.isEmpty {
                    seed()
                }
            }
        }
    }

    private func index(row: Int, col: Int) -> Int { row * columns + col }

    private func isAlive(row: Int, col: Int) -> Bool {
        let idx = index(row: (row + rows) % rows, col: (col + columns) % columns)
        return idx < cells.count ? cells[idx] : false
    }

    private func seed() {
        var rng = SystemRandomNumberGenerator()
        cells = (0..<(rows * columns)).map { _ in Double.random(in: 0...1, using: &rng) < 0.22 }
        stepCount = 0
    }

    private func step() {
        guard !cells.isEmpty else {
            seed()
            return
        }
        var next = cells
        var aliveCount = 0
        for row in 0..<rows {
            for col in 0..<columns {
                let idx = index(row: row, col: col)
                let neighbors = neighborCount(row: row, col: col)
                let alive = cells[idx]
                let nextAlive = (alive && (neighbors == 2 || neighbors == 3)) || (!alive && neighbors == 3)
                next[idx] = nextAlive
                if nextAlive { aliveCount += 1 }
            }
        }
        stepCount += 1
        if aliveCount < max(6, (rows * columns) / 22) || stepCount > 120 {
            seed()
            return
        }
        cells = next
    }

    private func neighborCount(row: Int, col: Int) -> Int {
        var count = 0
        for dr in -1...1 {
            for dc in -1...1 where dr != 0 || dc != 0 {
                if isAlive(row: row + dr, col: col + dc) { count += 1 }
            }
        }
        return count
    }
}

/// The secondary actions shown when an email-auth account needs verification.
struct SignInBillingRecoveryActions: View {
    let isVisible: Bool
    let isAuthInProgress: Bool
    let isRequestingEmailVerification: Bool
    @Binding var isRequestingBillingRecovery: Bool
    @Binding var billingRecoveryMessage: String?
    let requestEmailVerification: () async -> Void
    let requestBillingRecovery: () async -> Void

    @ViewBuilder
    var body: some View {
        if isVisible {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        Task { await requestEmailVerification() }
                    } label: {
                        Text("Resend verification email")
                            .multilineTextAlignment(.center)
                            .mobileButtonLoading(isRequestingEmailVerification, tint: .secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(isAuthInProgress)
                    .accessibilityIdentifier("signin.emailVerificationResend")

                    Button {
                        Task { await requestBillingRecovery() }
                    } label: {
                        Text("Already paid? Recover your account")
                            .multilineTextAlignment(.center)
                            .mobileButtonLoading(isRequestingBillingRecovery, tint: .secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(isAuthInProgress || isRequestingBillingRecovery)
                    .accessibilityIdentifier("signin.billingRecovery")
                }

                if let billingRecoveryMessage {
                    Text(billingRecoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("signin.billingRecoveryMessage")
                }
            }
        }
    }
}

/// "Restoring session" status shown while the stored session is validated.
struct SignInAuthRestoreStatusView: View {
    private static let authRestoreTimeout: Duration = .seconds(10)

    let controller: SignInController
    @State private var authRestoreTimedOut = false
    @State private var authRestoreRetryGeneration = 0

    var body: some View {
        if controller.isRestoringSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if authRestoreTimedOut {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(authRestoreTimedOut ? "Still restoring session" : "Restoring session")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text(authRestoreTimedOut
                    ? "cmux could not finish checking your saved session. Check your connection, then retry."
                    : "Checking your saved session. Sign-in options are paused until this finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if authRestoreTimedOut {
                    Button {
                        authRestoreTimedOut = false
                        authRestoreRetryGeneration &+= 1
                        Task { await controller.auth.restore() }
                    } label: {
                        Text("Retry")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("signin.restoreRetry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("signin.restoreStatus")
            .task(id: (authRestoreRetryGeneration &* 2) + (controller.isRestoringSession ? 1 : 0)) {
                authRestoreTimedOut = false
                // Bounded user-facing deadline, not synchronization.
                do { try await ContinuousClock().sleep(for: Self.authRestoreTimeout) } catch { return }
                guard controller.isRestoringSession else { return }
                authRestoreTimedOut = true
            }
        }
    }
}

extension View {
    /// Glass button styling for secondary sign-in actions.
    func mobileGlassButton() -> some View {
        buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.extraLarge)
    }

    /// Prominent glass primary button styling.
    func mobileGlassProminentButton() -> some View {
        buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.extraLarge)
    }

    /// Glass capsule pill background for input fields.
    func mobileGlassPill() -> some View {
        glassEffect(.regular.interactive(), in: .capsule)
    }

    /// Hides the label and overlays a small spinner without changing layout.
    @ViewBuilder
    func mobileButtonLoading(_ isLoading: Bool, tint: Color? = nil) -> some View {
        self
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                }
            }
    }

    func mobileEmailTextInput() -> some View {
        keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    func mobileOneTimeCodeInput() -> some View {
        keyboardType(.asciiCapable)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
    }
}

extension UIApplication {
    /// Resigns the keyboard across every window in every connected scene.
    @MainActor
    func dismissMobileKeyboard() {
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.endEditing(true) }
        }
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
