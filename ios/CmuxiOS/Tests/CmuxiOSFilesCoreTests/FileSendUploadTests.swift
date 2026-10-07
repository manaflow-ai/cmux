import CmuxiOSFeatureKit
@testable import CmuxiOSFilesCore
import Foundation
import Testing

/// The terminal composer's upload (E4): one completion per upload with the
/// Mac inbox path, or nil when it ends without finishing; nothing pasted.
@Suite("File send upload")
@MainActor
struct FileSendUploadTests {
    final class Results {
        var values: [String?] = []
    }

    @Test func finishedUploadAnswersThePathAndPastesNothing() async throws {
        let stager = FileStager(root: FileManager.default.temporaryDirectory.appendingPathComponent("e4u-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: stager.root) }
        let paster = RecordingPaster()
        let model = TransferListModel(transfer: MockFileTransfer())
        let coordinator = FileSendCoordinator(model: model, paster: paster, attachments: nil, stager: stager)
        let file = try stager.stage(data: Data("png".utf8), name: "shot 1.png")
        let results = Results()
        coordinator.upload(file, host: MockFixtures.studio) { results.values.append($0) }
        try await waitUntil { !results.values.isEmpty }
        #expect(results.values == ["/Users/mock/Downloads/cmux-phone/shot 1.png"])
        #expect(await paster.pastes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.url.path), "the staged copy is discarded")
        #expect(model.items.first?.request.destination == .composer)
    }

    @Test func cancelledUploadAnswersNil() async throws {
        let stager = FileStager(root: FileManager.default.temporaryDirectory.appendingPathComponent("e4c-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: stager.root) }
        let model = TransferListModel(transfer: MockFileTransfer(failAfterChunks: 2))
        let coordinator = FileSendCoordinator(model: model, paster: nil, attachments: nil, stager: stager)
        let file = try stager.stage(data: Data(repeating: 7, count: 800), name: "big.bin")
        let results = Results()
        let id = coordinator.upload(file, host: MockFixtures.studio) { results.values.append($0) }
        try await waitUntil { model.items.first?.canResume == true }
        model.cancel(id)
        try await waitUntil { !results.values.isEmpty }
        #expect(results.values == [nil])
    }
}
