import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import SwiftUI

/// One machine: name, status, size, and why it is paused or failed.
struct CloudMachineRowView: View {
    let row: CloudMachineRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title.isEmpty ? CloudText.unnamed : row.title)
                        .font(.body)
                        .lineLimit(1)
                    if row.isClassic {
                        Text(CloudText.classic)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if row.isPendingCreate || row.status?.isTransitioning == true {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [CloudText.status(row.status)]
        if let reason = row.pauseReason { parts = [CloudText.pauseReason(reason)] }
        if let failure = row.failureMessage { parts.append(failure) }
        let size = CloudText.size(row.size)
        if !size.isEmpty { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch row.status {
        case .running?: "circle.fill"
        case .paused?: "pause.circle"
        case .failed?: "exclamationmark.triangle.fill"
        default: "circle.dotted"
        }
    }

    private var tint: Color {
        switch row.status {
        case .running?: Color(uiColor: .systemGreen)
        case .failed?: Color(uiColor: .systemRed)
        default: Color(uiColor: .tertiaryLabel)
        }
    }
}
