import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CLIPathFixture {
    let fileManager: FileManager
    let rootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let installer: CmuxCLIPathInstaller

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }
}
