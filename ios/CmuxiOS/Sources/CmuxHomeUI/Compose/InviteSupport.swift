import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// What a run of `invite` ops produced.
struct InviteOutcome: Sendable {
    var receipts: [InviteReceipt] = []
    var failures: [HomeRejection] = []

    /// The alert that confirms what happened.
    @MainActor
    func confirmation(onDone: @escaping @MainActor () -> Void) -> UIAlertController {
        let title: String
        let message: String
        if let failure = failures.first, receipts.isEmpty {
            title = HomeText.inviteFailedTitle
            message = HomeText.explanation(for: failure)
        } else {
            title = receipts.count == 1 ? HomeText.inviteSentTitle : HomeText.invitesSentTitle(receipts.count)
            message = receipts.map(\.confirmationLine).joined(separator: "\n")
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: HomeText.ok, style: .default) { _ in
            MainActor.assumeIsolated { onDone() }
        })
        return alert
    }
}

extension HomeStore {
    /// One `invite` per address, in order. Stops at the first offline refusal.
    func sendInvites(_ addresses: [ContactAddress]) async -> InviteOutcome {
        var outcome = InviteOutcome()
        for address in addresses {
            do {
                let result = try await perform(.invite(contact: address))
                outcome.receipts.append(result.invite ?? InviteReceipt(
                    contact: address, channel: address.isEmail ? .email : .sms, alreadyMember: false))
            } catch let rejection as HomeRejection {
                outcome.failures.append(rejection)
                if rejection == .ownerUnreachable { break }
            } catch {
                outcome.failures.append(.indeterminate)
            }
        }
        return outcome
    }
}

extension InviteReceipt {
    /// One confirmation line ("Emailed to sam@example.com.").
    var confirmationLine: String {
        if alreadyMember { return HomeText.inviteAlreadyMember(contact.description) }
        switch channel {
        case .email: return HomeText.inviteEmailed(contact.description)
        case .sms: return HomeText.inviteTexted(contact.description)
        }
    }
}

/// A card that previews the invitation a new person receives: who it is
/// from, the message, and the link. In message mode the message is editable.
@MainActor
final class InvitePreviewView: UIView {
    let messageView = UITextView()
    private let caption = UILabel()
    private let titleLabel = UILabel()
    private let linkLabel = UILabel()

    init(sender: String, editable: Bool) {
        super.init(frame: .zero)
        let card = UIView()
        card.backgroundColor = HomePalette.pinnedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        caption.text = HomeText.invitePreviewCaption
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = HomePalette.secondaryText
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        titleLabel.text = HomeText.invitationTitle(sender: sender)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        messageView.text = editable ? HomeText.inviteFirstMessage : HomeText.invitationBody(sender: sender)
        messageView.font = .preferredFont(forTextStyle: .body)
        messageView.adjustsFontForContentSizeCategory = true
        messageView.textColor = HomePalette.primaryText
        messageView.backgroundColor = .clear
        messageView.isScrollEnabled = false
        messageView.isEditable = editable
        messageView.tintColor = HomePalette.accent
        messageView.textContainerInset = .zero
        messageView.textContainer.lineFragmentPadding = 0
        messageView.accessibilityLabel = HomeText.invitePreviewMessageA11y

        linkLabel.text = HomeText.inviteLink
        linkLabel.isHidden = editable
        linkLabel.font = .preferredFont(forTextStyle: .footnote)
        linkLabel.adjustsFontForContentSizeCategory = true
        linkLabel.textColor = HomePalette.secondaryText

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageView, linkLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

extension HomeText {
    /// Why an op was refused, in one sentence.
    static func explanation(for rejection: HomeRejection) -> String {
        switch rejection {
        case .ownerUnreachable: offlineBody
        case .notAuthorized: rejectionNotAuthorized
        case .invalid: rejectionInvalid
        case .rateLimited: rejectionRateLimited
        case .indeterminate: rejectionIndeterminate
        }
    }
}
