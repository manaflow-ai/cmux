#if os(iOS)
import SwiftUI

private let theme = CnxTheme.standard

/// How a Mac reaches this iPhone: there is no pairing code. A Mac signed in
/// to the same account and team, with iPhone connections allowed, appears by
/// itself (PROTOCOL.md). Two numbered steps and a live status line that
/// flips when the Mac shows up. Used by the Workspaces empty state and the
/// first-run setup.
public struct ConnectMacSteps: View {
    let email: String?
    /// The first online Mac, once one appears.
    let onlineMac: String?

    public init(email: String?, onlineMac: String?) {
        self.email = email
        self.onlineMac = onlineMac
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, signInText)
            step(2, Text("In cmux on your Mac, turn on \(Text("Settings → Mobile → Allow iPhone Connections").fontWeight(.semibold))."))
            status
                .padding(.top, 6)
        }
        .frame(maxWidth: 340, alignment: .leading)
    }

    private var signInText: Text {
        if let email, !email.isEmpty {
            return Text("Open cmux on your Mac and sign in as \(Text(email).fontWeight(.semibold)).")
        }
        return Text("Open cmux on your Mac and sign in with this account.")
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.colors.label)
                .frame(width: 22, height: 22)
                .background(theme.colors.fill.color, in: .circle)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
            text
                .font(theme.type.body)
                .foregroundStyle(theme.colors.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if let onlineMac {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.colors.success.color)
                Text("\(onlineMac) is online")
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for your Mac…")
            }
        }
        .font(theme.type.rowSubtitle)
        .foregroundStyle(theme.colors.label2)
        .frame(minHeight: 22)
        .contentTransition(.opacity)
        .animation(theme.motion.snappy.animation, value: onlineMac)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connect-mac.status")
    }
}
#endif
