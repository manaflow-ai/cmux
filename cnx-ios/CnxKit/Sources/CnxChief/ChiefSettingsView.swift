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
    @State private var name: String
    @State private var nameError: String?

    public init(session: ChiefSession) {
        self.session = session
        _muted = State(initialValue: session.isMuted)
        _receipts = State(initialValue: session.sendsReadReceipts)
        _name = State(initialValue: session.store.info?.title ?? session.identity.title)
    }

    public var body: some View {
        NavigationStack {
            Form {
                header
                engineSection
                if session.control != nil, !(report?.recent.isEmpty ?? true) { recentSection }
                notificationsSection
                nameSection
                Section {
                } footer: {
                    Text("Chief's memory and traces open on the Mac.")
                }
            }
            .navigationTitle("Chief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chief.settings.done")
                }
            }
            // Loads again once Chief connects with the sheet open.
            .task(id: session.control != nil) { await load() }
            .onChange(of: session.title) { _, title in if let title, title != name { name = title } }
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
                ChiefAvatar(size: 72)
                Text(session.store.info?.title ?? session.identity.title)
                    .font(.title2.bold())
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private var statusLine: String {
        if let reason = session.unavailableReason { return reason }
        if session.isTyping { return String(localized: "Working on \(session.macName ?? String(localized: "your Mac"))") }
        return String(localized: "Runs on \(session.macName ?? String(localized: "your Mac"))")
    }

    @ViewBuilder private var engineSection: some View {
        Section {
            if session.control == nil {
                Text(session.unavailableReason ?? String(localized: "Connect to your Mac to choose Chief's model."))
                    .foregroundStyle(.secondary)
            } else if let report {
                Picker("Harness", selection: binding(\.harness, report.engine.harness ?? "claude")) {
                    ForEach(report.harnesses, id: \.self) { Text(Self.harnessName($0)).tag($0) }
                }
                .accessibilityIdentifier("chief.settings.harness")
                Picker("Model", selection: binding(\.model, report.choice.model ?? "default")) {
                    Text(defaultLabel(report.engine.model.flatMap { id in report.offered.models.first { $0.id == id }?.name ?? id }))
                        .tag("default")
                    ForEach(report.offered.models, id: \.id) { Text($0.name).tag($0.id) }
                    if let chosen = report.choice.model, !report.offered.models.contains(where: { $0.id == chosen }) {
                        Text(chosen).tag(chosen)
                    }
                }
                .accessibilityIdentifier("chief.settings.model")
                Picker("Effort", selection: binding(\.effort, report.choice.effort ?? "default")) {
                    Text(defaultLabel(report.engine.effort.map(Self.effortName))).tag("default")
                    ForEach(report.offered.efforts, id: \.self) { Text(Self.effortName($0)).tag($0) }
                    if let chosen = report.choice.effort, !report.offered.efforts.contains(chosen) {
                        Text(Self.effortName(chosen)).tag(chosen)
                    }
                }
                .accessibilityIdentifier("chief.settings.effort")
                .disabled(report.offered.efforts.isEmpty && report.choice.effort == nil)
            } else if loading {
                HStack { ProgressView(); Text("Asking Chief on the Mac…").foregroundStyle(.secondary) }
            }
            if let engineError {
                Text(engineError).font(.footnote).foregroundStyle(.red)
            }
            if session.control != nil, session.isTyping || stopping {
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
            if session.control != nil {
                Text("Changes apply to Chief's next turn, on every device.")
            }
        }
    }

    private var recentSection: some View {
        Section("Recent Turns") {
            ForEach(Array((report?.recent ?? []).prefix(5).enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 2) {
                    Text([turn.model, turn.harness].compactMap { $0 }.first ?? String(localized: "Turn"))
                        .font(.subheadline)
                    Text(Self.turnLine(turn))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

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

    private var nameSection: some View {
        Section {
            TextField("Name", text: $name)
                .submitLabel(.done)
                .onSubmit { Task { await rename() } }
                .accessibilityIdentifier("chief.settings.name")
            if let nameError {
                Text(nameError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Name")
        }
        .disabled(session.control == nil)
    }

    // MARK: Actions

    private func load() async {
        guard let control = session.control else { return }
        loading = true
        defer { loading = false }
        do {
            report = try await control.engine()
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
                    switch field {
                    case \.harness: report = try await control.setEngine(harness: value)
                    case \.model: report = try await control.setEngine(model: value)
                    default: report = try await control.setEngine(effort: value)
                    }
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

    private func rename() async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session.store.info?.title else { return }
        do {
            try await session.rename(title)
            nameError = nil
        } catch {
            nameError = (error as? ConversationBackendError)?.message ?? String(describing: error)
            name = session.store.info?.title ?? session.identity.title
        }
    }

    // MARK: Labels

    private func defaultLabel(_ current: String?) -> String {
        current.map { String(localized: "Default (\($0))") } ?? String(localized: "Default")
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

    static func turnLine(_ turn: ChiefEngineReport.Turn) -> String {
        var parts: [String] = []
        if let status = turn.status { parts.append(status) }
        if let ms = turn.ms { parts.append(Duration.milliseconds(Int64(ms)).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))) }
        if let tools = turn.tools, tools > 0 { parts.append(String(localized: "\(tools) tools")) }
        if let cost = turn.costUSD { parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))) }
        return parts.joined(separator: " · ")
    }
}
#endif
