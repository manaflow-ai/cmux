import Foundation

/// Every PROTOCOL §4 RPC method name.
public enum HostMethod: String, Sendable, CaseIterable {
    case hello = "host.hello", ping = "host.ping"
    case convList = "conv.list", convHistory = "conv.history", convSend = "conv.send", convRead = "conv.read"
    case convSetPinned = "conv.setPinned", convSetMuted = "conv.setMuted", convDelete = "conv.delete"
    case agentHarnesses = "agent.harnesses", agentList = "agent.list", agentCreate = "agent.create"
    case agentHistory = "agent.history", agentPrompt = "agent.prompt", agentCancel = "agent.cancel"
    case agentClose = "agent.close", agentPermission = "agent.permission", agentSetModel = "agent.setModel"
    case agentSetMode = "agent.setMode", agentRename = "agent.rename"
    case termList = "term.list", termCreate = "term.create", termAttach = "term.attach", termDetach = "term.detach"
    case termResize = "term.resize", termClose = "term.close", termRename = "term.rename"
    case browserList = "browser.list", browserCreate = "browser.create", browserAttach = "browser.attach"
    case browserDetach = "browser.detach", browserClose = "browser.close", browserActivate = "browser.activate"
    case browserViewport = "browser.viewport", browserAck = "browser.ack", browserNavigate = "browser.navigate"
    case browserBack = "browser.back", browserForward = "browser.forward", browserReload = "browser.reload"
    case browserStop = "browser.stop", browserPointer = "browser.pointer", browserTouch = "browser.touch"
    case browserScroll = "browser.scroll", browserKey = "browser.key", browserText = "browser.text"
    case browserScreenshot = "browser.screenshot"
}

/// Every PROTOCOL §4 event topic.
public enum HostTopic: String, Sendable, CaseIterable {
    case convMessage = "conv.message", convUpdated = "conv.updated", convTyping = "conv.typing", convRemoved = "conv.removed"
    case agentSession = "agent.session", agentItem = "agent.item", agentRemoved = "agent.removed"
    case termUpdated = "term.updated", termExited = "term.exited"
    case browserTab = "browser.tab", browserClosed = "browser.closed", browserDetached = "browser.detached"
}
