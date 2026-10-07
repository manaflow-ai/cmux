public import SwiftUI

/// Settings > Demo Content, shown while App Review demo mode is on.
public struct DemoContentView: View {
    public init() {}

    public var body: some View {
        Form {
            Section {
                Label(PlatformText.demoActive, systemImage: "theatermasks")
            } footer: {
                Text(PlatformText.demoFooter)
            }
        }
        .navigationTitle(PlatformText.demoTitle)
    }
}
