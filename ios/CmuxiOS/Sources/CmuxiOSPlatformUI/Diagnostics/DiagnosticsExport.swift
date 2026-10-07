public import CmuxiOSPlatform
public import CoreTransferable
import UniformTypeIdentifiers

/// The share-sheet item for the diagnostics file. The file is written only
/// when the user picks a destination, never on screen open.
public struct DiagnosticsExport: Transferable, Sendable {
    let sink: DiagnosticLogSink
    let header: DiagnosticSupportInfo

    public init(sink: DiagnosticLogSink, header: DiagnosticSupportInfo) {
        self.sink = sink
        self.header = header
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(try await export.sink.export(header: export.header))
        }
    }
}
