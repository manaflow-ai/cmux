import Foundation

/// Strings for compose, invite, New Group and New Chief.
extension HomeText {
    // MARK: To: field

    static var toLabel: String { String(localized: "home.to.label", defaultValue: "To:", bundle: .module) }
    static var toPlaceholder: String { String(localized: "home.to.placeholder", defaultValue: "Email or phone number", bundle: .module) }
    static var toA11y: String { String(localized: "home.to.a11y", defaultValue: "To", bundle: .module) }
    static var inviteBadge: String { String(localized: "home.to.inviteBadge", defaultValue: "Invite", bundle: .module) }
    static var remove: String { String(localized: "home.to.remove", defaultValue: "Remove", bundle: .module) }
    static var recipientsInviteNotice: String { String(localized: "home.to.inviteNotice", defaultValue: "People marked Invite aren't on cmux yet. Your message reaches them as an invite by email or text.", bundle: .module) }
    static var recipientsInvalidNotice: String { String(localized: "home.to.invalidNotice", defaultValue: "Some entries aren't an email address or phone number.", bundle: .module) }
    static var inviteOnlyNotice: String { String(localized: "home.to.inviteOnlyNotice", defaultValue: "They get an invitation from you by email or text. People already on cmux are told you're here.", bundle: .module) }

    static func recipientMemberA11y(_ name: String) -> String {
        String(localized: "home.to.memberA11y", defaultValue: "\(name), on cmux", bundle: .module)
    }

    static func recipientInvitableA11y(_ address: String) -> String {
        String(localized: "home.to.invitableA11y", defaultValue: "\(address), will be invited", bundle: .module)
    }

    static func recipientInvalidA11y(_ text: String) -> String {
        String(localized: "home.to.invalidA11y", defaultValue: "\(text), not an email address or phone number", bundle: .module)
    }

    // MARK: Invite

    static var inviteTitle: String { String(localized: "home.invite.title", defaultValue: "Invite to cmux", bundle: .module) }
    static var kindEmail: String { String(localized: "home.invite.kindEmail", defaultValue: "Email", bundle: .module) }
    static var kindPhone: String { String(localized: "home.invite.kindPhone", defaultValue: "Phone", bundle: .module) }
    static var inviteFieldPlaceholder: String { String(localized: "home.invite.fieldPlaceholder", defaultValue: "Email or phone number", bundle: .module) }
    static var inviteFieldHint: String { String(localized: "home.invite.fieldHint", defaultValue: "Enter an email address or a phone number.", bundle: .module) }
    static var inviteFieldInvalid: String { String(localized: "home.invite.fieldInvalid", defaultValue: "That isn't an email address or phone number yet.", bundle: .module) }
    static var inviteStatusEmail: String { String(localized: "home.invite.statusEmail", defaultValue: "Not on cmux yet. They get your invite by email.", bundle: .module) }
    static var inviteStatusText: String { String(localized: "home.invite.statusText", defaultValue: "Not on cmux yet. They get your invite by text message.", bundle: .module) }
    static var invitePreviewCaption: String { String(localized: "home.invite.previewCaption", defaultValue: "What they receive", bundle: .module) }
    static var invitePreviewMessageA11y: String { String(localized: "home.invite.previewMessageA11y", defaultValue: "Invite message", bundle: .module) }
    static var sendInvite: String { String(localized: "home.invite.send", defaultValue: "Send Invite", bundle: .module) }
    static var sendMessage: String { String(localized: "home.invite.sendMessage", defaultValue: "Send Message", bundle: .module) }
    static var shareInvite: String { String(localized: "home.invite.share", defaultValue: "Share Invite…", bundle: .module) }
    static var inviteSentTitle: String { String(localized: "home.invite.sentTitle", defaultValue: "Invite Sent", bundle: .module) }
    static var inviteFailedTitle: String { String(localized: "home.invite.failedTitle", defaultValue: "Couldn't Send the Invite", bundle: .module) }
    static var sendFailedTitle: String { String(localized: "home.send.failedTitle", defaultValue: "Couldn't Send", bundle: .module) }

