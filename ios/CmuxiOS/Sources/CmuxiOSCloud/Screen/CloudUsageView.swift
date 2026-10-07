import CmuxiOSCloudCore
import SwiftUI

/// Plan and usage: running machines against the limit, paused, VM hours.
struct CloudUsageView: View {
    let usage: CloudUsageSummary

    var body: some View {
        if usage.hasPlan {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(CloudText.activeUsage(usage.active, usage.maxActive)) {
                    Text(CloudText.plan(usage.planID)).foregroundStyle(.secondary)
                }
                ProgressView(value: usage.activeFraction)
                    .tint(.primary)
                    .accessibilityHidden(true)
            }
            Text(CloudText.savedUsage(usage.saved, usage.maxSaved))
            Text(hoursText).foregroundStyle(.secondary)
        } else {
            Text(CloudText.noPlan).foregroundStyle(.secondary)
        }
    }

    private var hoursText: String {
        let used = usage.vmHoursUsed.formatted(.number.precision(.fractionLength(0...1)))
        guard let included = usage.vmHoursIncluded else { return CloudText.hoursUsed(used) }
        return CloudText.hours(used, included.formatted(.number.precision(.fractionLength(0...1))))
    }
}
