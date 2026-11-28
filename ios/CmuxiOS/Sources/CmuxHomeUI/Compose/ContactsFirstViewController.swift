import CmuxHomeCore
import CmuxiOSDesign
import Contacts
import ContactsUI
import UIKit

/// The contacts-first variant: the system contact picker is the main path
/// (no Contacts permission needed: the picker runs out of process and
/// returns only the chosen email or phone number), with manual entry as
/// the fallback. Message mode continues to the To: screen with the person
/// filled in; invite mode sends the invitation.
@MainActor
final class ContactsFirstViewController: UIViewController, ComposeScreen, CNContactPickerDelegate, UITextFieldDelegate {
    var onFinish: (@MainActor (ConversationID?) -> Void)?
    /// These screens never raise the keyboard on their own.
    var focusesOnAppear = false

    private let store: HomeStore
    private let mode: ComposeMode
    private let pickButton = UIButton(configuration: .filled())
    private let field = UITextField()
    private let continueButton = UIButton(configuration: .gray())
    private let hint = UILabel()
    private lazy var observation = StoreObservation { [weak self] in self?.updateState() }
    private let callingCode = RecipientSet.defaultCallingCode(region: Locale.current.region?.identifier)
    private var isSending = false

    init(store: HomeStore, mode: ComposeMode) {
        self.store = store
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode == .message ? HomeText.newMessage : HomeText.inviteTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasUnsavedInput: Bool { !(field.text ?? "").isEmpty }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onFinish?(nil)
        })
        navigationItem.backButtonDisplayMode = .minimal

        let heading = UILabel()
        heading.text = mode == .message ? HomeText.contactsHeadingMessage : HomeText.contactsHeadingInvite
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0

        var pick = UIButton.Configuration.filled()
        pick.title = HomeText.chooseFromContacts
        pick.image = UIImage(systemName: "person.crop.circle")
        pick.imagePadding = 8
        pick.buttonSize = .large
        pick.cornerStyle = .large
        pick.baseBackgroundColor = HomePalette.accent
        pick.baseForegroundColor = HomePalette.background
        pickButton.configuration = pick
        pickButton.addAction(UIAction { [weak self] _ in self?.showPicker() }, for: .primaryActionTriggered)

        let orLabel = UILabel()
        orLabel.text = HomeText.contactsManualLabel
        orLabel.font = .preferredFont(forTextStyle: .footnote)
        orLabel.adjustsFontForContentSizeCategory = true
        orLabel.textColor = HomePalette.secondaryText
        orLabel.numberOfLines = 0

        field.placeholder = HomeText.inviteFieldPlaceholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .continue
        field.tintColor = HomePalette.accent
        field.delegate = self
        field.accessibilityLabel = HomeText.inviteFieldPlaceholder
        field.addAction(UIAction { [weak self] _ in self?.updateState() }, for: .editingChanged)

        var next = UIButton.Configuration.gray()
        next.title = mode == .message ? HomeText.continueButton : HomeText.sendInvite
        next.buttonSize = .large
        next.cornerStyle = .large
        next.baseForegroundColor = HomePalette.primaryText
        continueButton.configuration = next
        continueButton.addAction(UIAction { [weak self] _ in self?.submitTyped() }, for: .primaryActionTriggered)

        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = HomePalette.secondaryText
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [heading, pickButton, orLabel, field, continueButton, hint])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(28, after: pickButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
        observation.start()
    }

    private var typedAddress: ContactAddress? {
        ContactAddress.parse(field.text ?? "", defaultCallingCode: callingCode)
    }

    private func updateState() {
        let online = store.isOnline
        let typed = !(field.text ?? "").isEmpty
        continueButton.isEnabled = typedAddress != nil && !isSending && (mode == .message || online)
        pickButton.isEnabled = !isSending && (mode == .message || online)
        if !online {
            hint.text = HomeText.offlineBody
        } else {
            hint.text = typed && typedAddress == nil ? HomeText.inviteFieldInvalid : HomeText.contactsPrivacyNote
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitTyped()
        return false
    }

    private func submitTyped() {
        guard let address = typedAddress else { return }
        proceed(with: address)
    }

    // MARK: Contact picker

    private func showPicker() {
        let picker = CNContactPickerViewController()
        picker.delegate = self
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0 OR phoneNumbers.@count > 0")
        // Choosing a contact opens their card so the person picks one address.
        picker.predicateForSelectionOfContact = NSPredicate(value: false)
        present(picker, animated: true)
    }

    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
        let raw: String? = if let email = contactProperty.value as? String {
            email
        } else if let phone = contactProperty.value as? CNPhoneNumber {
            phone.stringValue
        } else {
            nil
        }
        MainActor.assumeIsolated { self.picked(raw) }
    }

    private func picked(_ raw: String?) {
        guard let raw, let address = ContactAddress.parse(raw, defaultCallingCode: callingCode) else {
            hint.text = HomeText.inviteFieldInvalid
            return
        }
        proceed(with: address)
    }

    // MARK: Continue

    private func proceed(with address: ContactAddress) {
        switch mode {
        case .message:
            let next = NewMessageViewController(store: store, mode: .message, prefill: [address])
            next.onFinish = { [weak self] id in self?.onFinish?(id) }
            navigationController?.pushViewController(next, animated: !HomeMotion.reduceMotion)
        case .invite:
            guard store.isOnline, !isSending else { return }
            isSending = true
            updateState()
            let store = self.store
            Task { [weak self] in
                let outcome = await store.sendInvites([address])
                guard let self else { return }
                self.isSending = false
                self.updateState()
                let succeeded = !outcome.receipts.isEmpty
                self.present(outcome.confirmation { [weak self] in
                    if succeeded { self?.onFinish?(nil) }
                }, animated: true)
            }
        }
    }
}
