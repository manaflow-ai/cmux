import SwiftUI

struct ChatDebugMenu: View {
    var body: some View {
        List {
            Section("Keyboard Handling Fixes") {
                NavigationLink("Fix 1: .never") {
                    ChatFix1_ContentInsetNever(conversation: fakeConversations[0])
                }
                NavigationLink("Fix 2: inputBarHeight only") {
                    ChatFix2_InputBarHeightOnly(conversation: fakeConversations[0])
                }
                NavigationLink("Fix 3: adjustedContentInset") {
                    ChatFix3_AdjustedContentInset(conversation: fakeConversations[0])
                }
                NavigationLink("Fix 4: delegate limit") {
                    ChatFix4_ScrollViewDelegate(conversation: fakeConversations[0])
                }
                NavigationLink("Fix 5: no bottom padding") {
                    ChatFix5_ReducePadding(conversation: fakeConversations[0])
                }
            }

            Section("Original (with dropdown)") {
                NavigationLink("Picker (default: none)") {
                    ChatApproachI(conversation: fakeConversations[0])
                }
                NavigationLink("Picker (default: Fix 1)") {
                    ChatApproachI_Fix1Default(conversation: fakeConversations[0])
                }
            }

            Section("Notes") {
                Text("Fix 1: contentInsetAdjustmentBehavior=.never")
                    .font(.caption)
                Text("Fix 2: inset=inputBarHeight only (no safe area)")
                    .font(.caption)
                Text("Fix 3: use adjustedContentInset to complement iOS")
                    .font(.caption)
                Text("Fix 4: limit scroll in UIScrollViewDelegate")
                    .font(.caption)
                Text("Fix 5: remove bottom padding on content")
                    .font(.caption)
            }
        }
        .navigationTitle("Chat Debug")
    }
}

#Preview {
    NavigationStack {
        ChatDebugMenu()
    }
}
