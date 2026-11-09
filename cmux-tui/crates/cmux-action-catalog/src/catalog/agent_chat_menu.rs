// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentChatMenuActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentChatMenuActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentPane.toggleDisplaySettings",
        group: GROUP,
        title: Text::raw("Toggle Text & Width"),
        keywords: &["agent", "chat", "display", "text", "width", "appearance", "font", "layout"],
        category: "agents",
        symbol: "textformat.size",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent toggle-display-settings",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.replayConversation",
        group: GROUP,
        title: Text::raw("Replay Conversation"),
        keywords: &["agent", "chat", "conversation", "replay", "history", "recording", "playback"],
        category: "agents",
        symbol: "arrow.counterclockwise",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent replay-conversation",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.editInstructions",
        group: GROUP,
        title: Text::raw("Edit Folder Instructions…"),
        keywords: &["agent", "chat", "project", "instructions", "claude.md", "agents.md", "rules", "edit"],
        category: "agents",
        symbol: "doc.text",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent edit-instructions",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.addProjectFiles",
        group: GROUP,
        title: Text::raw("Add Files to Folder…"),
        keywords: &["agent", "chat", "project", "files", "context", "knowledge", "add", "attach"],
        category: "agents",
        symbol: "folder.badge.plus",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent add-project-files",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.markUnread",
        group: GROUP,
        title: Text::raw("Mark Chat Unread"),
        keywords: &["agent", "chat", "unread", "notification", "mark", "later"],
        category: "agents",
        symbol: "circle.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent mark-unread",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.moveToFloatingChat",
        group: GROUP,
        title: Text::raw("Move Chat to Floating Chat"),
        keywords: &["agent", "chat", "floating", "float", "detach", "panel", "window"],
        category: "agents",
        symbol: "rectangle.inset.filled.and.person.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent move-to-floating-chat",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.continueAfterError",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.continueAfterError", "Continue After Error"),
        keywords: &["agent", "chat", "continue", "retry", "try again", "resume", "error", "failed", "rate limit", "capacity"],
        category: "agents",
        symbol: "arrow.clockwise",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent continue-after-error",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.toggleMinimap",
        group: GROUP,
        title: Text::raw("Toggle Thread Minimap"),
        keywords: &["agent", "chat", "thread", "minimap", "rail", "prompts", "navigation", "map"],
        category: "agents",
        symbol: "sidebar.left",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent toggle-minimap",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.revealCwdInFinder",
        group: GROUP,
        title: Text::raw("Reveal Chat Folder in Finder"),
        keywords: &["agent", "chat", "folder", "cwd", "directory", "finder", "reveal", "show"],
        category: "agents",
        symbol: "folder",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent reveal-cwd-in-finder",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.openCwdInTerminal",
        group: GROUP,
        title: Text::raw("Open Chat Folder in Terminal"),
        keywords: &["agent", "chat", "folder", "cwd", "directory", "terminal", "shell", "open"],
        category: "agents",
        symbol: "terminal",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "agent open-cwd-in-terminal",
        focuses: true,
        ..Action::DEFAULT
    },
];
