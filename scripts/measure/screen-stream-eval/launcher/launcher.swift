// CmuxScreenEvalLauncher.app: the stable app the screen stream eval runs inside, so the stream
// hosts it starts capture the screen and post input under this app's Screen Recording and
// Accessibility grants. macOS gives a process the grants of its responsible app, and every child
// of an app LaunchServices started has that app as its responsible app; the hosts are rebuilt at
// every commit, this app is not (install.sh installs it once and never replaces it), so one grant
// at the console lasts.
//
//   launcher --status                      the grants as this app sees them (JSON)
//   launcher --request                     the same, after asking macOS for both, which lists the app
//                                          under Privacy & Security > Screen Recording and Accessibility
//   launcher SCRIPT STATUS_FILE [ARG...]   runs /bin/bash SCRIPT ARG... and writes its exit status to
//                                          STATUS_FILE
//
// Started through `open -W -n -g -a CmuxScreenEvalLauncher --args ...` (so LaunchServices makes it
// the responsible app). SCRIPT must be a scripts/measure/screen-stream-eval.sh owned by this user,
// run by a clean bash (no profile, rc file or BASH_ENV). That is a guard against a wrong path, not a
// boundary against this user's own processes; the README's "Trust" says why that is the right line.
// LaunchServices, not the step, is the app's parent, so a step that is killed would leave the run
// going: CMUX_SCREEN_EVAL_PARENT names the step's process, and the app ends the run's process group
// when that process is gone or the app gets SIGTERM.

import ApplicationServices
import CoreGraphics
import Foundation

func grants() -> String {
    let report: [String: Any] = [
        "screen_recording": CGPreflightScreenCaptureAccess(),
        "accessibility": AXIsProcessTrusted(),
        "user": NSUserName(),
        "launcher": Bundle.main.bundlePath,
    ]
    let json = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: json, as: UTF8.self)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cmux-screen-eval-launcher: \(message)\n".utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--status":
    print(grants())
    exit(0)
case "--request":
    _ = CGRequestScreenCaptureAccess()
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    print(grants())
    exit(0)
case nil:
    fail("usage: launcher --status | --request | SCRIPT STATUS_FILE [ARG...]")
default:
    break
}
guard args.count >= 2 else { fail("usage: launcher SCRIPT STATUS_FILE [ARG...]") }
let script = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
let statusFile = args[1]
guard script.lastPathComponent == "screen-stream-eval.sh",
      script.deletingLastPathComponent().path.hasSuffix("/scripts/measure"),
      let attributes = try? FileManager.default.attributesOfItem(atPath: script.path),
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
else { fail("refusing \(script.path): only this user's scripts/measure/screen-stream-eval.sh runs here") }

var environment = ProcessInfo.processInfo.environment
for name in ["BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH"] { environment[name] = nil }
environment["CMUX_SCREEN_EVAL_IN_LAUNCHER"] = "1"
let parent = environment["CMUX_SCREEN_EVAL_PARENT"].flatMap { pid_t($0) }
let argv = ["/bin/bash", "--noprofile", "--norc", script.path] + args.dropFirst(2)
let cArgs = argv.map { strdup($0) } + [nil]
let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
var spawnAttributes: posix_spawnattr_t?
posix_spawnattr_init(&spawnAttributes)
posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETPGROUP)) // the run gets a process group of its own
posix_spawnattr_setpgroup(&spawnAttributes, 0)
var pid: pid_t = 0
let spawned = posix_spawn(&pid, "/bin/bash", nil, &spawnAttributes, cArgs, cEnv)
guard spawned == 0 else { fail("posix_spawn: \(String(cString: strerror(spawned)))") }

/// Ends the run's process group: SIGTERM, then SIGKILL after 10 s.
func endRun() {
    kill(-pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { kill(-pid, SIGKILL) }
}
signal(SIGTERM, SIG_IGN)
let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
terminated.setEventHandler(handler: endRun)
terminated.resume()
let watch = DispatchSource.makeTimerSource(queue: .global())
if let parent {
    watch.schedule(deadline: .now() + 2, repeating: 2) // the step's process, every 2 s
    watch.setEventHandler {
        if kill(parent, 0) == -1, errno == ESRCH {
            watch.cancel()
            endRun()
        }
    }
    watch.resume()
}
var status: Int32 = 0
while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
try? "\(code)\n".write(toFile: statusFile, atomically: true, encoding: .utf8)
exit(code)
