import WidgetKit
import SwiftUI

@main
struct CmuxWidgetBundle: WidgetBundle {
    var body: some Widget {
        CmuxLiveActivityWidget()
        AgentDecisionActivityWidget()
        WorkspaceStatusWidget()
        NotificationCountWidget()
    }
}
