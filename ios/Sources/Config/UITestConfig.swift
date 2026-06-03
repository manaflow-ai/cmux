import Foundation

enum UITestConfig {
    static var mockDataEnabled: Bool {
        mockDataEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func mockDataEnabled(from env: [String: String]) -> Bool {
        #if DEBUG
        if env["CMUX_UITEST_MOCK_DATA"] == "0" {
            return false
        }
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

    static var terminalDirectFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_DIRECT_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    static var terminalDiscoveredFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_DISCOVERED_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    static var terminalInboxFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    static var terminalSetupFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_SETUP_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    static var terminalSetupSaveOnlyFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_SETUP_SAVE_ONLY"] == "1"
        #else
        return false
        #endif
    }

    static var terminalInputFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_INPUT_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    static var terminalReconnectDelayOverride: Double? {
        #if DEBUG
        return nonNegativeDoubleOverride("CMUX_UITEST_TERMINAL_RECONNECT_DELAY")
        #else
        return nil
        #endif
    }

    private static func nonNegativeDoubleOverride(_ key: String) -> Double? {
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env[key],
              let seconds = Double(rawValue),
              seconds >= 0 else {
            return nil
        }
        return seconds
    }
}
