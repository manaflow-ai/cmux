//! The catalog scope a resource kind or public id kind names, for selector
//! and not-found error details.

pub(super) fn canonical_resource_scope(kind: &str) -> &'static str {
    match kind.trim_end_matches('s') {
        "machine" | "MachinePublicId" => "machine",
        "session" | "SessionPublicId" => "session",
        "client" | "ClientPublicId" => "client",
        "workspace" | "WorkspacePublicId" | "ws" => "workspace",
        "screen" | "ScreenPublicId" => "screen",
        "pane" | "PanePublicId" => "pane",
        "split" | "SplitPublicId" => "split",
        "tab" | "TabPublicId" => "tab",
        "terminal" | "TerminalPublicId" | "term" => "terminal",
        "browser" | "BrowserPublicId" => "browser",
        "notification" | "NotificationPublicId" => "notification",
        "agent" | "AgentPublicId" => "agent",
        "frontend_projection" | "FrontendProjectionPublicId" | "projection" => {
            "frontend_projection"
        }
        "pairing_request" | "PairingRequestPublicId" | "pairing" => "pairing_request",
        "sidebar_view" | "SidebarViewPublicId" => "sidebar_view",
        "sidebar_plugin" | "SidebarPluginPublicId" => "sidebar_plugin",
        "stream" | "StreamPublicId" => "stream",
        "tab_group" => "tab_group",
        "saved_tab_group" => "saved_tab_group",
        "workspace_group" => "workspace_group",
        "room" => "room",
        "screen_group" => "screen_group",
        "closed" => "closed",
        "conversation" => "conversation",
        other => panic!("unknown catalog resource scope {other:?}"),
    }
}
