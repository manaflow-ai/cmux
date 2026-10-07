public import CmuxiOSFeatureKit

/// What the composer asks of lane C4: upload a staged file to the Mac's
/// inbox (`dest.kind = composer`) and answer its absolute path there, or
/// nil when the upload failed or was cancelled. The staged copy is the
/// uploader's to discard.
@MainActor
public protocol TerminalComposerUploading: AnyObject {
    func upload(_ file: ComposerUploadFile, to host: HostID) async -> String?
}
