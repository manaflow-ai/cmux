#if os(iOS)
import CmuxConversationCore
import CnxDesign
import SwiftUI

/// Chief's details: what the Mac's Chief settings sidebar offers its owner
/// (HomeChiefSidebar: harness, model and effort; the name), Stop for a running
/// turn, the recent turns, and this phone's Hide Alerts and Send Read
/// Receipts. It replaces CmuxConversation's contact details for Chief, whose
/// Call, FaceTime and Mail have no meaning here. Every control acts on the
/// Mac's Chief or on this phone's settings; nothing here is decoration.
public struct ChiefSettingsView: View {
    let session: ChiefSession
    @Environment(\.dismiss) private var dismiss
    @State private var report: ChiefEngineReport?
    @State private var engineError: String?
    @State private var loading = false
    @State private var saving = false
    @State private var stopping = false
    @State private var stopNote: String?
    @State private var muted: Bool
    @State private var receipts: Bool

    public init(session: ChiefSession) {
        self.session = session
        _muted = State(initialValue: session.isMuted)
        _receipts = State(initialValue: session.sendsReadReceipts)
        _report = State(initialValue: session.engineReport)
    }

    private var hasControl: Bool { session.control != nil }
    private var name: String { session.title ?? session.identity.title }

    public var body: some View {
        NavigationStack {
            Form {
                header
                engineSection
                if hasControl, !(report?.recent.isEmpty ?? true) { recentSection }
                notificationsSection
                if hasControl { identitySection }
                Section {
                } footer: {
                    Text("Chief's memory and traces open on the Mac.")
                }
            }
            // The header already names Chief: no title in the bar (SPEC 4,
            // problem 6). It still names the sheet for VoiceOver.
            .navigationTitle("Chief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chief.settings.done")
                }
            }
            // Loads again once Chief connects with the sheet open.
            .task(id: hasControl) { await load() }
            // Hide Alerts changed elsewhere (Home's pin menu): the switch follows, animated.
            .onChange(of: session.isMuted) { _, on in if muted != on { withAnimation { muted = on } } }
            .onChange(of: session.sendsReadReceipts) { _, on in if receipts != on { withAnimation { receipts = on } } }
        }
        .accessibilityIdentifier("chief.settings")
    }

    // MARK: Sections

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                ChiefAvatar(text: session.avatar, size: 72)
                Text(name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
        }
    }

    /// Never claims Chief runs on a Mac it cannot reach: without the Mac's
    /// control channel the status is the reason, matching the Model row.
    private var statusLine: String {
        guard hasControl else {
            return session.unavailableReason ?? String(localized: "Not connected to your Mac")
        }
        let mac = session.macName ?? String(localized: "your Mac")
        if session.isTyping { return String(localized: "Working on \(mac)") }
        return String(localized: "Runs on \(mac)")
    }

    @ViewBuilder private var engineSection: some View {
        Section {
            if !hasControl {
                Text("Connect to your Mac to choose Chief's model.")
                    .foregroundStyle(.secondary)
            } else if let report {
                Picker("Harness", selection: binding(\.harness, report.engine.harness ?? "claude")) {
                    ForEach(report.harnesses, id: \.self) { Text(Self.harnessName($0)).tag($0) }
                }
                .accessibilityIdentifier("chief.settings.harness")
                Picker("Model", selection: binding(\.model, report.choice.model ?? "default")) {
                    Text(Self.defaultModelLabel(report)).tag("default")
                    ForEach(report.pickableModels, id: \.id) { Text($0.name).tag($0.id) }
                    if let chosen = report.choice.model, chosen != "default",
                       !report.pickableModels.contains(where: { $0.id == chosen }) {
                        Text(chosen).tag(chosen)
                    }
                }
                .accessibilityIdentifier("chief.settings.model")
                // No effort to pick on a harness that takes none: no row,
                // rather than a picker that does nothing.
                if !report.offered.efforts.isEmpty || report.choice.effort != nil {
                    Picker("Effort", selection: binding(\.effort, report.choice.effort ?? "default")) {
                        Text(Self.defaultLabel(report.engine.effort.map(Self.effortName))).tag("default")
                        ForEach(report.offered.efforts, id: \.self) { Text(Self.effortName($0)).tag($0) }
                        if let chosen = report.choice.effort, !report.offered.efforts.contains(chosen) {
                            Text(Self.effortName(chosen)).tag(chosen)
                        }
                    }
                    .accessibilityIdentifier("chief.settings.effort")
                }
            } else if loading {
                HStack { ProgressView(); Text("Asking Chief on the Mac…").foregroundStyle(.secondary) }
            }
            if let engineError {
                Text(engineError).font(.footnote).foregroundStyle(.red)
            }
            if hasControl, session.isTyping || stopping {
                Button(role: .destructive) {
                    Task { await stop() }
                } label: {
                    HStack {
                        Text("Stop Chief")
                        if stopping { Spacer(); ProgressView() }
                    }
                }
                .disabled(stopping)
                .accessibilityIdentifier("chief.settings.stop")
            }
            if let stopNote {
                Text(stopNote).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            if hasControl {
                Text("Changes apply to Chief's next turn, on every device.")
            }
        }
    }

    private var recentSection: some View {
        Section("Recent Turns") {
            ForEach(Array((report?.recent ?? []).prefix(5).enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.turnTitle(turn, in: report))
                        .font(.subheadline)
                    Text(Self.turnLine(turn))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// This phone's switches: they need the conversation, so without it they
    /// show the standard disabled dimming.
    private var notificationsSection: some View {
        Section {
            Toggle("Hide Alerts", isOn: $muted)
                .accessibilityIdentifier("chief.settings.hideAlerts")
                .onChange(of: muted) { _, on in
                    guard on != session.isMuted else { return }
                    session.setMuted(on) { withAnimation { muted = !on } }
                }
            Toggle("Send Read Receipts", isOn: $receipts)
                .accessibilityIdentifier("chief.settings.readReceipts")
                .onChange(of: receipts) { _, on in
                    guard on != session.sendsReadReceipts else { return }
                    session.setSendsReadReceipts(on) { withAnimation { receipts = !on } }
                }
        } footer: {
            Text("Hide Alerts silences Chief's notifications on this iPhone. With Send Read Receipts off, reading Chief here does not mark it read on your Mac.")
        }
        .disabled(session.conversationID == nil)
    }

    /// Name, and the avatar on a Mac that reads and sets it: a value on the
    /// right that opens a one-field page with Save, as in Settings.
    private var identitySection: some View {
        Section {
            NavigationLink {
                ChiefFieldEditor(title: String(localized: "Name"), value: name, footer: nil) { value in
                    try await session.rename(value)
                }
            } label: {
                LabeledContent("Name", value: name)
            }
            .accessibilityIdentifier("chief.settings.name")
            if let report, report.avatarSupported {
                NavigationLink {
                    ChiefFieldEditor(title: String(localized: "Avatar"), value: report.avatar ?? "",
                                     footer: String(localized: "An emoji or one or two letters. Leave it empty for \(ChiefIdentity.defaultAvatar)."), allowsEmpty: true) { value in
                        try await setAvatar(value)
                    }
                } label: {
                    LabeledContent("Avatar", value: session.avatar)
                }
                .accessibilityIdentifier("chief.settings.avatar")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        guard let control = session.control else { return }
        loading = true
        defer { loading = false }
        do {
            let loaded = try await control.engine()
            report = loaded
            session.adopt(loaded)
            engineError = nil
        } catch {
            engineError = String(describing: error)
        }
    }

    /// A picker bound to one engine field: picking writes it on the Mac and
    /// shows the brain's answer; a refusal puts the old value back.
    private func binding(_ field: WritableKeyPath<ChiefEngineReport.Engine, String?>, _ current: String) -> Binding<String> {
        Binding {
            current
        } set: { value in
            guard value != current, let control = session.control, !saving else { return }
            let before = report
            report?.choice[keyPath: field] = value == "default" ? nil : value
            if value != "default" { report?.engine[keyPath: field] = value }
            saving = true
            Task {
                defer { saving = false }
                do {
                    let answer = switch field {
                    case \.harness: try await control.setEngine(harness: value)
                    case \.model: try await control.setEngine(model: value)
                    default: try await control.setEngine(effort: value)
                    }
                    report = answer
                    session.adopt(answer)
                    engineError = nil
                } catch {
                    report = before
                    engineError = String(describing: error)
                }
            }
        }
    }

    private func stop() async {
        guard let control = session.control else { return }
        stopping = true
        defer { stopping = false }
        do {
            stopNote = try await control.stop() ? String(localized: "Chief stopped.") : String(localized: "Chief had nothing running.")
        } catch {
            stopNote = String(describing: error)
        }
    }

    /// Sets the avatar on the Mac (`chief.engine.set` `avatar`); empty is the default.
    private func setAvatar(_ value: String) async throws {
        guard let control = session.control else {
            throw ConversationBackendError(code: -1, message: String(localized: "Chief isn't connected to a Mac"))
        }
        let answer = try await control.setEngine(avatar: value)
        report = answer
        session.adopt(answer)
    }

    // MARK: Labels

    static func defaultLabel(_ current: String?) -> String {
        current.map { String(localized: "Default (\($0))") } ?? String(localized: "Default")
    }

    /// The model picker's default item names what it resolves to (SPEC 4):
    /// acpmux's own "default" entry ("Default (GPT-6.1 Sol)"), else the
    /// engine's resolved model, else plain "Default".
    static func defaultModelLabel(_ report: ChiefEngineReport) -> String {
        if let entry = report.defaultModel, !entry.name.isEmpty, entry.name.caseInsensitiveCompare("default") != .orderedSame {
            return entry.name.lowercased().hasPrefix("default") ? entry.name : defaultLabel(entry.name)
        }
        guard let model = report.engine.model, model != "default" else { return defaultLabel(nil) }
        return defaultLabel(report.modelName(model) ?? model)
    }

    static func harnessName(_ id: String) -> String {
        switch id {
        case "claude": "Claude"
        case "codex": "Codex"
        case "claude-cr": "Claude (CodeRouter)"
        default: id
        }
    }

    static func effortName(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    /// A recent turn's first line: the model's display name, else the
    /// harness's ("Claude", "Codex"); never a raw id.
    static func turnTitle(_ turn: ChiefEngineReport.Turn, in report: ChiefEngineReport?) -> String {
        if let name = report?.modelName(turn.model) { return name }
        if let harness = turn.harness { return harnessName(harness) }
        return String(localized: "Turn")
    }

    /// "Failed · 2 min 57 s · 3 tools · $0.04".
    static func turnLine(_ turn: ChiefEngineReport.Turn) -> String {
        var parts: [String] = []
        if let status = turn.status { parts.append(statusName(status)) }
        if let ms = turn.ms { parts.append(durationText(milliseconds: ms)) }
        if let tools = turn.tools, tools > 0 {
            parts.append(tools == 1 ? String(localized: "1 tool") : String(localized: "\(tools) tools"))
        }
        if let cost = turn.costUSD { parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))) }
        return parts.joined(separator: " · ")
    }

    /// The brain's turn status (`ok`, `error`, `stopped`, ...) in words.
    static func statusName(_ status: String) -> String {
        switch status.lowercased() {
        case "ok", "done", "completed", "complete", "success", "end": String(localized: "Completed")
        case "error", "failed", "failure": String(localized: "Failed")
        case "stopped", "interrupted", "cancelled", "canceled", "aborted": String(localized: "Stopped")
        case "running": String(localized: "Running")
        default: status.prefix(1).uppercased() + status.dropFirst()
        }
    }

    /// "2 min 57 s", "45 s", "1 h 2 min".
    static func durationText(milliseconds: Double) -> String {
        let seconds = Int((milliseconds / 1000).rounded())
        let (h, m, s) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        if h > 0 { return m > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(h) h") }
        if m > 0 { return s > 0 ? String(localized: "\(m) min \(s) s") : String(localized: "\(m) min") }
        return String(localized: "\(s) s")
    }
}

/// One field of Chief's identity (Name, Avatar) on its own page, as
/// Settings edits a value: the field, Save in the bar, and the Mac's
/// refusal in the footer when it does not take the change.
struct ChiefFieldEditor: View {
    let title: String
    let original: String
    let footer: String?
    /// The name may not be empty; the avatar may (it clears to the default).
    let allowsEmpty: Bool
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(title: String, value: String, footer: String?, allowsEmpty: Bool = false,
         save: @escaping (String) async throws -> Void) {
        self.title = title
        original = value
        self.footer = footer
        self.allowsEmpty = allowsEmpty
        self.save = save
        _value = State(initialValue: value)
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { trimmed != original && (allowsEmpty || !trimmed.isEmpty) && !saving }

    var body: some View {
        Form {
            Section {
                TextField(title, text: $value)
                    .focused($focused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit { if canSave { Task { await commit() } } }
                    .accessibilityIdentifier("chief.settings.field")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let footer {
                    Text(footer)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await commit() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("chief.settings.save")
                }
            }
        }
        .onAppear { focused = true }
    }

    private func commit() async {
        saving = true
        defer { saving = false }
        do {
            try await save(trimmed)
            dismiss()
        } catch {
            self.error = (error as? ConversationBackendError)?.message ?? String(describing: error)
        }
    }
}
#endif
