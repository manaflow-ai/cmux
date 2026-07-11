import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserWebExtensionDiscoveryServiceTests {
    @Test
    func pluginkitParserHandlesVerboseSpaceSeparatedOutput() {
        let output = """
        +    com.bitwarden.desktop.safari(2026.7.0)  01234567-89AB-CDEF-0123-456789ABCDEF  2026-07-09 03:21:09 +0000  /Applications/Bitwarden.app/Contents/PlugIns/safari.appex
        -    com.example.disabled(1.2.3)\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\t2026-07-09 03:22:09 +0000\t/Applications/Example App.app/Contents/PlugIns/Example Extension.appex
        """

        let candidates = BrowserWebExtensionDiscoveryService.parse(pluginkitOutput: output)

        #expect(candidates.map(\.id) == [
            "com.bitwarden.desktop.safari",
            "com.example.disabled",
        ])
        #expect(candidates.first?.version == "2026.7.0")
        #expect(candidates.first?.path == "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex")
        #expect(candidates.last?.version == "1.2.3")
        #expect(candidates.last?.path == "/Applications/Example App.app/Contents/PlugIns/Example Extension.appex")
    }
}
