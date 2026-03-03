import SwiftUI
import AppKit
import AuthenticationServices
import StackAuth

@main
struct StackAuthMacOSApp: App {
    init() {
        // Required for SwiftUI apps run from command line (not .app bundle)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @State private var viewModel = SDKTestViewModel()
    
    var body: some View {
        HSplitView {
            // Left: Navigation + Controls
            NavigationSplitView {
                List(selection: $viewModel.selectedSection) {
                    Section("Configuration") {
                        Label("Settings", systemImage: "gear")
                            .tag(TestSection.settings)
                    }
                    
                    Section("Client App") {
                        Label("Authentication", systemImage: "person.badge.key")
                            .tag(TestSection.authentication)
                        Label("User Management", systemImage: "person.crop.circle")
                            .tag(TestSection.userManagement)
                        Label("Teams", systemImage: "person.3")
                            .tag(TestSection.teams)
                        Label("Contact Channels", systemImage: "envelope")
                            .tag(TestSection.contactChannels)
                        Label("OAuth", systemImage: "link")
                            .tag(TestSection.oauth)
                        Label("Tokens", systemImage: "key")
                            .tag(TestSection.tokens)
                    }
                    
                    Section("Server App") {
                        Label("Server Users", systemImage: "person.badge.shield.checkmark")
                            .tag(TestSection.serverUsers)
                        Label("Server Teams", systemImage: "person.3.fill")
                            .tag(TestSection.serverTeams)
                        Label("Sessions", systemImage: "rectangle.stack.person.crop")
                            .tag(TestSection.sessions)
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Stack Auth SDK")
            } detail: {
                Group {
                    switch viewModel.selectedSection {
                    case .settings:
                        SettingsView(viewModel: viewModel)
                    case .authentication:
                        AuthenticationView(viewModel: viewModel)
                    case .userManagement:
                        UserManagementView(viewModel: viewModel)
                    case .teams:
                        TeamsView(viewModel: viewModel)
                    case .contactChannels:
                        ContactChannelsView(viewModel: viewModel)
                    case .oauth:
                        OAuthView(viewModel: viewModel)
                    case .tokens:
                        TokensView(viewModel: viewModel)
                    case .serverUsers:
                        ServerUsersView(viewModel: viewModel)
                    case .serverTeams:
                        ServerTeamsView(viewModel: viewModel)
                    case .sessions:
                        SessionsView(viewModel: viewModel)
                    }
                }
                .frame(minWidth: 400)
            }
            .frame(minWidth: 500)
            
            // Right: Log Panel (always visible)
            LogPanelView(viewModel: viewModel)
                .frame(minWidth: 400, idealWidth: 500)
        }
        .frame(minWidth: 1100, minHeight: 700)
    }
}

// MARK: - Log Panel View

struct LogPanelView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var selectedLogId: UUID?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SDK Activity Log")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.logs.count) entries")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Button("Clear") {
                    viewModel.clearLogs()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Log entries
            if viewModel.logs.isEmpty {
                VStack {
                    Spacer()
                    Text("No activity yet")
                        .foregroundStyle(.secondary)
                    Text("Click buttons on the left to test SDK functions")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    List(viewModel.logs, selection: $selectedLogId) { entry in
                        LogEntryView(entry: entry)
                            .id(entry.id)
                            .contextMenu {
                                Button("Copy Message") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.message, forType: .string)
                                }
                                Button("Copy Full Details") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.fullDescription, forType: .string)
                                }
                                if let details = entry.details {
                                    Button("Copy Details JSON") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(details, forType: .string)
                                    }
                                }
                            }
                    }
                    .listStyle(.plain)
                    .onChange(of: viewModel.logs.first?.id) { _, newId in
                        if let id = newId {
                            withAnimation {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // Selected log details
            if let selectedId = selectedLogId,
               let entry = viewModel.logs.first(where: { $0.id == selectedId }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Details")
                            .font(.caption.bold())
                        Spacer()
                        Button("Copy All") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.fullDescription, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    
                    ScrollView {
                        Text(entry.fullDescription)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(height: 150)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct LogEntryView: View {
    let entry: LogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                // Icon
                Image(systemName: entry.type.icon)
                    .foregroundStyle(entry.type.color)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    // Function call
                    if let function = entry.function {
                        Text(function)
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(.primary)
                    }
                    
                    // Message
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(entry.type.color)
                        .lineLimit(3)
                    
                    // Timestamp
                    Text(entry.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Test Sections

enum TestSection: String, CaseIterable, Identifiable {
    case settings
    case authentication
    case userManagement
    case teams
    case contactChannels
    case oauth
    case tokens
    case serverUsers
    case serverTeams
    case sessions
    
    var id: String { rawValue }
}

// MARK: - View Model

@Observable
class SDKTestViewModel {
    // Configuration
    var baseUrl = "http://localhost:8102"
    var projectId = "internal"
    var publishableClientKey = "this-publishable-client-key-is-for-local-development-only"
    var secretServerKey = "this-secret-server-key-is-for-local-development-only"
    
    // State
    var selectedSection: TestSection = .settings
    var logs: [LogEntry] = []
    var isLoading = false
    
    // Apps (lazy initialized)
    private var _clientApp: StackClientApp?
    private var _serverApp: StackServerApp?
    
    var clientApp: StackClientApp {
        if _clientApp == nil {
            _clientApp = StackClientApp(
                projectId: projectId,
                publishableClientKey: publishableClientKey,
                baseUrl: baseUrl,
                tokenStore: .memory,
                noAutomaticPrefetch: true
            )
        }
        return _clientApp!
    }
    
    var serverApp: StackServerApp {
        if _serverApp == nil {
            _serverApp = StackServerApp(
                projectId: projectId,
                publishableClientKey: publishableClientKey,
                secretServerKey: secretServerKey,
                baseUrl: baseUrl
            )
        }
        return _serverApp!
    }
    
    func resetApps() {
        _clientApp = nil
        _serverApp = nil
        logCall("resetApps()", result: "Apps reset with new configuration")
    }
    
    // Enhanced logging
    func logCall(_ function: String, params: String? = nil, result: String) {
        let message = result
        let details = params.map { "Parameters:\n\($0)\n\nResult:\n\(result)" } ?? "Result:\n\(result)"
        let entry = LogEntry(
            function: function,
            message: message,
            details: details,
            type: .success,
            timestamp: Date()
        )
        logs.insert(entry, at: 0)
        trimLogs()
    }
    
    func logCall(_ function: String, params: String? = nil, error: Error) {
        let errorStr = String(describing: error)
        let message = errorStr
        let details = params.map { "Parameters:\n\($0)\n\nError:\n\(errorStr)" } ?? "Error:\n\(errorStr)"
        let entry = LogEntry(
            function: function,
            message: message,
            details: details,
            type: .error,
            timestamp: Date()
        )
        logs.insert(entry, at: 0)
        trimLogs()
    }
    
    func logInfo(_ function: String, message: String, details: String? = nil) {
        let entry = LogEntry(
            function: function,
            message: message,
            details: details ?? message,
            type: .info,
            timestamp: Date()
        )
        logs.insert(entry, at: 0)
        trimLogs()
    }
    
    private func trimLogs() {
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }
    
    func clearLogs() {
        logs.removeAll()
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let function: String?
    let message: String
    let details: String?
    let type: LogType
    let timestamp: Date
    
    var fullDescription: String {
        var parts: [String] = []
        parts.append("Time: \(timestamp.formatted(date: .omitted, time: .standard))")
        if let function = function {
            parts.append("Function: \(function)")
        }
        parts.append("Status: \(type.rawValue)")
        parts.append("Message: \(message)")
        if let details = details {
            parts.append("\nDetails:\n\(details)")
        }
        return parts.joined(separator: "\n")
    }
}

enum LogType: String {
    case info = "INFO"
    case success = "SUCCESS"
    case error = "ERROR"
    
    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Object Serialization Helpers

/// Converts any value to a pretty-printed string representation
func formatValue(_ value: Any?, indent: Int = 0) -> String {
    let spaces = String(repeating: "  ", count: indent)
    
    guard let value = value else { return "nil" }
    
    switch value {
    case let str as String:
        return "\"\(str)\""
    case let bool as Bool:
        return bool ? "true" : "false"
    case let num as NSNumber:
        return "\(num)"
    case let date as Date:
        return "\"\(date.formatted())\""
    case let url as URL:
        return "\"\(url.absoluteString)\""
    case let dict as [String: Any]:
        if dict.isEmpty { return "{}" }
        var lines = ["{"]
        for (key, val) in dict.sorted(by: { $0.key < $1.key }) {
            lines.append("\(spaces)  \(key): \(formatValue(val, indent: indent + 1))")
        }
        lines.append("\(spaces)}")
        return lines.joined(separator: "\n")
    case let arr as [Any]:
        if arr.isEmpty { return "[]" }
        var lines = ["["]
        for item in arr {
            lines.append("\(spaces)  \(formatValue(item, indent: indent + 1)),")
        }
        lines.append("\(spaces)]")
        return lines.joined(separator: "\n")
    default:
        return String(describing: value)
    }
}

/// Serializes a CurrentUser to a dictionary for logging
func serializeCurrentUser(_ user: CurrentUser) async -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["id"] = await user.id
    dict["displayName"] = await user.displayName
    dict["primaryEmail"] = await user.primaryEmail
    dict["primaryEmailVerified"] = await user.primaryEmailVerified
    dict["profileImageUrl"] = await user.profileImageUrl
    dict["signedUpAt"] = await user.signedUpAt.formatted()
    dict["clientMetadata"] = await user.clientMetadata
    dict["clientReadOnlyMetadata"] = await user.clientReadOnlyMetadata
    dict["hasPassword"] = await user.hasPassword
    dict["emailAuthEnabled"] = await user.emailAuthEnabled
    dict["otpAuthEnabled"] = await user.otpAuthEnabled
    dict["passkeyAuthEnabled"] = await user.passkeyAuthEnabled
    dict["isMultiFactorRequired"] = await user.isMultiFactorRequired
    dict["isAnonymous"] = await user.isAnonymous
    dict["isRestricted"] = await user.isRestricted
    if let reason = await user.restrictedReason {
        dict["restrictedReason"] = String(describing: reason)
    }
    let providers = await user.oauthProviders
    if !providers.isEmpty {
        dict["oauthProviders"] = providers.map { ["id": $0.id] }
    }
    if let team = await user.selectedTeam {
        dict["selectedTeam"] = ["id": team.id, "displayName": await team.displayName]
    }
    return dict
}

/// Serializes a ServerUser to a dictionary for logging
func serializeServerUser(_ user: ServerUser) async -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["id"] = user.id
    dict["displayName"] = await user.displayName
    dict["primaryEmail"] = await user.primaryEmail
    dict["primaryEmailVerified"] = await user.primaryEmailVerified
    dict["profileImageUrl"] = await user.profileImageUrl
    dict["signedUpAt"] = await user.signedUpAt.formatted()
    if let lastActiveAt = await user.lastActiveAt {
        dict["lastActiveAt"] = lastActiveAt.formatted()
    }
    dict["clientMetadata"] = await user.clientMetadata
    dict["clientReadOnlyMetadata"] = await user.clientReadOnlyMetadata
    dict["serverMetadata"] = await user.serverMetadata
    dict["hasPassword"] = await user.hasPassword
    dict["emailAuthEnabled"] = await user.emailAuthEnabled
    dict["otpAuthEnabled"] = await user.otpAuthEnabled
    dict["passkeyAuthEnabled"] = await user.passkeyAuthEnabled
    dict["isMultiFactorRequired"] = await user.isMultiFactorRequired
    return dict
}

/// Serializes a Team to a dictionary for logging
func serializeTeam(_ team: Team) async -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["id"] = team.id
    dict["displayName"] = await team.displayName
    dict["profileImageUrl"] = await team.profileImageUrl
    dict["clientMetadata"] = await team.clientMetadata
    dict["clientReadOnlyMetadata"] = await team.clientReadOnlyMetadata
    return dict
}

/// Serializes a ServerTeam to a dictionary for logging
func serializeServerTeam(_ team: ServerTeam) async -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["id"] = team.id
    dict["displayName"] = await team.displayName
    dict["profileImageUrl"] = await team.profileImageUrl
    dict["clientMetadata"] = await team.clientMetadata
    dict["clientReadOnlyMetadata"] = await team.clientReadOnlyMetadata
    dict["serverMetadata"] = await team.serverMetadata
    dict["createdAt"] = await team.createdAt.formatted()
    return dict
}

/// Serializes a ContactChannel to a dictionary for logging
func serializeContactChannel(_ channel: ContactChannel) async -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["id"] = channel.id
    dict["type"] = await channel.type
    dict["value"] = await channel.value
    dict["isPrimary"] = await channel.isPrimary
    dict["isVerified"] = await channel.isVerified
    dict["usedForAuth"] = await channel.usedForAuth
    return dict
}

/// Serializes a TeamUser to a dictionary for logging
func serializeTeamUser(_ user: TeamUser) -> [String: Any] {
    var dict: [String: Any] = [:]
    dict["id"] = user.id
    dict["teamProfile"] = [
        "displayName": user.teamProfile.displayName as Any,
        "profileImageUrl": user.teamProfile.profileImageUrl as Any
    ]
    return dict
}

/// Formats a dictionary as a pretty object string
func formatObject(_ name: String, _ dict: [String: Any]) -> String {
    var lines = ["\(name) {"]
    for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
        let formattedValue = formatValue(value, indent: 1)
        if formattedValue.contains("\n") {
            lines.append("  \(key): \(formattedValue)")
        } else {
            lines.append("  \(key): \(formattedValue)")
        }
    }
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// Formats an array of dictionaries as a pretty array string
func formatObjectArray(_ name: String, _ items: [[String: Any]]) -> String {
    if items.isEmpty {
        return "\(name) []"
    }
    var lines = ["\(name) ["]
    for (index, item) in items.enumerated() {
        lines.append("  [\(index)] {")
        for (key, value) in item.sorted(by: { $0.key < $1.key }) {
            lines.append("    \(key): \(formatValue(value, indent: 2))")
        }
        lines.append("  }")
    }
    lines.append("]")
    lines.append("Total: \(items.count) items")
    return lines.joined(separator: "\n")
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var viewModel: SDKTestViewModel
    
    var body: some View {
        Form {
            Section("API Configuration") {
                TextField("Base URL", text: $viewModel.baseUrl)
                TextField("Project ID", text: $viewModel.projectId)
                TextField("Publishable Client Key", text: $viewModel.publishableClientKey)
                SecureField("Secret Server Key", text: $viewModel.secretServerKey)
                
                Button("Apply Configuration") {
                    viewModel.resetApps()
                }
                .buttonStyle(.borderedProminent)
            }
            
            Section("Quick Actions") {
                Button("Test Connection") {
                    Task { await testConnection() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
    
    func testConnection() async {
        viewModel.logInfo("testConnection()", message: "Testing connection to \(viewModel.baseUrl)...")
        do {
            let project = try await viewModel.clientApp.getProject()
            viewModel.logCall(
                "getProject()",
                result: "Connected! Project ID: \(project.id)"
            )
        } catch {
            viewModel.logCall("getProject()", error: error)
        }
    }
}

// MARK: - Authentication View

struct AuthenticationView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var email = ""
    @State private var password = "TestPassword123!"
    @State private var currentUser: String?
    
    var body: some View {
        Form {
            Section("Credentials") {
                TextField("Email", text: $email)
                SecureField("Password", text: $password)
                
                Button("Generate Random Email") {
                    email = "test-\(UUID().uuidString.lowercased())@example.com"
                    viewModel.logInfo("generateEmail()", message: "Generated: \(email)")
                }
            }
            
            Section("Sign Up") {
                Button("signUpWithCredential(email, password)") {
                    Task { await signUp() }
                }
                .disabled(email.isEmpty || password.isEmpty)
            }
            
            Section("Sign In") {
                Button("signInWithCredential(email, password)") {
                    Task { await signIn() }
                }
                .disabled(email.isEmpty || password.isEmpty)
                
                Button("signInWithCredential(email, WRONG_PASSWORD)") {
                    Task { await signInWrongPassword() }
                }
                .disabled(email.isEmpty)
            }
            
            Section("Sign Out") {
                Button("signOut()") {
                    Task { await signOut() }
                }
            }
            
            Section("Current User") {
                Button("getUser()") {
                    Task { await getUser() }
                }
                
                Button("getUser(or: .throw)") {
                    Task { await getUserOrThrow() }
                }
                
                if let user = currentUser {
                    Text(user)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Authentication")
    }
    
    func signUp() async {
        let params = "email: \"\(email)\"\npassword: \"\(password)\""
        viewModel.logInfo("signUpWithCredential()", message: "Calling...", details: params)
        
        do {
            try await viewModel.clientApp.signUpWithCredential(email: email, password: password)
            viewModel.logCall(
                "signUpWithCredential(email, password)",
                params: params,
                result: "Success! User signed up."
            )
            await getUser()
        } catch {
            viewModel.logCall("signUpWithCredential(email, password)", params: params, error: error)
        }
    }
    
    func signIn() async {
        let params = "email: \"\(email)\"\npassword: \"\(password)\""
        viewModel.logInfo("signInWithCredential()", message: "Calling...", details: params)
        
        do {
            try await viewModel.clientApp.signInWithCredential(email: email, password: password)
            viewModel.logCall(
                "signInWithCredential(email, password)",
                params: params,
                result: "Success! User signed in."
            )
            await getUser()
        } catch {
            viewModel.logCall("signInWithCredential(email, password)", params: params, error: error)
        }
    }
    
    func signInWrongPassword() async {
        let params = "email: \"\(email)\"\npassword: \"WrongPassword!\""
        viewModel.logInfo("signInWithCredential()", message: "Calling with wrong password...", details: params)
        
        do {
            try await viewModel.clientApp.signInWithCredential(email: email, password: "WrongPassword!")
            viewModel.logCall(
                "signInWithCredential(email, WRONG)",
                params: params,
                result: "Unexpected success (should have failed)"
            )
        } catch let error as EmailPasswordMismatchError {
            viewModel.logCall(
                "signInWithCredential(email, WRONG)",
                params: params,
                result: "Expected error caught!\nType: EmailPasswordMismatchError\nCode: \(error.code)\nMessage: \(error.message)"
            )
        } catch {
            viewModel.logCall("signInWithCredential(email, WRONG)", params: params, error: error)
        }
    }
    
    func signOut() async {
        viewModel.logInfo("signOut()", message: "Calling...")
        
        do {
            try await viewModel.clientApp.signOut()
            viewModel.logCall("signOut()", result: "Success! User signed out.")
            currentUser = nil
        } catch {
            viewModel.logCall("signOut()", error: error)
        }
    }
    
    func getUser() async {
        viewModel.logInfo("getUser()", message: "Calling...")
        
        do {
            let user = try await viewModel.clientApp.getUser()
            if let user = user {
                let dict = await serializeCurrentUser(user)
                currentUser = "ID: \(dict["id"] ?? "")\nEmail: \(dict["primaryEmail"] ?? "nil")"
                viewModel.logCall(
                    "getUser()",
                    result: formatObject("CurrentUser", dict)
                )
            } else {
                currentUser = nil
                viewModel.logCall("getUser()", result: "nil (no user signed in)")
            }
        } catch {
            viewModel.logCall("getUser()", error: error)
        }
    }
    
    func getUserOrThrow() async {
        viewModel.logInfo("getUser(or: .throw)", message: "Calling...")
        
        do {
            let user = try await viewModel.clientApp.getUser(or: .throw)
            if let user = user {
                let dict = await serializeCurrentUser(user)
                viewModel.logCall("getUser(or: .throw)", result: formatObject("CurrentUser", dict))
            } else {
                viewModel.logCall("getUser(or: .throw)", result: "nil (unexpected)")
            }
        } catch let error as UserNotSignedInError {
            viewModel.logCall(
                "getUser(or: .throw)",
                result: "Expected error caught!\nType: UserNotSignedInError\nCode: \(error.code)\nMessage: \(error.message)"
            )
        } catch {
            viewModel.logCall("getUser(or: .throw)", error: error)
        }
    }
}

// MARK: - User Management View

struct UserManagementView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var displayName = ""
    @State private var metadataKey = "theme"
    @State private var metadataValue = "dark"
    @State private var oldPassword = "TestPassword123!"
    @State private var newPassword = "NewPassword456!"
    
    var body: some View {
        Form {
            Section("Display Name") {
                TextField("Display Name", text: $displayName)
                
                Button("user.setDisplayName(displayName)") {
                    Task { await setDisplayName() }
                }
                .disabled(displayName.isEmpty)
            }
            
            Section("Client Metadata") {
                TextField("Key", text: $metadataKey)
                TextField("Value", text: $metadataValue)
                
                Button("user.update(clientMetadata: {key: value})") {
                    Task { await updateMetadata() }
                }
            }
            
            Section("Password") {
                SecureField("Old Password", text: $oldPassword)
                SecureField("New Password", text: $newPassword)
                
                Button("user.updatePassword(oldPassword, newPassword)") {
                    Task { await updatePassword() }
                }
                
                Button("user.updatePassword(WRONG_OLD, newPassword)") {
                    Task { await updatePasswordWrong() }
                }
            }
            
            Section("Token Info") {
                Button("getAccessToken()") {
                    Task { await getAccessToken() }
                }
                
                Button("getRefreshToken()") {
                    Task { await getRefreshToken() }
                }
                
                Button("getAuthHeaders()") {
                    Task { await getAuthHeaders() }
                }
                
                Button("getPartialUser()") {
                    Task { await getPartialUser() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("User Management")
    }
    
    func setDisplayName() async {
        let params = "displayName: \"\(displayName)\""
        viewModel.logInfo("setDisplayName()", message: "Calling...", details: params)
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("setDisplayName()", result: "Error: No user signed in")
                return
            }
            try await user.setDisplayName(displayName)
            let dict = await serializeCurrentUser(user)
            viewModel.logCall(
                "user.setDisplayName(displayName)",
                params: params,
                result: "Success!\n\n" + formatObject("CurrentUser (updated)", dict)
            )
        } catch {
            viewModel.logCall("user.setDisplayName(displayName)", params: params, error: error)
        }
    }
    
    func updateMetadata() async {
        let params = "clientMetadata: {\"\(metadataKey)\": \"\(metadataValue)\"}"
        viewModel.logInfo("update(clientMetadata:)", message: "Calling...", details: params)
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("update(clientMetadata:)", result: "Error: No user signed in")
                return
            }
            try await user.update(clientMetadata: [metadataKey: metadataValue])
            let dict = await serializeCurrentUser(user)
            viewModel.logCall(
                "user.update(clientMetadata:)",
                params: params,
                result: "Success!\n\n" + formatObject("CurrentUser (updated)", dict)
            )
        } catch {
            viewModel.logCall("user.update(clientMetadata:)", params: params, error: error)
        }
    }
    
    func updatePassword() async {
        let params = "oldPassword: \"\(oldPassword)\"\nnewPassword: \"\(newPassword)\""
        viewModel.logInfo("updatePassword()", message: "Calling...", details: params)
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("updatePassword()", result: "Error: No user signed in")
                return
            }
            try await user.updatePassword(oldPassword: oldPassword, newPassword: newPassword)
            viewModel.logCall(
                "user.updatePassword(old, new)",
                params: params,
                result: "Success! Password updated."
            )
        } catch {
            viewModel.logCall("user.updatePassword(old, new)", params: params, error: error)
        }
    }
    
    func updatePasswordWrong() async {
        let params = "oldPassword: \"WrongPassword!\"\nnewPassword: \"\(newPassword)\""
        viewModel.logInfo("updatePassword()", message: "Calling with wrong old password...", details: params)
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("updatePassword()", result: "Error: No user signed in")
                return
            }
            try await user.updatePassword(oldPassword: "WrongPassword!", newPassword: newPassword)
            viewModel.logCall(
                "user.updatePassword(WRONG, new)",
                params: params,
                result: "Unexpected success"
            )
        } catch let error as PasswordConfirmationMismatchError {
            viewModel.logCall(
                "user.updatePassword(WRONG, new)",
                params: params,
                result: "Expected error caught!\nType: PasswordConfirmationMismatchError\nCode: \(error.code)\nMessage: \(error.message)"
            )
        } catch {
            viewModel.logCall("user.updatePassword(WRONG, new)", params: params, error: error)
        }
    }
    
    func getAccessToken() async {
        viewModel.logInfo("getAccessToken()", message: "Calling...")
        
        let token = await viewModel.clientApp.getAccessToken()
        if let token = token {
            let parts = token.split(separator: ".")
            viewModel.logCall(
                "getAccessToken()",
                result: "JWT Token (\(parts.count) parts, \(token.count) chars):\n\(token)"
            )
        } else {
            viewModel.logCall("getAccessToken()", result: "nil (not signed in)")
        }
    }
    
    func getRefreshToken() async {
        viewModel.logInfo("getRefreshToken()", message: "Calling...")
        
        let token = await viewModel.clientApp.getRefreshToken()
        if let token = token {
            viewModel.logCall(
                "getRefreshToken()",
                result: "Refresh Token (\(token.count) chars):\n\(token)"
            )
        } else {
            viewModel.logCall("getRefreshToken()", result: "nil (not signed in)")
        }
    }
    
    func getAuthHeaders() async {
        viewModel.logInfo("getAuthHeaders()", message: "Calling...")
        
        let headers = await viewModel.clientApp.getAuthHeaders()
        var result = "Headers:\n"
        for (key, value) in headers {
            result += "  \(key): \(value)\n"
        }
        viewModel.logCall("getAuthHeaders()", result: result)
    }
    
    func getPartialUser() async {
        viewModel.logInfo("getPartialUser()", message: "Calling...")
        
        let user = await viewModel.clientApp.getPartialUser()
        if let user = user {
            viewModel.logCall(
                "getPartialUser()",
                result: "PartialUser {\n  id: \"\(user.id)\"\n  primaryEmail: \"\(user.primaryEmail ?? "nil")\"\n}"
            )
        } else {
            viewModel.logCall("getPartialUser()", result: "nil (not signed in)")
        }
    }
}

// MARK: - Teams View

struct TeamsView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var teamName = ""
    @State private var teams: [(id: String, name: String)] = []
    @State private var selectedTeamId = ""
    
    var body: some View {
        Form {
            Section("Create Team") {
                TextField("Team Name", text: $teamName)
                
                Button("Generate Random Name") {
                    teamName = "Team \(UUID().uuidString.prefix(8))"
                    viewModel.logInfo("generateTeamName()", message: "Generated: \(teamName)")
                }
                
                Button("user.createTeam(displayName: teamName)") {
                    Task { await createTeam() }
                }
                .disabled(teamName.isEmpty)
            }
            
            Section("List Teams") {
                Button("user.listTeams()") {
                    Task { await listTeams() }
                }
                
                ForEach(teams, id: \.id) { team in
                    HStack {
                        Text(team.name)
                        Spacer()
                        Text(team.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Select") {
                            selectedTeamId = team.id
                            viewModel.logInfo("selectTeam()", message: "Selected team: \(team.id)")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            
            Section("Team Operations") {
                TextField("Team ID", text: $selectedTeamId)
                
                Button("user.getTeam(id: teamId)") {
                    Task { await getTeam() }
                }
                .disabled(selectedTeamId.isEmpty)
                
                Button("team.listUsers()") {
                    Task { await listTeamMembers() }
                }
                .disabled(selectedTeamId.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Teams")
    }
    
    func createTeam() async {
        let params = "displayName: \"\(teamName)\""
        viewModel.logInfo("createTeam()", message: "Calling...", details: params)
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("createTeam()", result: "Error: No user signed in")
                return
            }
            let team = try await user.createTeam(displayName: teamName)
            let dict = await serializeTeam(team)
            viewModel.logCall(
                "user.createTeam(displayName:)",
                params: params,
                result: formatObject("Team", dict)
            )
            await listTeams()
        } catch {
            viewModel.logCall("user.createTeam(displayName:)", params: params, error: error)
        }
    }
    
    func listTeams() async {
        viewModel.logInfo("listTeams()", message: "Calling...")
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("listTeams()", result: "Error: No user signed in")
                return
            }
            let teamsList = try await user.listTeams()
            var results: [(id: String, name: String)] = []
            var dicts: [[String: Any]] = []
            for team in teamsList {
                let dict = await serializeTeam(team)
                dicts.append(dict)
                results.append((id: team.id, name: dict["displayName"] as? String ?? ""))
            }
            teams = results
            viewModel.logCall("user.listTeams()", result: formatObjectArray("Team", dicts))
        } catch {
            viewModel.logCall("user.listTeams()", error: error)
        }
    }
    
    func getTeam() async {
        let params = "id: \"\(selectedTeamId)\""
        viewModel.logInfo("getTeam()", message: "Calling...", details: params)
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("getTeam()", result: "Error: No user signed in")
                return
            }
            let team = try await user.getTeam(id: selectedTeamId)
            if let team = team {
                let dict = await serializeTeam(team)
                viewModel.logCall(
                    "user.getTeam(id:)",
                    params: params,
                    result: formatObject("Team", dict)
                )
            } else {
                viewModel.logCall("user.getTeam(id:)", params: params, result: "nil (team not found or not a member)")
            }
        } catch {
            viewModel.logCall("user.getTeam(id:)", params: params, error: error)
        }
    }
    
    func listTeamMembers() async {
        let params = "teamId: \"\(selectedTeamId)\""
        viewModel.logInfo("team.listUsers()", message: "Calling...", details: params)
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("team.listUsers()", result: "Error: No user signed in")
                return
            }
            guard let team = try await user.getTeam(id: selectedTeamId) else {
                viewModel.logCall("team.listUsers()", params: params, result: "Error: Team not found")
                return
            }
            let members = try await team.listUsers()
            let dicts = members.map { serializeTeamUser($0) }
            viewModel.logCall("team.listUsers()", params: params, result: formatObjectArray("TeamUser", dicts))
        } catch {
            viewModel.logCall("team.listUsers()", params: params, error: error)
        }
    }
}

// MARK: - Contact Channels View

struct ContactChannelsView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var channels: [(id: String, value: String, isPrimary: Bool, isVerified: Bool)] = []
    
    var body: some View {
        Form {
            Section("Contact Channels") {
                Button("user.listContactChannels()") {
                    Task { await listChannels() }
                }
                
                ForEach(channels, id: \.id) { channel in
                    HStack {
                        Text(channel.value)
                        Spacer()
                        if channel.isPrimary {
                            Text("Primary")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        if channel.isVerified {
                            Text("Verified")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Contact Channels")
    }
    
    func listChannels() async {
        viewModel.logInfo("listContactChannels()", message: "Calling...")
        
        do {
            guard let user = try await viewModel.clientApp.getUser() else {
                viewModel.logCall("listContactChannels()", result: "Error: No user signed in")
                return
            }
            let channelsList = try await user.listContactChannels()
            var results: [(id: String, value: String, isPrimary: Bool, isVerified: Bool)] = []
            var dicts: [[String: Any]] = []
            for channel in channelsList {
                let dict = await serializeContactChannel(channel)
                dicts.append(dict)
                results.append((
                    id: channel.id,
                    value: dict["value"] as? String ?? "",
                    isPrimary: dict["isPrimary"] as? Bool ?? false,
                    isVerified: dict["isVerified"] as? Bool ?? false
                ))
            }
            channels = results
            viewModel.logCall("user.listContactChannels()", result: formatObjectArray("ContactChannel", dicts))
        } catch {
            viewModel.logCall("user.listContactChannels()", error: error)
        }
    }
}

// MARK: - OAuth Presentation Context Provider

class MacOSPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - OAuth View

struct OAuthView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var provider = "google"
    @State private var redirectUrl = "stack-auth-mobile-oauth-url://success"
    @State private var errorRedirectUrl = "stack-auth-mobile-oauth-url://error"
    @State private var isSigningIn = false
    private let presentationProvider = MacOSPresentationContextProvider()
    
    var body: some View {
        Form {
            Section("Sign In with Apple (Native)") {
                Button {
                    Task { await signInWithApple() }
                } label: {
                    HStack {
                        Image(systemName: "apple.logo")
                        Text("Sign In with Apple")
                    }
                }
                .disabled(isSigningIn)
                
                Text("Uses native ASAuthorizationController (Face ID/Touch ID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Sign In with OAuth") {
                TextField("Provider", text: $provider)
                
                HStack {
                    Button("google") { provider = "google" }
                    Button("github") { provider = "github" }
                    Button("microsoft") { provider = "microsoft" }
                }
                
                Button("signInWithOAuth(provider: \"\(provider)\")") {
                    Task { await signInWithOAuth() }
                }
                .disabled(isSigningIn)
                
                if isSigningIn {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Waiting for OAuth...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("OAuth URL Generation (Manual)") {
                Button("getOAuthUrl(provider: \"\(provider)\")") {
                    Task { await getOAuthUrl() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("OAuth")
    }
    
    func signInWithApple() async {
        viewModel.logInfo("signInWithOAuth(apple)", message: "Opening native Apple Sign In...")
        isSigningIn = true
        
        do {
            try await viewModel.clientApp.signInWithOAuth(
                provider: "apple",
                presentationContextProvider: presentationProvider
            )
            viewModel.logCall(
                "signInWithOAuth(provider: \"apple\")",
                params: "provider: \"apple\" (native flow)",
                result: "Success! User signed in via Apple."
            )
            // Fetch user to show details
            if let user = try await viewModel.clientApp.getUser() {
                let dict = await serializeCurrentUser(user)
                viewModel.logCall(
                    "getUser() after Apple Sign In",
                    result: formatObject("CurrentUser", dict)
                )
            }
        } catch {
            viewModel.logCall("signInWithOAuth(provider: \"apple\")", params: "provider: \"apple\"", error: error)
        }
        
        isSigningIn = false
    }
    
    func signInWithOAuth() async {
        let params = "provider: \"\(provider)\""
        viewModel.logInfo("signInWithOAuth()", message: "Opening OAuth browser...", details: params)
        isSigningIn = true
        
        do {
            try await viewModel.clientApp.signInWithOAuth(
                provider: provider,
                presentationContextProvider: presentationProvider
            )
            viewModel.logCall(
                "signInWithOAuth(provider:)",
                params: params,
                result: "Success! User signed in via OAuth."
            )
            // Fetch user to show details
            if let user = try await viewModel.clientApp.getUser() {
                let dict = await serializeCurrentUser(user)
                viewModel.logCall(
                    "getUser() after OAuth",
                    result: formatObject("CurrentUser", dict)
                )
            }
        } catch {
            viewModel.logCall("signInWithOAuth(provider:)", params: params, error: error)
        }
        
        isSigningIn = false
    }
    
    func getOAuthUrl() async {
        let params = "provider: \"\(provider)\"\nredirectUrl: \"\(redirectUrl)\"\nerrorRedirectUrl: \"\(errorRedirectUrl)\""
        viewModel.logInfo("getOAuthUrl()", message: "Calling...", details: params)
        
        do {
            let result = try await viewModel.clientApp.getOAuthUrl(provider: provider, redirectUrl: redirectUrl, errorRedirectUrl: errorRedirectUrl)
            viewModel.logCall(
                "getOAuthUrl(provider:redirectUrl:errorRedirectUrl:)",
                params: params,
                result: "OAuthUrlResult {\n  url: \"\(result.url)\"\n  state: \"\(result.state)\"\n  codeVerifier: \"\(result.codeVerifier)\"\n  redirectUrl: \"\(result.redirectUrl)\"\n}"
            )
        } catch {
            viewModel.logCall("getOAuthUrl(provider:redirectUrl:errorRedirectUrl:)", params: params, error: error)
        }
    }
}

// MARK: - Tokens View

struct TokensView: View {
    @Bindable var viewModel: SDKTestViewModel
    
    var body: some View {
        Form {
            Section("Token Operations") {
                Button("getAccessToken()") {
                    Task { await getAccessToken() }
                }
                
                Button("getRefreshToken()") {
                    Task { await getRefreshToken() }
                }
                
                Button("getAuthHeaders()") {
                    Task { await getAuthHeaders() }
                }
            }
            
            Section("Token Store Types") {
                Button("Test Memory Store") {
                    Task { await testMemoryStore() }
                }
                
                Button("Test Explicit Store") {
                    Task { await testExplicitStore() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tokens")
    }
    
    func getAccessToken() async {
        viewModel.logInfo("getAccessToken()", message: "Calling...")
        
        let token = await viewModel.clientApp.getAccessToken()
        if let token = token {
            let parts = token.split(separator: ".")
            viewModel.logCall(
                "getAccessToken()",
                result: "JWT Token:\n  Parts: \(parts.count)\n  Length: \(token.count) chars\n  Token: \(token)"
            )
        } else {
            viewModel.logCall("getAccessToken()", result: "nil")
        }
    }
    
    func getRefreshToken() async {
        viewModel.logInfo("getRefreshToken()", message: "Calling...")
        
        let token = await viewModel.clientApp.getRefreshToken()
        if let token = token {
            viewModel.logCall(
                "getRefreshToken()",
                result: "Refresh Token:\n  Length: \(token.count) chars\n  Token: \(token)"
            )
        } else {
            viewModel.logCall("getRefreshToken()", result: "nil")
        }
    }
    
    func getAuthHeaders() async {
        viewModel.logInfo("getAuthHeaders()", message: "Calling...")
        
        let headers = await viewModel.clientApp.getAuthHeaders()
        var result = "Headers {\n"
        for (key, value) in headers {
            result += "  \"\(key)\": \"\(value)\"\n"
        }
        result += "}"
        viewModel.logCall("getAuthHeaders()", result: result)
    }
    
    func testMemoryStore() async {
        viewModel.logInfo("StackClientApp(tokenStore: .memory)", message: "Creating app with memory store...")
        
        let app = StackClientApp(
            projectId: viewModel.projectId,
            publishableClientKey: viewModel.publishableClientKey,
            baseUrl: viewModel.baseUrl,
            tokenStore: .memory,
            noAutomaticPrefetch: true
        )
        let token = await app.getAccessToken()
        viewModel.logCall(
            "StackClientApp(tokenStore: .memory)",
            result: "Created app with memory store\ngetAccessToken() = \(token == nil ? "nil" : "present")"
        )
    }
    
    func testExplicitStore() async {
        viewModel.logInfo("Testing explicit token store...", message: "Getting tokens from current app...")
        
        let accessToken = await viewModel.clientApp.getAccessToken()
        let refreshToken = await viewModel.clientApp.getRefreshToken()
        
        guard let at = accessToken, let rt = refreshToken else {
            viewModel.logCall("testExplicitStore()", result: "Error: No tokens available. Sign in first.")
            return
        }
        
        let app = StackClientApp(
            projectId: viewModel.projectId,
            publishableClientKey: viewModel.publishableClientKey,
            baseUrl: viewModel.baseUrl,
            tokenStore: .explicit(accessToken: at, refreshToken: rt),
            noAutomaticPrefetch: true
        )
        
        do {
            let user = try await app.getUser()
            if let user = user {
                let email = await user.primaryEmail
                viewModel.logCall(
                    "StackClientApp(tokenStore: .explicit(...))",
                    result: "Success! Created app with explicit tokens\ngetUser() returned: \(email ?? "no email")"
                )
            } else {
                viewModel.logCall(
                    "StackClientApp(tokenStore: .explicit(...))",
                    result: "App created but getUser() returned nil"
                )
            }
        } catch {
            viewModel.logCall("testExplicitStore()", error: error)
        }
    }
}

// MARK: - Server Users View

struct ServerUsersView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var email = ""
    @State private var displayName = ""
    @State private var userId = ""
    @State private var users: [(id: String, email: String?)] = []
    
    var body: some View {
        Form {
            Section("Create User") {
                TextField("Email", text: $email)
                TextField("Display Name (optional)", text: $displayName)
                
                Button("Generate Random Email") {
                    email = "test-\(UUID().uuidString.lowercased())@example.com"
                    viewModel.logInfo("generateEmail()", message: "Generated: \(email)")
                }
                
                Button("serverApp.createUser(email: email)") {
                    Task { await createUser() }
                }
                .disabled(email.isEmpty)
                
                Button("serverApp.createUser(email, password, displayName, ...)") {
                    Task { await createUserWithAllOptions() }
                }
                .disabled(email.isEmpty)
            }
            
            Section("List Users") {
                Button("serverApp.listUsers(limit: 5)") {
                    Task { await listUsers() }
                }
                
                ForEach(users, id: \.id) { user in
                    HStack {
                        Text(user.email ?? "no email")
                        Spacer()
                        Text(user.id.prefix(8) + "...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Select") {
                            userId = user.id
                            viewModel.logInfo("selectUser()", message: "Selected: \(user.id)")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            
            Section("User Operations") {
                TextField("User ID", text: $userId)
                
                Button("serverApp.getUser(id: userId)") {
                    Task { await getUser() }
                }
                .disabled(userId.isEmpty)
                
                Button("user.delete()") {
                    Task { await deleteUser() }
                }
                .disabled(userId.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server Users")
    }
    
    func createUser() async {
        let params = "email: \"\(email)\""
        viewModel.logInfo("createUser()", message: "Calling...", details: params)
        
        do {
            let user = try await viewModel.serverApp.createUser(email: email)
            let dict = await serializeServerUser(user)
            viewModel.logCall(
                "serverApp.createUser(email:)",
                params: params,
                result: formatObject("ServerUser", dict)
            )
            userId = user.id
            await listUsers()
        } catch {
            viewModel.logCall("serverApp.createUser(email:)", params: params, error: error)
        }
    }
    
    func createUserWithAllOptions() async {
        let params = """
        email: "\(email)"
        password: "TestPassword123!"
        displayName: "\(displayName.isEmpty ? "nil" : displayName)"
        primaryEmailVerified: true
        clientMetadata: {"source": "macOS-example"}
        serverMetadata: {"created_via": "example-app"}
        """
        viewModel.logInfo("createUser(all options)", message: "Calling...", details: params)
        
        do {
            let user = try await viewModel.serverApp.createUser(
                email: email,
                password: "TestPassword123!",
                displayName: displayName.isEmpty ? nil : displayName,
                primaryEmailVerified: true,
                clientMetadata: ["source": "macOS-example"],
                serverMetadata: ["created_via": "example-app"]
            )
            let dict = await serializeServerUser(user)
            viewModel.logCall(
                "serverApp.createUser(...)",
                params: params,
                result: formatObject("ServerUser", dict)
            )
            userId = user.id
            await listUsers()
        } catch {
            viewModel.logCall("serverApp.createUser(...)", params: params, error: error)
        }
    }
    
    func listUsers() async {
        let params = "limit: 5"
        viewModel.logInfo("listUsers()", message: "Calling...", details: params)
        
        do {
            let result = try await viewModel.serverApp.listUsers(limit: 5)
            var usersList: [(id: String, email: String?)] = []
            var dicts: [[String: Any]] = []
            for user in result.items {
                let dict = await serializeServerUser(user)
                dicts.append(dict)
                usersList.append((id: user.id, email: dict["primaryEmail"] as? String))
            }
            users = usersList
            viewModel.logCall("serverApp.listUsers(limit:)", params: params, result: formatObjectArray("ServerUser", dicts))
        } catch {
            viewModel.logCall("serverApp.listUsers(limit:)", params: params, error: error)
        }
    }
    
    func getUser() async {
        let params = "id: \"\(userId)\""
        viewModel.logInfo("getUser()", message: "Calling...", details: params)
        
        do {
            let user = try await viewModel.serverApp.getUser(id: userId)
            if let user = user {
                let dict = await serializeServerUser(user)
                viewModel.logCall(
                    "serverApp.getUser(id:)",
                    params: params,
                    result: formatObject("ServerUser", dict)
                )
            } else {
                viewModel.logCall("serverApp.getUser(id:)", params: params, result: "nil (user not found)")
            }
        } catch {
            viewModel.logCall("serverApp.getUser(id:)", params: params, error: error)
        }
    }
    
    func deleteUser() async {
        let params = "userId: \"\(userId)\""
        viewModel.logInfo("user.delete()", message: "Calling...", details: params)
        
        do {
            guard let user = try await viewModel.serverApp.getUser(id: userId) else {
                viewModel.logCall("user.delete()", params: params, result: "Error: User not found")
                return
            }
            try await user.delete()
            viewModel.logCall("user.delete()", params: params, result: "Success! User deleted.")
            userId = ""
            await listUsers()
        } catch {
            viewModel.logCall("user.delete()", params: params, error: error)
        }
    }
}

// MARK: - Server Teams View

struct ServerTeamsView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var teamName = ""
    @State private var teamId = ""
    @State private var userIdToAdd = ""
    @State private var teams: [(id: String, name: String)] = []
    
    var body: some View {
        Form {
            Section("Create Team") {
                TextField("Team Name", text: $teamName)
                
                Button("Generate Random Name") {
                    teamName = "Team \(UUID().uuidString.prefix(8))"
                    viewModel.logInfo("generateTeamName()", message: "Generated: \(teamName)")
                }
                
                Button("serverApp.createTeam(displayName: teamName)") {
                    Task { await createTeam() }
                }
                .disabled(teamName.isEmpty)
            }
            
            Section("List Teams") {
                Button("serverApp.listTeams()") {
                    Task { await listTeams() }
                }
                
                ForEach(teams, id: \.id) { team in
                    HStack {
                        Text(team.name)
                        Spacer()
                        Text(team.id.prefix(8) + "...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Select") {
                            teamId = team.id
                            viewModel.logInfo("selectTeam()", message: "Selected: \(team.id)")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            
            Section("Team Membership") {
                TextField("Team ID", text: $teamId)
                TextField("User ID", text: $userIdToAdd)
                
                Button("team.addUser(id: userId)") {
                    Task { await addUserToTeam() }
                }
                .disabled(teamId.isEmpty || userIdToAdd.isEmpty)
                
                Button("team.removeUser(id: userId)") {
                    Task { await removeUserFromTeam() }
                }
                .disabled(teamId.isEmpty || userIdToAdd.isEmpty)
                
                Button("team.listUsers()") {
                    Task { await listTeamUsers() }
                }
                .disabled(teamId.isEmpty)
            }
            
            Section("Team Operations") {
                Button("team.delete()") {
                    Task { await deleteTeam() }
                }
                .disabled(teamId.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server Teams")
    }
    
    func createTeam() async {
        let params = "displayName: \"\(teamName)\""
        viewModel.logInfo("createTeam()", message: "Calling...", details: params)
        
        do {
            let team = try await viewModel.serverApp.createTeam(displayName: teamName)
            let dict = await serializeServerTeam(team)
            viewModel.logCall(
                "serverApp.createTeam(displayName:)",
                params: params,
                result: formatObject("ServerTeam", dict)
            )
            teamId = team.id
            await listTeams()
        } catch {
            viewModel.logCall("serverApp.createTeam(displayName:)", params: params, error: error)
        }
    }
    
    func listTeams() async {
        viewModel.logInfo("listTeams()", message: "Calling...")
        
        do {
            let teamsList = try await viewModel.serverApp.listTeams()
            var results: [(id: String, name: String)] = []
            var dicts: [[String: Any]] = []
            for team in teamsList {
                let dict = await serializeServerTeam(team)
                dicts.append(dict)
                results.append((id: team.id, name: dict["displayName"] as? String ?? ""))
            }
            teams = results
            viewModel.logCall("serverApp.listTeams()", result: formatObjectArray("ServerTeam", dicts))
        } catch {
            viewModel.logCall("serverApp.listTeams()", error: error)
        }
    }
    
    func addUserToTeam() async {
        let params = "teamId: \"\(teamId)\"\nuserId: \"\(userIdToAdd)\""
        viewModel.logInfo("team.addUser()", message: "Calling...", details: params)
        
        do {
            guard let team = try await viewModel.serverApp.getTeam(id: teamId) else {
                viewModel.logCall("team.addUser()", params: params, result: "Error: Team not found")
                return
            }
            try await team.addUser(id: userIdToAdd)
            let dict = await serializeServerTeam(team)
            viewModel.logCall("team.addUser(id:)", params: params, result: "Success! User added to team.\n\n" + formatObject("ServerTeam", dict))
        } catch {
            viewModel.logCall("team.addUser(id:)", params: params, error: error)
        }
    }
    
    func removeUserFromTeam() async {
        let params = "teamId: \"\(teamId)\"\nuserId: \"\(userIdToAdd)\""
        viewModel.logInfo("team.removeUser()", message: "Calling...", details: params)
        
        do {
            guard let team = try await viewModel.serverApp.getTeam(id: teamId) else {
                viewModel.logCall("team.removeUser()", params: params, result: "Error: Team not found")
                return
            }
            try await team.removeUser(id: userIdToAdd)
            let dict = await serializeServerTeam(team)
            viewModel.logCall("team.removeUser(id:)", params: params, result: "Success! User removed from team.\n\n" + formatObject("ServerTeam", dict))
        } catch {
            viewModel.logCall("team.removeUser(id:)", params: params, error: error)
        }
    }
    
    func listTeamUsers() async {
        let params = "teamId: \"\(teamId)\""
        viewModel.logInfo("team.listUsers()", message: "Calling...", details: params)
        
        do {
            guard let team = try await viewModel.serverApp.getTeam(id: teamId) else {
                viewModel.logCall("team.listUsers()", params: params, result: "Error: Team not found")
                return
            }
            let users = try await team.listUsers()
            let dicts = users.map { serializeTeamUser($0) }
            viewModel.logCall("team.listUsers()", params: params, result: formatObjectArray("TeamUser", dicts))
        } catch {
            viewModel.logCall("team.listUsers()", params: params, error: error)
        }
    }
    
    func deleteTeam() async {
        let params = "teamId: \"\(teamId)\""
        viewModel.logInfo("team.delete()", message: "Calling...", details: params)
        
        do {
            guard let team = try await viewModel.serverApp.getTeam(id: teamId) else {
                viewModel.logCall("team.delete()", params: params, result: "Error: Team not found")
                return
            }
            try await team.delete()
            viewModel.logCall("team.delete()", params: params, result: "Success! Team deleted.")
            teamId = ""
            await listTeams()
        } catch {
            viewModel.logCall("team.delete()", params: params, error: error)
        }
    }
}

// MARK: - Sessions View

struct SessionsView: View {
    @Bindable var viewModel: SDKTestViewModel
    @State private var userId = ""
    @State private var accessToken = ""
    @State private var refreshToken = ""
    
    var body: some View {
        Form {
            Section("Create Session (Impersonation)") {
                TextField("User ID", text: $userId)
                
                Button("serverApp.createSession(userId: userId)") {
                    Task { await createSession() }
                }
                .disabled(userId.isEmpty)
            }
            
            Section("Session Tokens") {
                if !accessToken.isEmpty {
                    Text("Access Token:")
                        .font(.headline)
                    Text(accessToken)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(5)
                    
                    Text("Refresh Token:")
                        .font(.headline)
                    Text(refreshToken)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            
            Section("Use Session") {
                Button("Create Client with Session Tokens") {
                    Task { await useSessionTokens() }
                }
                .disabled(accessToken.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sessions")
    }
    
    func createSession() async {
        let params = "userId: \"\(userId)\""
        viewModel.logInfo("createSession()", message: "Calling...", details: params)
        
        do {
            let tokens = try await viewModel.serverApp.createSession(userId: userId)
            accessToken = tokens.accessToken
            refreshToken = tokens.refreshToken
            viewModel.logCall(
                "serverApp.createSession(userId:)",
                params: params,
                result: """
                SessionTokens {
                  accessToken: "\(tokens.accessToken.prefix(50))..."
                  refreshToken: "\(tokens.refreshToken.prefix(30))..."
                }
                """
            )
        } catch {
            viewModel.logCall("serverApp.createSession(userId:)", params: params, error: error)
        }
    }
    
    func useSessionTokens() async {
        viewModel.logInfo("StackClientApp(tokenStore: .explicit(...))", message: "Creating client with session tokens...")
        
        do {
            let client = StackClientApp(
                projectId: viewModel.projectId,
                publishableClientKey: viewModel.publishableClientKey,
                baseUrl: viewModel.baseUrl,
                tokenStore: .explicit(accessToken: accessToken, refreshToken: refreshToken),
                noAutomaticPrefetch: true
            )
            let user = try await client.getUser()
            if let user = user {
                let dict = await serializeCurrentUser(user)
                viewModel.logCall(
                    "clientWithTokens.getUser()",
                    result: "Success! Authenticated user:\n\n" + formatObject("CurrentUser", dict)
                )
            } else {
                viewModel.logCall(
                    "clientWithTokens.getUser()",
                    result: "nil (tokens may be invalid)"
                )
            }
        } catch {
            viewModel.logCall("clientWithTokens.getUser()", error: error)
        }
    }
}
