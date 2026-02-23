import SwiftUI
import WebKit
import CryptoKit
import ConvexMobile
import Combine

// MARK: - Codex OAuth View

struct CodexOAuthView: View {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var convex = ConvexClientManager.shared
    @State private var codexStatus: CodexStatus = .loading
    @State private var showWebView = false
    @State private var authURL: URL?
    @State private var codeVerifier: String?
    @State private var errorMessage: String?
    @State private var isExchangingCode = false
    @State private var currentTeamId: String?

    var body: some View {
        List {
            Section {
                statusRow
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section {
                switch codexStatus {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                case .notLinked:
                    Button("Link OpenAI Codex Account") {
                        startOAuth()
                    }
                    .frame(maxWidth: .infinity)
                case .linked(let info):
                    accountInfoRows(info)
                    Button(role: .destructive) {
                        Task { await unlinkAccount() }
                    } label: {
                        Text("Disconnect Account")
                            .frame(maxWidth: .infinity)
                    }
                case .error:
                    Button("Retry") {
                        Task { await loadStatus() }
                    }
                }
            }

            Section("About") {
                Text("Link your OpenAI account to use Codex CLI features through cmux. Your tokens are encrypted and stored securely on our servers, and refreshed automatically when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("cmux is not affiliated with, endorsed by, or sponsored by OpenAI.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("OpenAI Codex")
        .task {
            await loadStatus()
        }
        .sheet(isPresented: $showWebView) {
            if let url = authURL, let verifier = codeVerifier {
                CodexOAuthWebView(
                    url: url,
                    codeVerifier: verifier,
                    onSuccess: { tokens in
                        showWebView = false
                        Task { await saveTokens(tokens) }
                    },
                    onError: { error in
                        showWebView = false
                        errorMessage = error
                    }
                )
            }
        }
        .overlay {
            if isExchangingCode {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.primary)

                        Text("Linking Account")
                            .font(.headline)

                        Text("Saving your credentials securely...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExchangingCode)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
            Text(statusText)
            Spacer()
        }
    }

    private var statusIcon: String {
        switch codexStatus {
        case .loading: return "circle.dotted"
        case .notLinked: return "person.badge.plus"
        case .linked: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch codexStatus {
        case .loading: return .secondary
        case .notLinked: return .secondary
        case .linked: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch codexStatus {
        case .loading: return "Checking status..."
        case .notLinked: return "Not linked"
        case .linked: return "Linked"
        case .error: return "Error loading status"
        }
    }

    @ViewBuilder
    private func accountInfoRows(_ info: CodexAccountInfo) -> some View {
        if let email = info.email {
            HStack {
                Text("Email")
                Spacer()
                Text(email)
                    .foregroundStyle(.secondary)
            }
        }
        if let accountId = info.accountId {
            HStack {
                Text("Account ID")
                Spacer()
                Text(String(accountId.prefix(12)) + "...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        if let planType = info.planType {
            HStack {
                Text("Plan")
                Spacer()
                Text(planType.capitalized)
                    .foregroundStyle(planType == "pro" ? .blue : .secondary)
            }
        }
        HStack {
            Text("Proxy Token")
            Spacer()
            Text(info.proxyToken)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - OAuth Configuration

    private let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"
    private let redirectUri = "http://localhost:1455/auth/callback"

    // MARK: - Actions

    private func loadStatus() async {
        // First get the user's team membership
        guard let teamId = await getFirstTeamId() else {
            codexStatus = .notLinked
            errorMessage = "No team found. Please join a team first."
            return
        }
        currentTeamId = teamId

        // Now check for Codex tokens using subscription
        let args = CodexTokensGetArgs(teamSlugOrId: teamId)
        var cancellable: AnyCancellable?
        cancellable = convex.client
            .subscribe(to: "codexTokens:get", with: args.asDictionary(), yielding: CodexTokensGetReturn?.self)
            .first()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        break
                    case .failure(let error):
                        print("[CodexOAuth] Error loading status: \(error)")
                        self.codexStatus = .error
                    }
                    cancellable?.cancel()
                },
                receiveValue: { tokens in
                    if let tokens {
                        let userId = self.authManager.currentUser?.id ?? "unknown"
                        let proxyToken = "cmux_\(userId)_\(teamId)"
                        self.codexStatus = .linked(CodexAccountInfo(
                            email: tokens.email,
                            accountId: tokens.accountId,
                            planType: tokens.planType,
                            proxyToken: proxyToken
                        ))
                    } else {
                        self.codexStatus = .notLinked
                    }
                }
            )
    }

    private func getFirstTeamId() async -> String? {
        return await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = convex.client
                .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
                .first()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure = completion {
                            continuation.resume(returning: nil)
                        }
                        cancellable?.cancel()
                    },
                    receiveValue: { memberships in
                        continuation.resume(returning: memberships.first?.teamId)
                    }
                )
        }
    }

    private func startOAuth() {
        errorMessage = nil

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateState()

        var components = URLComponents(string: "\(issuer)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "cmux"),
        ]

        guard let url = components.url else {
            errorMessage = "Failed to build auth URL"
            return
        }

        codeVerifier = verifier
        authURL = url
        showWebView = true
    }

    private func saveTokens(_ tokens: CodexTokenResponse) async {
        guard let teamId = currentTeamId else {
            errorMessage = "No team selected"
            return
        }

        isExchangingCode = true
        defer { isExchangingCode = false }

        // Parse JWT to extract claims
        var accountId: String?
        var planType: String?
        var email: String?

        if let claims = parseJWT(tokens.access_token) {
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                accountId = auth["chatgpt_account_id"] as? String
                planType = auth["chatgpt_plan_type"] as? String
            }
            if let profile = claims["https://api.openai.com/profile"] as? [String: Any] {
                email = profile["email"] as? String
            }
        }

        // Call mutation via HTTP action workaround or direct mutation
        // For now, we'll use a simpler approach - make direct HTTP call to save
        do {
            try await saveTokensViaHTTP(
                teamId: teamId,
                accessToken: tokens.access_token,
                refreshToken: tokens.refresh_token ?? "",
                idToken: tokens.id_token,
                accountId: accountId,
                planType: planType,
                email: email,
                expiresIn: tokens.expires_in ?? 864000
            )
            await loadStatus()
        } catch {
            print("[CodexOAuth] Error saving tokens: \(error)")
            errorMessage = "Failed to save tokens: \(error.localizedDescription)"
        }
    }

    private func saveTokensViaHTTP(
        teamId: String,
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        planType: String?,
        email: String?,
        expiresIn: Int
    ) async throws {
        // Use Convex mutation through the client
        // Since ConvexMobile doesn't have a direct mutation call in subscript style,
        // we need to use the action approach or call the Convex HTTP endpoint

        // Use the configured Convex URL from Environment
        let convexUrl = Environment.current.convexURL

        let token = try await authManager.getAccessToken()

        var request = URLRequest(url: URL(string: "\(convexUrl)/api/mutation")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var args: [String: Any] = [
            "teamSlugOrId": teamId,
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresIn": expiresIn
        ]
        if let idToken = idToken { args["idToken"] = idToken }
        if let accountId = accountId { args["accountId"] = accountId }
        if let planType = planType { args["planType"] = planType }
        if let email = email { args["email"] = email }

        let body: [String: Any] = [
            "path": "codexTokens:save",
            "args": args
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexOAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CodexOAuthError.saveFailed(errorText)
        }
    }

    private func unlinkAccount() async {
        guard let teamId = currentTeamId else {
            return
        }

        do {
            let convexUrl = Environment.current.convexURL
            let token = try await authManager.getAccessToken()

            var request = URLRequest(url: URL(string: "\(convexUrl)/api/mutation")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = [
                "path": "codexTokens:remove",
                "args": ["teamSlugOrId": teamId]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                codexStatus = .notLinked
            }
        } catch {
            print("[CodexOAuth] Error unlinking: \(error)")
            errorMessage = "Failed to unlink: \(error.localizedDescription)"
        }
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(43)
            .description
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - JWT Parsing

    private func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }
}

// MARK: - Models

private enum CodexStatus {
    case loading
    case notLinked
    case linked(CodexAccountInfo)
    case error
}

private struct CodexAccountInfo {
    let email: String?
    let accountId: String?
    let planType: String?
    let proxyToken: String
}

struct CodexTokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Int?
}

enum CodexOAuthError: Error {
    case invalidResponse
    case saveFailed(String)
}

// MARK: - OAuth WebView

struct CodexOAuthWebView: View {
    let url: URL
    let codeVerifier: String
    let onSuccess: (CodexTokenResponse) -> Void
    let onError: (String) -> Void

    @State private var isLoading = true

    var body: some View {
        ZStack {
            CodexOAuthWebViewRepresentable(
                url: url,
                codeVerifier: codeVerifier,
                isLoading: $isLoading,
                onSuccess: onSuccess,
                onError: onError
            )

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading OpenAI sign-in...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
    }
}

struct CodexOAuthWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let codeVerifier: String
    @Binding var isLoading: Bool
    let onSuccess: (CodexTokenResponse) -> Void
    let onError: (String) -> Void

    private let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"
    private let redirectUri = "http://localhost:1455/auth/callback"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // Ephemeral session

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: CodexOAuthWebViewRepresentable

        init(_ parent: CodexOAuthWebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            print("[CodexOAuth] Navigation to: \(url)")

            // Intercept localhost redirect
            if url.host == "localhost" && url.port == 1455 {
                print("[CodexOAuth] Intercepted callback URL!")
                decisionHandler(.cancel)

                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

                // Check for error
                if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
                    let desc = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
                    parent.onError("\(error): \(desc ?? "Unknown error")")
                    return
                }

                // Get authorization code
                guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
                    parent.onError("No authorization code received")
                    return
                }

                print("[CodexOAuth] Got code: \(code.prefix(20))...")

                Task {
                    await exchangeCode(code)
                }
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Ignore localhost connection errors - we intercept before they happen
            if (error as NSError).domain == NSURLErrorDomain &&
               (error as NSError).code == NSURLErrorCannotConnectToHost {
                return
            }
            parent.onError("Navigation failed: \(error.localizedDescription)")
        }

        private func exchangeCode(_ code: String) async {
            let tokenURL = URL(string: "\(parent.issuer)/oauth/token")!

            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let body = [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": parent.redirectUri,
                "client_id": parent.clientId,
                "code_verifier": parent.codeVerifier,
            ]

            request.httpBody = body
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run { parent.onError("Invalid response") }
                    return
                }

                if httpResponse.statusCode != 200 {
                    let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                    await MainActor.run { parent.onError("Token exchange failed: \(httpResponse.statusCode) - \(errorText)") }
                    return
                }

                let tokens = try JSONDecoder().decode(CodexTokenResponse.self, from: data)

                await MainActor.run {
                    parent.onSuccess(tokens)
                }

            } catch {
                await MainActor.run {
                    parent.onError("Network error: \(error.localizedDescription)")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        CodexOAuthView()
    }
}
