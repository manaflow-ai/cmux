import Foundation

/// Shell-quote a single argument so it can be embedded inside a remote
/// command line (e.g. `cmux send --text $(cat <<EOF...)`).
///
/// We're using POSIX single-quote rules: wrap the value in single quotes,
/// escape embedded single quotes as `'\''`. Anything else passes through
/// unchanged. This is the safest form for `/bin/sh`, `bash`, and `zsh` —
/// the three shells we may encounter on macOS / Linux remotes.
public enum ShellEscape {
    public static func single(_ value: String) -> String {
        if value.isEmpty { return "''" }
        // Always quote values that look like a CLI flag — `-foo` or `--foo`
        // — so they are passed as arguments to the cmux subcommand instead
        // of being interpreted as flags. Without this, a workspace handle
        // like "--help" would silently turn into a flag and the command
        // would do something unexpected.
        if value.first == "-" {
            return quoted(value)
        }
        if value.allSatisfy(isShellSafe) { return value }
        return quoted(value)
    }

    public static func command(_ parts: [String]) -> String {
        parts.map(single).joined(separator: " ")
    }

    private static func quoted(_ value: String) -> String {
        var out = "'"
        out.reserveCapacity(value.utf8.count + 2)
        for c in value {
            if c == "'" {
                out.append("'\\''")
            } else {
                out.append(c)
            }
        }
        out.append("'")
        return out
    }

    private static func isShellSafe(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        switch c {
        case "_", "-", ".", "/", ":", "@", ",", "=", "+":
            return true
        default:
            return false
        }
    }
}
