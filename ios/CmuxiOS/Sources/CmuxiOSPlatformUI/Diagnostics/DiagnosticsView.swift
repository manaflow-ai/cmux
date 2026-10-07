public import SwiftUI
import UIKit

/// Settings > Diagnostics and `cmux://diagnostics`: crash-report consent,
/// share the scrubbed log, copy support info, clear. A low-frequency form.
public struct DiagnosticsView: View {
    @Bindable var model: DiagnosticsModel
    @State private var confirmingClear = false
    @State private var copied = false

    public init(model: DiagnosticsModel) { self.model = model }

    public var body: some View {
        Form {
            Section {
                LabeledContent(PlatformText.crashReports,
                               value: model.crashReportsEnabled ? PlatformText.on : PlatformText.off)
                    .accessibilityIdentifier("platform.diagnostics.crashReports")
            } footer: {
                Text(PlatformText.crashReportsMovedFooter)
            }
            Section {
                LabeledContent(PlatformText.logLines, value: model.lineCount.formatted())
                ShareLink(item: model.export, preview: SharePreview(PlatformText.diagnosticsTitle)) {
                    Label(PlatformText.shareDiagnostics, systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("platform.diagnostics.share")
                Button {
                    UIPasteboard.general.string = model.supportText
                    copied = true
                    UIAccessibility.post(notification: .announcement, argument: PlatformText.supportInfoCopied)
                } label: {
                    Label(copied ? PlatformText.supportInfoCopied : PlatformText.copySupportInfo,
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("platform.diagnostics.copy")
                Button(PlatformText.clearLog, role: .destructive) { confirmingClear = true }
                    .accessibilityIdentifier("platform.diagnostics.clear")
            } header: {
                Text(PlatformText.logSection)
            } footer: {
                Text(PlatformText.logFooter)
            }
        }
        .navigationTitle(PlatformText.diagnosticsTitle)
        .task { await model.refresh() }
        .confirmationDialog(PlatformText.clearLogConfirm, isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(PlatformText.clearLog, role: .destructive) {
                Task { await model.clear() }
            }
        }
    }
}
