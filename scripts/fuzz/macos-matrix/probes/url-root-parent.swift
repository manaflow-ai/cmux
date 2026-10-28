// OS probe (vm.sh --suite exec --probe url-root-parent): issue #4529. Foundation's parent of the file
// URL "/" is "/.." on macOS 14 and 15 and "/" on macOS 26 (Apple changed the CFURL normalization).
// It reports the guest's answer and always exits 0: the value is the data. Self-contained, no package.
import Foundation

let parent = URL(fileURLWithPath: "/").deletingLastPathComponent().path
let os = ProcessInfo.processInfo.operatingSystemVersion
print("url-root-parent macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion): \"\(parent)\"")
