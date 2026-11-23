// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentChatCopyActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentChatCopyActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentChat.copyName",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyName", "Copy Agent Name"),
        keywords: &["agent", "chat", "harness", "name", "provider", "copy"],
        category: "agents",
        symbol: "person.text.rectangle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-name",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyHarnessSessionID",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyHarnessSessionID", "Copy Harness Session ID"),
        keywords: &["agent", "chat", "harness", "session", "id", "identifier", "claude", "codex", "copy"],
        category: "agents",
        symbol: "number",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-harness-session-i-d",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyConversation",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyConversation", "Copy Conversation as Markdown"),
        keywords: &["agent", "chat", "conversation", "transcript", "markdown", "messages", "copy"],
        category: "agents",
        symbol: "text.quote",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-conversation",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copySessionDetails",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copySessionDetails", "Copy Session Details"),
        keywords: &["agent", "chat", "session", "details", "metadata", "cwd", "host", "copy"],
        category: "agents",
        symbol: "doc.text.magnifyingglass",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-session-details",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyWorkingDirectory",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyWorkingDirectory", "Copy Working Directory"),
        keywords: &["agent", "chat", "session", "cwd", "directory", "folder", "path", "copy"],
        category: "agents",
        symbol: "folder",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-working-directory",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyHost",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyHost", "Copy Chat Host"),
        keywords: &["agent", "chat", "session", "host", "machine", "remote", "copy"],
        category: "agents",
        symbol: "network",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-host",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copySessionFilePaths",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copySessionFilePaths", "Copy Session File Paths"),
        keywords: &["agent", "chat", "session", "files", "paths", "claude.json", "settings.json", "config.toml", "transcript", "jsonl", "copy"],
        category: "agents",
        symbol: "doc.on.doc",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-session-file-paths",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyTranscriptFile",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyTranscriptFile", "Copy Transcript File"),
        keywords: &["agent", "chat", "session", "transcript", "jsonl", "rollout", "raw", "claude", "codex", "copy"],
        category: "agents",
        symbol: "doc.plaintext",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-transcript-file",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyHarnessConfigFile",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyHarnessConfigFile", "Copy Harness Config File"),
        keywords: &["agent", "chat", "harness", "config", "claude.json", "config.toml", "claude", "codex", "json", "copy"],
        category: "agents",
        symbol: "gearshape",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-harness-config-file",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyHarnessSettingsFile",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyHarnessSettingsFile", "Copy Harness Settings File"),
        keywords: &["agent", "chat", "harness", "settings", "settings.json", "claude", "json", "copy"],
        category: "agents",
        symbol: "slider.horizontal.3",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-harness-settings-file",
        ..Action::DEFAULT
    },
    Action {
        id: "agentChat.copyAcpmuxSessionFile",
        group: GROUP,
        title: t("ActionCatalog", "action.agentChat.copyAcpmuxSessionFile", "Copy cmux Session File"),
        keywords: &["agent", "chat", "acpmux", "session", "session.json", "json", "record", "copy"],
        category: "agents",
        symbol: "curlybraces",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("clipboard")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-chat-copy-acpmux-session-file",
        ..Action::DEFAULT
    },
];
