import Foundation

enum Variant: String, CaseIterable {
    case chromeA = "chrome-a"
    case chromeB = "chrome-b"
    case chromeC = "chrome-c"
    case stateConnecting = "state-connecting"
    case stateHighLatency = "state-high-latency"
    case stateConsentWait = "state-consent-wait"
    case stateDisconnectedBy = "state-disconnected-by"
    case stateHostStopped = "state-host-stopped"
    case hostI1 = "host-i1"
    case hostI2 = "host-i2"
    case hostI3 = "host-i3"
    case hostConsent = "host-consent"
}

enum AppearanceChoice: String {
    case light
    case dark
}

enum MaterialChoice: String {
    case auto
    case glass
    case opaque
}

/// `--variant <name> --appearance light|dark [--material auto|glass|opaque]
/// [--hold <seconds>] [--list]`. Unknown arguments (for example
/// `-AppleLanguages (ja)`) pass through to AppKit.
struct LaunchArguments {
    var variant: Variant = .chromeA
    var appearance: AppearanceChoice = .dark
    var material: MaterialChoice = .auto
    /// The app exits by itself after this many seconds, so a forgotten
    /// launch never lingers. The capture script kills it sooner.
    var holdSeconds = 120
    var listOnly = false
    /// Renders the window's own view tree to this PNG and exits. Needs no
    /// Screen Recording grant, but cannot draw Liquid Glass (the window
    /// server composites it), so pair it with `--material opaque`.
    var snapshotPath: String?

    static func parse(_ argv: [String]) -> Result<LaunchArguments, UsageError> {
        var result = LaunchArguments()
        var index = 1
        func value(_ flag: String) throws(UsageError) -> String {
            index += 1
            guard index < argv.count else { throw UsageError(message: "\(flag) needs a value") }
            return argv[index]
        }
        do throws(UsageError) {
            while index < argv.count {
                switch argv[index] {
                case "--variant":
                    let name = try value("--variant")
                    guard let variant = Variant(rawValue: name) else { throw UsageError(message: "unknown variant \(name)") }
                    result.variant = variant
                case "--appearance":
                    let name = try value("--appearance")
                    guard let appearance = AppearanceChoice(rawValue: name) else { throw UsageError(message: "appearance is light or dark") }
                    result.appearance = appearance
                case "--material":
                    let name = try value("--material")
                    guard let material = MaterialChoice(rawValue: name) else { throw UsageError(message: "material is auto, glass or opaque") }
                    result.material = material
                case "--hold":
                    let raw = try value("--hold")
                    guard let seconds = Int(raw), seconds > 0 else { throw UsageError(message: "--hold needs seconds") }
                    result.holdSeconds = seconds
                case "--snapshot":
                    result.snapshotPath = try value("--snapshot")
                case "--list":
                    result.listOnly = true
                default:
                    break
                }
                index += 1
            }
        } catch {
            return .failure(error)
        }
        return .success(result)
    }
}

struct UsageError: Error {
    let message: String
    static let usage = """
    usage: rdpane-variants --variant <name> [--appearance light|dark] [--material auto|glass|opaque] [--hold <s>] [--snapshot <out.png>] [--list]
    """
}
