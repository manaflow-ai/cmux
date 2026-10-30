// OS probe (vm.sh --suite exec --probe webkit-js-spi), for PL-memory: which private WKWebView JavaScript
// selectors this macOS's WebKit has. Prints "<selector> true|false" per selector and exits 0 when it ran
// (the answers are the data, not a verdict). Self-contained, no package.
import Foundation
import WebKit

let selectors = [
    "_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:",
    "_evaluateJavaScriptWithoutUserGesture:completionHandler:",
    "_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:",
    "_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:",
]
let os = ProcessInfo.processInfo.operatingSystemVersion
print("webkit-js-spi macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
for s in selectors {
    print(s, WKWebView.instancesRespond(to: NSSelectorFromString(s)))
}
