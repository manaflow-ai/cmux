// The CGWindowID of a process's largest on-screen window, for the window targets (rd-window,
// cu-png): the scene's window, which they stream on its own instead of the whole display.
//
//   swiftc -O -o screen-eval-window-id window-id.swift
//   screen-eval-window-id OWNER_NAME     (prints the id; exit 1 when the process has no window)

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: screen-eval-window-id OWNER_NAME\n".utf8))
    exit(2)
}
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
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
