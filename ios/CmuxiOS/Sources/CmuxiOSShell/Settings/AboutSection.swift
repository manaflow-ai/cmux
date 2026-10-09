import SwiftUI

/// Version, legal and support links, acknowledgements.
struct AboutSection: View {
    let about: ShellAbout

    var body: some View {
        Section(SettingsText.about) {
            LabeledContent(SettingsText.version, value: about.summary)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("shell.settings.version")
            Link(destination: SettingsLinks.termsOfService) {
                Label(SettingsText.termsOfService, systemImage: "doc.text")
            }
            Link(destination: SettingsLinks.privacyPolicy) {
                Label(SettingsText.privacyPolicy, systemImage: "hand.raised")
            }
            Link(destination: SettingsLinks.support) {
                Label(SettingsText.support, systemImage: "envelope")
            }
            NavigationLink {
                AcknowledgementsView()
            } label: {
                Label(SettingsText.acknowledgements, systemImage: "heart.text.square")
            }
            .accessibilityIdentifier("shell.settings.acknowledgements")
        }
    }
}
