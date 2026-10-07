public import SwiftUI

/// Plans stub behind the `billing` flag (off in every build until the cloud
/// lead decides plans): offers, purchase, restore.
public struct PlansView: View {
    @State private var model: PlansModel

    public init(model: PlansModel) { _model = State(initialValue: model) }

    public var body: some View {
        Form {
            Section {
                ForEach(model.state.plans) { plan in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.name).font(.headline)
                            Text(plan.summary).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.state.currentPlanID == plan.id {
                            Text(PlatformText.plansCurrent).font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button(plan.displayPrice) { Task { await model.purchase(plan.id) } }
                                .buttonStyle(.bordered)
                                .tint(.primary)
                                .disabled(model.working || !model.connection.isLive)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                if let error = model.lastError { Text(error) }
            }
            Section {
                Button(PlatformText.plansRestore) { Task { await model.restore() } }
                    .disabled(model.working || !model.connection.isLive)
            }
        }
        .navigationTitle(PlatformText.plansTitle)
        .task { await model.observe() }
    }
}
