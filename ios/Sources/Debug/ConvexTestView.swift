import SwiftUI
import Combine
import ConvexMobile

/// Debug view to test Convex auth integration
struct ConvexTestView: View {
    @StateObject private var convex = ConvexClientManager.shared
    @StateObject private var auth = AuthManager.shared
    @State private var result: String = "Not tested yet"
    @State private var isLoading = false
    @State private var logs: [String] = []
    @State private var teamInfo: TeamDebugInfo?

    // Debug login
    @State private var email = "l@l.com"
    @State private var password = "abc123"

    var body: some View {
        List {
            Section("Auth Status") {
                LabeledContent("Stack Auth") {
                    Text(auth.isAuthenticated ? "Authenticated" : "Not authenticated")
                        .foregroundStyle(auth.isAuthenticated ? .green : .red)
                }
                LabeledContent("Convex Auth") {
                    Text(convex.isAuthenticated ? "Authenticated" : "Not authenticated")
                        .foregroundStyle(convex.isAuthenticated ? .green : .red)
                }
                if let user = auth.currentUser {
                    LabeledContent("User Email") {
                        Text(user.primaryEmail ?? "N/A")
                            .font(.caption)
                    }
                    LabeledContent("User ID") {
                        Text(user.id)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }

            Section("Team Info") {
                if let info = teamInfo {
                    LabeledContent("Team Name") {
                        Text(info.displayName)
                            .font(.caption)
                    }
                    LabeledContent("Team Slug") {
                        Text(info.slug)
                            .font(.caption)
                    }
                    LabeledContent("Convex Team ID") {
                        Text(info.convexTeamId)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    LabeledContent("Stack Team ID") {
                        Text(info.stackTeamId)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                } else {
                    Text("Loading team info...")
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Team Info") {
                    Task { await loadTeamInfo() }
                }
            }

            Section("Debug Tools") {
                // Show token info for debugging
                Button("Show Token Info") {
                    Task {
                        do {
                            let token = try await auth.getAccessToken()
                            addLog("Token length: \(token.count)")
                            addLog("Token starts with: \(String(token.prefix(20)))...")
                            // Check if it looks like a JWT (has 3 parts separated by dots)
                            let parts = token.split(separator: ".")
                            addLog("Token parts: \(parts.count) (JWT should have 3)")
                            if parts.count == 3, let payload = decodeJWTPayload(String(parts[1])) {
                                addLog("JWT payload: \(payload)")
                            }
                        } catch {
                            addLog("Failed to get token: \(error)")
                        }
                    }
                }
            }

            Section("Debug Login (Password)") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                SecureField("Password", text: $password)
                Button {
                    Task { await debugLogin() }
                } label: {
                    HStack {
                        Text("Sign In with Password")
                        Spacer()
                        if auth.isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(auth.isLoading || email.isEmpty || password.isEmpty)
            }

            Section("Test Query") {
                Button {
                    Task { await testQuery() }
                } label: {
                    HStack {
                        Text("Call teams:listTeamMemberships")
                        Spacer()
                        if isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoading)

                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.contains("Error") ? .red : .secondary)
            }

            Section("Actions") {
                Button("Sync Convex Auth") {
                    addLog("Syncing Convex auth...")
                    addLog("Before sync: Convex auth = \(convex.isAuthenticated)")
                    Task {
                        let syncResult = await convex.syncAuth()
                        addLog("Sync result: \(syncResult)")
                        addLog("After sync: Convex auth = \(convex.isAuthenticated)")
                        do {
                            let token = try await auth.getAccessToken()
                            addLog("Access token len: \(token.count)")
                            let parts = token.split(separator: ".")
                            if parts.count == 3, let payload = decodeJWTPayload(String(parts[1])) {
                                addLog("JWT: \(payload)")
                            }
                        } catch {
                            addLog("⚠️ Failed to read access token: \(error)")
                        }
                    }
                }

                Button("Clear Convex Auth") {
                    Task {
                        await convex.clearAuth()
                        addLog("Convex auth cleared")
                    }
                }
                .foregroundStyle(.orange)

                Button("Sign Out (Full)") {
                    Task {
                        await auth.signOut()
                        addLog("Signed out completely")
                    }
                }
                .foregroundStyle(.red)
            }

            Section("Debug Logs") {
                if logs.isEmpty {
                    Text("No logs yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logs.indices, id: \.self) { i in
                        Text(logs[i])
                            .font(.caption2)
                            .fontDesign(.monospaced)
                    }
                }
                Button("Clear Logs") {
                    logs.removeAll()
                }
            }
        }
        .navigationTitle("Convex Test")
        .onAppear {
            Task { await loadTeamInfo() }
        }
    }

    func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
    }

    func loadTeamInfo() async {
        guard convex.isAuthenticated else {
            addLog("Cannot load team info: not authenticated")
            return
        }

        addLog("Loading team info...")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var cancellable: AnyCancellable?
            cancellable = convex.client
                .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
                .first()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            self.addLog("Failed to load team info: \(error)")
                        }
                        cancellable?.cancel()
                        continuation.resume()
                    },
                    receiveValue: { memberships in
                        if let first = memberships.first {
                            self.teamInfo = TeamDebugInfo(
                                displayName: first.team.displayName ?? "Unknown",
                                slug: first.team.slug ?? "unknown",
                                convexTeamId: first.team._id.rawValue,
                                stackTeamId: first.team.teamId
                            )
                            self.addLog("Team: \(first.team.displayName ?? "Unknown") (\(first.team.slug ?? "?"))")
                            self.addLog("Convex ID: \(first.team._id.rawValue)")
                        } else {
                            self.addLog("No team memberships found")
                        }
                    }
                )
        }
    }

