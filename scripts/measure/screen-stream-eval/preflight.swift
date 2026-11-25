// The screen stream eval's grant check: whether this process (and so every host the harness
// starts from it) may capture the screen and post input. Prints one JSON object; exits 0 either way.
//
//   swiftc -O -o screen-eval-preflight preflight.swift && ./screen-eval-preflight

import ApplicationServices
import CoreGraphics
import Foundation

let report: [String: Any] = [
    "screen_recording": CGPreflightScreenCaptureAccess(),
    "accessibility": AXIsProcessTrusted(),
    "user": NSUserName(),
]
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
