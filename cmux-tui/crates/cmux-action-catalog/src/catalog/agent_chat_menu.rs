// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentChatMenuActionCatalog` actions.

use super::args;
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
        title: Text::raw("Edit Project Instructions…"),
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
        title: Text::raw("Add Project Files…"),
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
    // Open in Editor on a chat's folder: the "..." menu's Folder ▸, Session Info, and a Priority row's menu
    // (its `agent-chat` target). The editors and the default are the App's (cmux-window-rules `editors`).
    Action {
        id: "agentPane.openCwdInEditor",
        group: GROUP,
        title: Text::raw("Open Chat Folder in Editor"),
        keywords: &["agent", "chat", "folder", "cwd", "directory", "editor", "ide", "code", "vscode", "cursor", "zed", "open"],
        category: "agents",
        symbol: "chevron.left.forwardslash.chevron.right",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("priorityRow", "reopen", 0).label(Text::raw("Open in Editor"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::EDITOR.optional()],
        requires: &["agentPaneFocused"],
        targets: &["pane", "agent-chat"],
        cli_name: "agent open-cwd-in-editor",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.openCwdInApp",
        group: GROUP,
        title: Text::raw("Open Chat Folder In…"),
        keywords: &["agent", "chat", "folder", "cwd", "directory", "editor", "ide", "app", "open in", "open with"],
        category: "agents",
        symbol: "arrow.up.forward.app",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("priorityRow", "reopen", 1).style("choices").label(Text::raw("Open In"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::EDITOR],
        requires: &["agentPaneFocused"],
        targets: &["pane", "agent-chat"],
        cli_name: "agent open-cwd-in",
        focuses: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.copyCwdPath",
        group: GROUP,
        title: Text::raw("Copy Chat Folder Path"),
        keywords: &["agent", "chat", "folder", "cwd", "directory", "path", "copy", "clipboard"],
        category: "agents",
        symbol: "doc.on.doc",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("priorityRow", "inspect", 0).label(Text::raw("Copy Path"))], ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane", "agent-chat"],
        cli_name: "agent copy-cwd-path",
        focuses: true,
        ..Action::DEFAULT
    },
];
