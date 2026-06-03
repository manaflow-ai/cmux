import Foundation

struct RemotePlatform: Equatable, Sendable {
    let goOS: String
    let goArch: String

    var resourceDirectoryName: String {
        "\(goOS)-\(goArch)"
    }
}

enum TerminalRemoteDaemonBootstrap {
    struct BundleLocator {
        private let resourceRoot: URL?

        init(resourceRoot: URL? = Bundle.main.resourceURL) {
            self.resourceRoot = resourceRoot
        }

        func binaryURL(goOS: String, goArch: String, version: String) throws -> URL {
            guard let resourceRoot else {
                throw BootstrapError.missingResourceRoot
            }

            let binaryURL = resourceRoot
                .appendingPathComponent("cmuxd-remote", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
                .appendingPathComponent("cmuxd-remote", isDirectory: false)

            guard FileManager.default.fileExists(atPath: binaryURL.path) else {
                throw BootstrapError.missingBinary(
                    version: version,
                    platform: "\(goOS)-\(goArch)"
                )
            }

            return binaryURL
        }
    }

    static func parsePlatform(stdout: String) throws -> RemotePlatform {
        let lines = stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            throw BootstrapError.invalidProbeOutput(stdout)
        }

        return RemotePlatform(
            goOS: try normalizeOS(lines[0]),
            goArch: try normalizeArchitecture(lines[1])
        )
    }

    static func installScript(remotePath: String) throws -> String {
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        guard !remoteDirectory.isEmpty else {
            throw BootstrapError.invalidRemotePath(remotePath)
        }

        let quotedRemotePath = shellSingleQuoted(remotePath)
        let quotedRemoteDirectory = shellSingleQuoted(remoteDirectory)

        return """
        set -eu
        decode_base64() {
          if command -v base64 >/dev/null 2>&1; then
            case "$(uname -s 2>/dev/null || true)" in
              Darwin)
                base64 -D
                ;;
              *)
                base64 -d
                ;;
            esac
            return $?
          fi
          echo "base64 command not found" >&2
          exit 1
        }

        expand_tilde() {
          case "$1" in
            "~")
              printf '%s\\n' "$HOME"
              ;;
            "~/"*)
              printf '%s/%s\\n' "$HOME" "${1#~/}"
              ;;
            *)
              printf '%s\\n' "$1"
              ;;
          esac
        }

        raw_remote_path=\(quotedRemotePath)
        raw_remote_dir=\(quotedRemoteDirectory)
        remote_path="$(expand_tilde "$raw_remote_path")"
        remote_dir="$(expand_tilde "$raw_remote_dir")"
        tmp_path="${remote_path}.tmp"

        mkdir -p "$remote_dir"
        decode_base64 > "$tmp_path"
        chmod 755 "$tmp_path"
        mv "$tmp_path" "$remote_path"
        """
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func normalizeOS(_ value: String) throws -> String {
        switch value.lowercased() {
        case "darwin":
            return "darwin"
        case "linux":
            return "linux"
        default:
            throw BootstrapError.unsupportedOperatingSystem(value)
        }
    }

    private static func normalizeArchitecture(_ value: String) throws -> String {
        switch value.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "arm64", "aarch64":
            return "arm64"
        default:
            throw BootstrapError.unsupportedArchitecture(value)
        }
    }
}

enum BootstrapError: LocalizedError, Equatable {
    case missingResourceRoot
    case missingBinary(version: String, platform: String)
    case invalidProbeOutput(String)
    case invalidRemotePath(String)
    case unsupportedOperatingSystem(String)
    case unsupportedArchitecture(String)

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            return "cmuxd-remote bundle resources are unavailable."
        case .missingBinary(let version, let platform):
            return "Missing cmuxd-remote binary for \(version) \(platform)."
        case .invalidProbeOutput(let output):
            return "Unsupported platform probe output: \(output)"
        case .invalidRemotePath(let path):
            return "Invalid remote install path: \(path)"
        case .unsupportedOperatingSystem(let value):
            return "Unsupported remote operating system: \(value)"
        case .unsupportedArchitecture(let value):
            return "Unsupported remote architecture: \(value)"
        }
    }
}
