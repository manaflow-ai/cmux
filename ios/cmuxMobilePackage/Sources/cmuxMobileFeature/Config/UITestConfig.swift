import Foundation

enum UITestConfig {
    static var mockDataEnabled: Bool {
        mockDataEnabled(from: ProcessInfo.processInfo.environment)
    }

    static var addDeviceName: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_NAME")
    }

    static var addDeviceHost: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_HOST")
    }

    static var addDevicePort: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_PORT")
    }

    static var attachURL: String? {
        value(for: "CMUX_UITEST_ATTACH_URL")
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

    private static func value(for key: String) -> String? {
        #if DEBUG
        guard mockDataEnabled else { return nil }
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
        #else
        return nil
        #endif
    }
}
