// The probe scripts/measure/launch-reveal-capture.sh builds: finds the PID of the app it launched, logs that app's
// on-screen windows (epoch ms, id, bounds, alpha) as they appear and change, and reports Screen Recording access.
//   probe pid APP_PATH         the PID of the running app whose bundle is APP_PATH
//   probe windows PID SECONDS LRC-WIN lines every 20 ms change, for SECONDS
//   probe screen-access       yes or no (CGPreflightScreenCaptureAccess)
import Cocoa
import CoreGraphics

func epochMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: probe pid|windows|screen-access\n".utf8)); exit(2) }
switch args[1] {
case "screen-access":
  print(CGPreflightScreenCaptureAccess() ? "yes" : "no")
case "pid":
  guard args.count >= 3 else { exit(2) }
  for app in NSWorkspace.shared.runningApplications {
    let want = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().path
    if let path = app.bundleURL?.resolvingSymlinksInPath().path, path == want { print(app.processIdentifier) }
  }
case "windows":
  guard args.count >= 4, let pid = Int32(args[2]), let seconds = Double(args[3]) else { exit(2) }
  let end = Date().addingTimeInterval(seconds)
  var last = ""
  setvbuf(stdout, nil, _IOLBF, 0)
  while Date() < end {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
      let id = w[kCGWindowNumber as String] as? Int ?? 0
      let layer = w[kCGWindowLayer as String] as? Int ?? 0
      let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
      let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
      let line = "\(id) \(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0)) alpha=\(String(format: "%.2f", alpha)) layer=\(layer)"
      let key = "\(id)|\(line)"
      if !last.contains(key) { last += key + "\n"; print("LRC-WIN \(id) \(epochMs()) \(line)") }
    }
    usleep(20_000)
  }
default:
  exit(2)
}
