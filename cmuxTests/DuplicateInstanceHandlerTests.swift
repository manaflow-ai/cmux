import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Duplicate instance handling")
struct DuplicateInstanceHandlerTests {
    @Test("only the cmux executable is considered a duplicate")
    func onlyCmuxExecutableMatches() {
        let app = URL(fileURLWithPath: "/Applications/cmux.app/Contents/MacOS/cmux")
        let cli = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux")
        let helper = URL(fileURLWithPath: "/usr/bin/osascript")

        #expect(AppDelegate.isDuplicateApplicationExecutableForTesting(app, mainExecutableURL: app, embeddedCLIURL: cli))
        #expect(!AppDelegate.isDuplicateApplicationExecutableForTesting(cli, mainExecutableURL: app, embeddedCLIURL: cli))
        #expect(!AppDelegate.isDuplicateApplicationExecutableForTesting(helper, mainExecutableURL: app, embeddedCLIURL: cli))
    }
}
