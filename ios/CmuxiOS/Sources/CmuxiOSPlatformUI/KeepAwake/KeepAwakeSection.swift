public import CmuxiOSFeatureKit
public import SwiftUI

/// A form section of keep-awake rows for the given Macs (DEV preview and
/// the future host detail screen).
public struct KeepAwakeSection: View {
    let macs: [(id: HostID, name: String)]
    @State private var model: KeepAwakeModel

    public init(macs: [(id: HostID, name: String)], model: KeepAwakeModel) {
        self.macs = macs
        _model = State(initialValue: model)
    }

    public var body: some View {
        Form {
            Section {
                ForEach(macs, id: \.id) { mac in
                    KeepAwakeRow(host: mac.id, name: mac.name, model: model)
                }
            } footer: {
                if let error = model.lastError { Text(error) }
            }
        }
        .navigationTitle(PlatformText.keepAwakeTitle)
        .task { await model.observe() }
    }
}
