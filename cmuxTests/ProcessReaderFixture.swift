import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ProcessReaderFixture: Sendable {
    let root: URL
    let healthyDirectory: URL
    let hungA: URL
    let hungB: URL
    let globalPath: String
    let globalFrameURL: URL
    let healthyFrameURL: URL

    init(codec: CmuxConfigActionCatalogFrameCodec) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-process-reader-\(UUID().uuidString)",
            isDirectory: true
        )
        healthyDirectory = root.appendingPathComponent("healthy", isDirectory: true)
        hungA = root.appendingPathComponent("hung-a", isDirectory: true)
        hungB = root.appendingPathComponent("hung-b", isDirectory: true)
        globalPath = root.appendingPathComponent("global.json").path
        globalFrameURL = root.appendingPathComponent("global-frame")
        healthyFrameURL = root.appendingPathComponent("healthy-frame")
        try FileManager.default.createDirectory(at: healthyDirectory, withIntermediateDirectories: true)
        try #require(codec.encode(
            .init(
                localPath: nil,
                local: nil,
                global: .init(status: .data, data: Data("{}".utf8))
            ),
            maximumConfigBytes: 1 << 20
        )).write(to: globalFrameURL)
        let localPath = healthyDirectory.appendingPathComponent(".cmux/cmux.json").path
        try #require(codec.encode(
            .init(
                localPath: localPath,
                local: .init(status: .missing, data: Data()),
                global: .init(status: .data, data: Data("{}".utf8))
            ),
            maximumConfigBytes: 1 << 20
        )).write(to: healthyFrameURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