    func debugLogin() async {
        addLog("Starting password login for \(email)...")
        do {
            try await auth.signInWithPassword(email: email, password: password)
            addLog("Login successful!")
            addLog("Stack auth: \(auth.isAuthenticated), Convex: \(convex.isAuthenticated)")
        } catch {
            addLog("Login failed: \(error)")
        }
    }

    func testQuery() async {
        isLoading = true
        addLog("Calling teams:listTeamMemberships...")

        var cancellable: AnyCancellable?

        cancellable = convex.client
            .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
            .first()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        break
                    case .failure(let error):
                        let errorMsg = parseConvexError(error)
                        self.result = "Error: \(errorMsg)"
                        self.addLog("Query failed: \(errorMsg)")
                    }
                    self.isLoading = false
                    cancellable?.cancel()
                },
                receiveValue: { memberships in
                    self.result = "Success! Found \(memberships.count) team(s)"
                    self.addLog("Query success: \(memberships.count) teams")
                }
            )
    }

    func parseConvexError(_ error: ClientError) -> String {
        switch error {
        case .ConvexError(let data):
            // Try to extract readable message from JSON
            if let jsonData = data.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let message = json["message"] as? String {
                return message
            }
            // Clean up the raw string
            return data.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\"", with: "")
        case .ServerError(let msg):
            return "Server: \(msg)"
        case .InternalError(let msg):
            return "Internal: \(msg)"
        @unknown default:
            return "Unknown error"
        }
    }
}

// Extended team info for debug display
struct TeamDebugInfo {
    let displayName: String
    let slug: String
    let convexTeamId: String  // Convex _id
    let stackTeamId: String   // Stack Auth teamId
}

// JWT decoder helper
func decodeJWTPayload(_ base64: String) -> String? {
    // Add padding if needed
    var base64 = base64
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
        base64.append("=")
    }
    guard let data = Data(base64Encoded: base64),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    // Extract key fields
    let iss = json["iss"] as? String ?? "?"
    let sub = json["sub"] as? String ?? "?"
    let exp = json["exp"] as? Int ?? 0
    let expDate = Date(timeIntervalSince1970: TimeInterval(exp))
    return "iss: \(iss)\nsub: \(sub)\nexp: \(expDate)"
}

#Preview {
    NavigationStack {
        ConvexTestView()
    }
}
