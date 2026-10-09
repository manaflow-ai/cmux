import CmuxiOSLiveActivity
import SwiftUI
import WidgetKit

/// The widget extension's only code: the Live Activity for running agents
/// lives in the CmuxiOS package (CmuxiOSLiveActivity, c7-notify.md section 6).
@main
struct AgentActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentActivityWidget()
    }
}
