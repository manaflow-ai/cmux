import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding

final class CmuxConfigDecodingTests: XCTestCase {

    func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    func resolvedActions(
        from config: CmuxConfigFile,
        sourcePath: String? = nil
    ) -> [String: CmuxResolvedConfigAction] {
        Dictionary(
            uniqueKeysWithValues: config.actions.compactMap { id, definition in
                CmuxResolvedConfigAction.fromDefinition(
                    id: id,
                    definition: definition,
                    sourcePath: sourcePath
                ).map { (id, $0) }
            }
        )
    }

    // MARK: Simple commands

}

// MARK: - Command identity

