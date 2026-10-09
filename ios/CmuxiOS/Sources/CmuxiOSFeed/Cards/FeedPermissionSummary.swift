import CmuxiOSFeatureKit
import SwiftUI

/// What the agent wants to do: the action type, its summary and the command.
struct FeedPermissionSummary: View {
    let permission: FeedPermission
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(permission.summary.isEmpty ? FeedText.actionType(permission.actionType) : permission.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let command = permission.command ?? permission.tool {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(expanded ? nil : 3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .textSelection(.enabled)
            }
            if expanded, let cwd = permission.cwd {
                Text(cwd).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
