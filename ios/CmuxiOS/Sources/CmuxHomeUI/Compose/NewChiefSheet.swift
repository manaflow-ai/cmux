import CmuxHomeCore
import SwiftUI
import UIKit

/// New Chief: a short SwiftUI form (low-frequency, so SwiftUI is fine here)
/// that names a Chief, performs `createChief`, and opens its DM.
@MainActor
final class NewChiefViewController: UIHostingController<NewChiefForm>, ComposeScreen {
    var onFinish: (@MainActor (ConversationID?) -> Void)?
    private let draft: NewChiefDraft
    private var createItem: UIBarButtonItem?
    private lazy var observation = StoreObservation { [weak self] in
        guard let self else { return }
        self.createItem?.isEnabled = self.draft.canCreate
    }

    init(store: HomeStore) {
        let draft = NewChiefDraft(store: store)
        self.draft = draft
        super.init(rootView: NewChiefForm(draft: draft))
        title = HomeText.newChief
        draft.onFinish = { [weak self] id in self?.onFinish?(id) }
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasUnsavedInput: Bool { !draft.name.isEmpty }

    var focusesOnAppear: Bool {
        get { draft.focusesOnAppear }
        set { draft.focusesOnAppear = newValue }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onFinish?(nil)
        })
        let create = UIBarButtonItem(title: HomeText.create, style: .done, target: self, action: #selector(createTapped))
        navigationItem.rightBarButtonItem = create
        createItem = create
        // Tracks the name, the in-flight flag and the connection.
        observation.start()
    }

    @objc private func createTapped() {
        draft.create()
    }
}

/// The form's state and the `createChief` op.
@MainActor
@Observable
final class NewChiefDraft {
    static let maxLength = 60

    var name = ""
    private(set) var isCreating = false
    private(set) var failure: String?

    @ObservationIgnored var focusesOnAppear = true
    @ObservationIgnored var onFinish: (@MainActor (ConversationID?) -> Void)?
    @ObservationIgnored private let store: HomeStore

    init(store: HomeStore) {
        self.store = store
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canCreate: Bool {
        !trimmedName.isEmpty && trimmedName.count <= Self.maxLength && !isCreating && store.isOnline
    }

    var isOnline: Bool { store.isOnline }

    func create() {
        guard canCreate else { return }
        isCreating = true
        failure = nil
        let name = trimmedName
        let store = self.store
        Task { [weak self] in
            do {
                let result = try await store.perform(.createChief(name: name))
                self?.onFinish?(result.conversation)
            } catch let rejection as HomeRejection {
                self?.isCreating = false
                self?.failure = HomeText.explanation(for: rejection)
            } catch {
                self?.isCreating = false
            }
        }
    }
}

struct NewChiefForm: View {
    @Bindable var draft: NewChiefDraft
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField(HomeText.chiefNamePlaceholder, text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { draft.create() }
                    .disabled(draft.isCreating)
            } footer: {
                Text(verbatim: HomeText.chiefFormFooter)
            }
            if !draft.isOnline {
                Section {
                    Label(HomeText.offlineBody, systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = draft.failure {
                Section {
                    Text(verbatim: failure).foregroundStyle(.red)
                }
            }
            if draft.isCreating {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(verbatim: HomeText.creatingChief).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tint(.primary)
        .onAppear { focused = draft.focusesOnAppear }
    }
}
