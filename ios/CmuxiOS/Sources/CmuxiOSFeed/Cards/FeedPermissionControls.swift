import CmuxiOSFeatureKit
import SwiftUI

/// Allow (first offered scope), Deny, and a menu of the other scopes.
struct FeedPermissionControls: View {
    let model: FeedCardModel
    let permission: FeedPermission
    let actions: FeedCardActions

    var body: some View {
        let scopes = permission.offeredScopes
        HStack(spacing: 8) {
            Button(FeedText.deny) { actions.answer(model.item.id, .permission(allow: false, scope: nil)) }
                .buttonStyle(FeedButtonStyle(role: .destructive))
            Button(scopes.count > 1 ? FeedText.allowScope(scopes[0]) : FeedText.allow) {
                actions.answer(model.item.id, .permission(allow: true, scope: scopes[0]))
            }
            .buttonStyle(FeedButtonStyle(role: .primary))
            if scopes.count > 1 {
                Menu {
                    ForEach(scopes.dropFirst(), id: \.self) { scope in
                        Button(FeedText.allowScope(scope)) {
                            actions.answer(model.item.id, .permission(allow: true, scope: scope))
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(FeedText.allowOptions)
                }
                .buttonStyle(FeedButtonStyle())
            }
        }
        .disabled(!model.canAnswer)
    }
}
