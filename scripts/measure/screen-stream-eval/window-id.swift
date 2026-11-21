// The CGWindowID of a process's largest on-screen window, for the window targets (rd-window,
// cu-png): the scene's window, which they stream on its own instead of the whole display.
//
//   swiftc -O -o screen-eval-window-id window-id.swift
//   screen-eval-window-id OWNER_NAME [PID WINDOW_ID]
// With explicit identity, refuse unless that process has exactly one normal
// on-screen window and it is WINDOW_ID. This makes AX's one-window mapping unambiguous.

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: screen-eval-window-id OWNER_NAME [PID WINDOW_ID]\n".utf8))
    exit(2)
}
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
if CommandLine.arguments.count == 4 {
    guard let pid = Int(CommandLine.arguments[2]), pid > 0,
          let expected = Int(CommandLine.arguments[3]), expected > 0 else { exit(2) }
    let candidates = list.filter {
        ($0[kCGWindowOwnerName as String] as? String) == owner &&
            ($0[kCGWindowOwnerPID as String] as? Int) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0
    }
    guard candidates.count == 1, (candidates[0][kCGWindowNumber as String] as? Int) == expected else {
        FileHandle.standardError.write(Data("ambiguous or changed window for \(owner) pid \(pid); next: select its sole connection window\n".utf8))
        exit(1)
    }
    print(expected)
    exit(0)
}
let area = { (info: [String: Any]) -> Double in
    let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
let best = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }.max { area($0) < area($1) }
guard let id = best?[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write(Data("no on-screen window of \(owner)\n".utf8))
    exit(1)
}
print(id)
