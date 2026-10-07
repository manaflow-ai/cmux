import Foundation

/// The header of an exported diagnostics file and the Copy Support Info
/// text. Build and device facts only: never the account id or email.
public struct DiagnosticSupportInfo: Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var deviceModel: String
    public var locale: String
    /// Extra facts in order, for example ("Flags", "feedTab, hostsTab").
    public var extra: [Field]

    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public init(appVersion: String, build: String, osVersion: String, deviceModel: String,
                locale: String, extra: [Field] = []) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.locale = locale
        self.extra = extra
    }

    /// Reads version and build from a bundle's Info.plist and the OS facts
    /// from the process.
    public init(bundle: Bundle, deviceModel: String, extra: [Field] = []) {
        let info = bundle.infoDictionary ?? [:]
        self.init(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: deviceModel,
            locale: Locale.current.identifier,
            extra: extra
        )
    }

    public var rendered: String {
        var lines = [
            "cmux \(appVersion) (\(build))",
            "OS: \(osVersion)",
            "Device: \(deviceModel)",
            "Locale: \(locale)",
        ]
        lines += extra.map { "\($0.name): \($0.value)" }
        return lines.joined(separator: "\n")
    }
}
