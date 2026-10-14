#if os(iOS)
import CnxDesign
import SwiftUI

/// The context meter in the composer's controls row: a small ring (used / size) whose
/// menu shows the tokens, as in the ACP web UI.
struct ContextUsageRing: View {
    let usage: ContextUsage

    var body: some View {
        Menu {
            Section("Context window") {
                Text("\(usage.percent)% used")
                Text(usage.tokensLabel)
            }
        } label: {
            ZStack {
                Circle().stroke(Color.cnxFillSelected, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: usage.fraction)
                    .stroke(usage.isNearlyFull ? Color.cnxWarning : Color.primary.opacity(0.7),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.cnxSmooth, value: usage.fraction)
            }
            .frame(width: 18, height: 18)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel("Context used")
        .accessibilityValue(Text("\(usage.percent) percent, \(usage.tokensLabel)"))
    }
}

/// The running turn's plan pinned above the composer: progress, count and the current step.
/// Tapping expands the whole checklist.
struct PlanProgressBar: View {
    let progress: PlanProgress
    let entries: [ACPPlanEntry]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.cnxSmooth) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(Color.cnxFillSelected, lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: Double(progress.completed) / Double(max(progress.total, 1)))
                            .stroke(Color.cnxSuccess, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.cnxSmooth, value: progress.completed)
                    }
                    .frame(width: 16, height: 16)
                    Text(progress.current ?? "Plan complete")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(progress.countLabel)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: entry.status == .completed ? "checkmark.circle.fill"
                                  : (entry.status == .inProgress ? "circle.dotted" : "circle"))
                                .foregroundStyle(entry.status == .completed ? Color.cnxSuccess : .secondary)
                            Text(entry.content).font(.footnote)
                                .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                        }
                    }
                }
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Plan, \(progress.completed) of \(progress.total) done. \(progress.current ?? "")"))
    }
}
#endif
