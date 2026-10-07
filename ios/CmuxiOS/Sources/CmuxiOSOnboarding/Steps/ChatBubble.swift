import SwiftUI

/// One message on the reply tour page: incoming (agent) or outgoing (you).
struct ChatBubble: View {
    let text: String
    let outgoing: Bool

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(outgoing ? OnboardingColors.outgoingText : OnboardingColors.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(outgoing ? OnboardingColors.outgoingBubble : OnboardingColors.incomingBubble,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
            .padding(outgoing ? .leading : .trailing, 40)
    }
}
