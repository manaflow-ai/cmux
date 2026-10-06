import CmuxBrowser
import Foundation

/// Enables the discard policy in timer mode, which arms a countdown when a
/// pane is hidden, and returns the values to restore afterwards.
@MainActor
func enableHiddenWebViewDiscardTimerPolicy() -> [String: Any] {
    let defaults = UserDefaults.standard
    var previousValues: [String: Any] = [:]
    for key in [BrowserHiddenWebViewDiscardPolicy.enabledKey, BrowserHiddenWebViewDiscardPolicy.modeKey] {
        previousValues[key] = defaults.object(forKey: key)
    }
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set("timer", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
    return previousValues
}

@MainActor
func restoreHiddenWebViewDiscardPolicy(_ previousValues: [String: Any]) {
    let defaults = UserDefaults.standard
    for key in [BrowserHiddenWebViewDiscardPolicy.enabledKey, BrowserHiddenWebViewDiscardPolicy.modeKey] {
        if let value = previousValues[key] {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