    static func inviteStatusMember(_ name: String) -> String {
        String(localized: "home.invite.statusMember", defaultValue: "\(name) is already on cmux.", bundle: .module)
    }

    static func invitesSentTitle(_ count: Int) -> String {
        String(localized: "home.invite.sentTitleMany", defaultValue: "\(count) Invites Sent", bundle: .module)
    }

    static func inviteEmailed(_ address: String) -> String {
        String(localized: "home.invite.emailed", defaultValue: "Emailed to \(address).", bundle: .module)
    }

    static func inviteTexted(_ number: String) -> String {
        String(localized: "home.invite.texted", defaultValue: "Texted to \(number).", bundle: .module)
    }

    static func inviteAlreadyMember(_ address: String) -> String {
        String(localized: "home.invite.alreadyMember", defaultValue: "\(address) is already on cmux.", bundle: .module)
    }

    /// The default first message to someone who is not on cmux yet.
    static func inviteDefaultMessage(link: String) -> String {
        String(localized: "home.invite.defaultMessage", defaultValue: "Hey! I'm using cmux to run my coding agents from my phone. My Chief takes a task, runs agents on my machines, and messages me here when it needs me. Join me: \(link)", bundle: .module)
    }

    static func invitationTitle(sender: String) -> String {
        String(localized: "home.invite.invitationTitle", defaultValue: "\(sender) invited you to cmux", bundle: .module)
    }

    static func invitationBody(sender: String) -> String {
        String(localized: "home.invite.invitationBody", defaultValue: "Message \(sender) and their Chiefs, the agents that write code on their machines and report back here.", bundle: .module)
    }

    // MARK: Contacts first

    static var contactsHeadingMessage: String { String(localized: "home.contacts.headingMessage", defaultValue: "Who do you want to message?", bundle: .module) }
    static var contactsHeadingInvite: String { String(localized: "home.contacts.headingInvite", defaultValue: "Who do you want to invite?", bundle: .module) }
    static var chooseFromContacts: String { String(localized: "home.contacts.choose", defaultValue: "Choose from Contacts", bundle: .module) }
    static var contactsManualLabel: String { String(localized: "home.contacts.manual", defaultValue: "Or type an email address or phone number", bundle: .module) }
    static var contactsPrivacyNote: String { String(localized: "home.contacts.privacy", defaultValue: "cmux sees only the address you pick, not your contacts.", bundle: .module) }
    static var continueButton: String { String(localized: "home.contacts.continue", defaultValue: "Continue", bundle: .module) }

    // MARK: Sheets

    static var create: String { String(localized: "home.sheet.create", defaultValue: "Create", bundle: .module) }
    static var discardDraft: String { String(localized: "home.sheet.discard", defaultValue: "Discard", bundle: .module) }
    static var keepEditing: String { String(localized: "home.sheet.keepEditing", defaultValue: "Keep Editing", bundle: .module) }
    static var createFailedTitle: String { String(localized: "home.sheet.createFailed", defaultValue: "Couldn't Create", bundle: .module) }

    // MARK: New Group and New Chief

    static var groupNamePlaceholder: String { String(localized: "home.group.namePlaceholder", defaultValue: "Group Name (Optional)", bundle: .module) }
    static var groupSectionChiefs: String { String(localized: "home.group.sectionChiefs", defaultValue: "Chiefs", bundle: .module) }
    static var groupSectionPeople: String { String(localized: "home.group.sectionPeople", defaultValue: "People", bundle: .module) }
    static var chiefLabel: String { String(localized: "home.group.chiefLabel", defaultValue: "Chief", bundle: .module) }
    static var chiefNamePlaceholder: String { String(localized: "home.chief.namePlaceholder", defaultValue: "Name, like Release or Infra", bundle: .module) }
    static var chiefFormFooter: String { String(localized: "home.chief.footer", defaultValue: "A Chief takes tasks, runs agents on your machines and messages you here. Name it for the work it owns.", bundle: .module) }
    static var creatingChief: String { String(localized: "home.chief.creating", defaultValue: "Creating…", bundle: .module) }
}
