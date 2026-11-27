// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentTranscriptActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentTranscriptActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agentPane.previousTurn",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.previousTurn", "Previous Turn"),
        keywords: &["agent", "chat", "turn", "prompt", "message", "previous", "up", "minimap"],
        default_shortcut: Some(Shortcut { key: "\u{f700}", modifiers: CTRL | OPT }),
        category: "agents",
        symbol: "chevron.up",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-pane-previous-turn",
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.nextTurn",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.nextTurn", "Next Turn"),
        keywords: &["agent", "chat", "turn", "prompt", "message", "next", "down", "minimap"],
        default_shortcut: Some(Shortcut { key: "\u{f701}", modifiers: CTRL | OPT }),
        category: "agents",
        symbol: "chevron.down",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-pane-next-turn",
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.previousBookmarkedPrompt",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.previousBookmarkedPrompt", "Previous Bookmarked Prompt"),
        keywords: &["agent", "chat", "bookmark", "bookmarked", "prompt", "turn", "previous", "minimap"],
        category: "agents",
        symbol: "bookmark",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-pane-previous-bookmarked-prompt",
        ..Action::DEFAULT
    },
    Action {
        id: "agentPane.nextBookmarkedPrompt",
        group: GROUP,
        title: t("ActionCatalog", "action.agentPane.nextBookmarkedPrompt", "Next Bookmarked Prompt"),
        keywords: &["agent", "chat", "bookmark", "bookmarked", "prompt", "turn", "next", "minimap"],
        category: "agents",
        symbol: "bookmark.fill",
        surfaces: PALETTE | KEYBOARD,
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        requires: &["agentPaneFocused"],
        targets: &["pane"],
        cli_name: "action agent-pane-next-bookmarked-prompt",
        ..Action::DEFAULT
    },
];
