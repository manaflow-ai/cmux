import Foundation

enum UITestConfig {
    static var mockDataEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UITEST_MOCK_DATA"] == "1" {
            return true
        }
        if env["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    static var presentationSamplingEnabled: Bool {
        #if DEBUG
        guard mockDataEnabled else { return false }
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_PRESENTATION_FRAMES"] == "1"
        #else
        return false
        #endif
    }

    static var rawCaretFrameEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_RAW_CARET"] == "1"
        #else
        return false
        #endif
    }
}
