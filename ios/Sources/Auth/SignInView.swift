import StackAuth
import SwiftUI
import Sentry
import UIKit

struct SignInView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var email = ""
    @State private var code = ""
    @State private var showCodeEntry = false
    @State private var error: String?
    @State private var isAppleSigningIn = false
    @State private var shouldAutofocusCode = false
    @State private var shouldAutofocusEmail = false
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()
                
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // Keep the glass container scoped to the actual glass controls so it tracks layout changes
                    // (like the keyboard) more predictably.
                    GlassEffectContainer {
                        if !showCodeEntry {
                            emailEntryView
                        } else {
                            codeEntryView
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Email Entry

    private var emailEntryView: some View {
        authCard {
            VStack(spacing: 20) {
                brandHeader

                appleSignInView

                DividerLabel(text: "or continue with email")

                VStack(spacing: 12) {
                    GlassInputPill(height: 50, alignment: .leading) {
                        TextField("Email address", text: $email)
                            .textFieldStyle(.plain)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .focused($emailFocused)
                            // Keep UITests stable: multiple UITests check for this to detect the sign-in screen.
                            .accessibilityIdentifier("Email")
                    } onTap: {
                        emailFocused = true
                    }

                    Button {
                        // Capture focus synchronously; the Task may start after focus updates from the tap.
                        let autofocusCodeOnSuccess = emailFocused
                        Task {
                            await sendCode(autofocusCodeOnSuccess: autofocusCodeOnSuccess)
                        }
                    } label: {
                        Text("Email me a code")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                    }
                    .disabled(email.isEmpty || authManager.isLoading || isAppleSigningIn)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.extraLarge)
                }

                if let error {
                    errorText(error)
                }
            }
        }
        .onAppear {
            guard shouldAutofocusEmail else { return }
            // Focus needs to happen after the view exists in the hierarchy.
            DispatchQueue.main.async {
                emailFocused = true
            }
            shouldAutofocusEmail = false
        }
    }

    // MARK: - Code Entry

    private var codeEntryView: some View {
        authCard {
            VStack(spacing: 18) {
                brandHeader

                VStack(spacing: 6) {
                    Text("Check your email")
                        .font(.headline)

                    Text("We sent a code to \(email)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                GlassInputPill(height: 60, alignment: .center) {
                    TextField("000000", text: $code)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .focused($codeFocused)
                        .onChange(of: code) { _, newValue in
                            if newValue.count > 6 {
                                code = String(newValue.prefix(6))
                            }
                            if newValue.count == 6 {
                                Task { await verifyCode() }
                            }
                        }
                } onTap: {
                    codeFocused = true
                }
                .onAppear {
                    guard shouldAutofocusCode else { return }
                    // Focus needs to happen after the view exists in the hierarchy.
                    DispatchQueue.main.async {
                        codeFocused = true
                    }
                    shouldAutofocusCode = false
                }

                if let error {
                    errorText(error)
                }

                Button {
                    Task { await verifyCode() }
                } label: {
                    Text("Verify code")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
                }
                .disabled(code.count != 6 || authManager.isLoading || isAppleSigningIn)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)

                Button("Use a different email") {
                    let autofocusEmailOnReturn = codeFocused
                    withAnimation {
                        shouldAutofocusEmail = autofocusEmailOnReturn
                        showCodeEntry = false
                        code = ""
                        error = nil
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func sendCode(autofocusCodeOnSuccess: Bool) async {
        error = nil

        do {
            try await authManager.sendCode(to: email)
            shouldAutofocusCode = autofocusCodeOnSuccess
            withAnimation {
                showCodeEntry = true
            }
        } catch let err {
            error = detailedErrorMessage(err)
            shouldAutofocusCode = false
            print("🔐 Email code request failed: \(err)")
            SentrySDK.capture(error: err)
        }
    }

    private func verifyCode() async {
        error = nil
        do {
            try await authManager.verifyCode(code)
            // Auth state will update automatically via @Published
        } catch let err {
            error = detailedErrorMessage(err)
            print("🔐 Email code verification failed: \(err)")
            SentrySDK.capture(error: err)
            code = ""
        }
    }

    private var appleSignInView: some View {
        Button {
            Task { await signInWithApple() }
        } label: {
            Label("Sign in with Apple", systemImage: "apple.logo")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            .contentShape(.capsule)
        }
        .disabled(authManager.isLoading || isAppleSigningIn)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
        .accessibilityIdentifier("signin.apple")
    }

    private func signInWithApple() async {
        error = nil
        isAppleSigningIn = true
        defer { isAppleSigningIn = false }

        do {
            try await authManager.signInWithApple()
        } catch let err {
            if let stackError = err as? StackAuthErrorProtocol, stackError.code == "oauth_cancelled" {
                return
            }
            error = detailedErrorMessage(err)
            print("🔐 Apple Sign In failed: \(err)")
            SentrySDK.capture(error: err)
        }
    }

    private func authCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            .opacity(isAuthInProgress ? 0.6 : 1.0)
            // Dismiss keyboard when tapping empty space in the card without stealing taps from controls.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
            )
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        var lines: [String] = []

        let localized = error.localizedDescription
        if !localized.isEmpty {
            lines.append(localized)
        }

        lines.append("Type: \(String(reflecting: type(of: error)))")

        if let stackError = error as? StackAuthErrorProtocol {
            lines.append("Code: \(stackError.code)")
            lines.append("Message: \(stackError.message)")
            if let details = stackError.details {
                lines.append("Details: \(details)")
            }
        }

        let nsError = error as NSError
        lines.append("NSError domain: \(nsError.domain)")
        lines.append("NSError code: \(nsError.code)")
        if !nsError.userInfo.isEmpty {
            lines.append("UserInfo: \(nsError.userInfo)")
        }

        return lines.joined(separator: "\n")
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image("CmuxLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text("cmux")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

    private var isAuthInProgress: Bool {
        authManager.isLoading || isAppleSigningIn
    }
}



private struct DividerLabel: View {
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
            .fill(Color(.separator).opacity(0.4))
            .frame(height: 1)
    }
}

private struct GameOfLifeHeader: View {
    private let columns = 36
    private let rows = 52
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GameOfLifeGrid(columns: columns, rows: rows)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)

                LinearGradient(
                    colors: [
                        Color(.systemBackground).opacity(0.0),
                        Color(.systemBackground).opacity(colorScheme == .dark ? 0.82 : 0.70),
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

private struct GameOfLifeGrid: View {
    let columns: Int
    let rows: Int

    @State private var cells: [Bool] = []
    @State private var stepCount = 0
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @SwiftUI.Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tick = Int(time / 0.08)

            GeometryReader { proxy in
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
                        for col in 0..<columns {
                            if isAlive(row: row, col: col) {
                                let baseOpacity = colorScheme == .dark ? 0.10 : 0.16
                                let flicker = baseOpacity + 0.10 * sin(time * 2.0 + Double(row * 3 + col) * 0.22)
                                let rect = CGRect(
                                    x: snapToPixel(CGFloat(col) * cellWidth + xOffset),
                                    y: snapToPixel(CGFloat(row) * cellHeight + yOffset),
                                    width: snapToPixel(cellSize),
                                    height: snapToPixel(cellSize)
                                )
                                let base = Color(colorScheme == .dark ? UIColor.systemGray4 : UIColor.systemGray2)
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: rect.width * 0.5),
                                    with: .color(base.opacity(max(0.0, flicker)))
                                )
                            }
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

    private func index(row: Int, col: Int) -> Int {
        row * columns + col
    }

    private func isAlive(row: Int, col: Int) -> Bool {
        let wrappedRow = (row + rows) % rows
        let wrappedCol = (col + columns) % columns
        let idx = index(row: wrappedRow, col: wrappedCol)
        if idx < cells.count {
            return cells[idx]
        }
        return false
    }

    private func seed() {
        var rng = SystemRandomNumberGenerator()
        cells = (0..<(rows * columns)).map { _ in
            Double.random(in: 0...1, using: &rng) < 0.22
        }
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
                if nextAlive {
                    aliveCount += 1
                }
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
            for dc in -1...1 {
                if dr == 0 && dc == 0 {
                    continue
                }
                if isAlive(row: row + dr, col: col + dc) {
                    count += 1
                }
            }
        }
        return count
    }
}

private struct GlassInputPill<Content: View>: View {
    let height: CGFloat
    let alignment: Alignment
    let content: Content
    let onTap: () -> Void

    init(
        height: CGFloat,
        alignment: Alignment,
        @ViewBuilder content: () -> Content,
        onTap: @escaping () -> Void
    ) {
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
        // Put the glass on a stable container (not the TextField itself) to avoid hit-testing dead zones.
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}


#Preview {
    SignInView()
}
