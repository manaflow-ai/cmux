// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `NotificationSoundActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "NotificationSoundActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "notifications.setWorkspaceSound",
        group: GROUP,
        title: t("Localizable", "action.notifications.setWorkspaceSound", "Notification Sound for Workspace"),
        keywords: &["sound", "chime", "alert", "audio", "mute", "volume", "notifications", "workspace"],
        category: "notifications",
        symbol: "speaker.wave.2",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 116).style("choices").folder("options").label(t("Localizable", "menu.notificationSound", "Notification Sound"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::SOUND.optional(), args::EVENT.optional(), args::VOLUME.optional(), args::FILE.optional()],
        targets: &["workspace"],
        cli_name: "notification set-workspace-sound",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.setGroupSound",
        group: GROUP,
        title: t("Localizable", "action.notifications.setGroupSound", "Notification Sound for Group"),
        keywords: &["sound", "chime", "alert", "audio", "mute", "volume", "notifications", "group", "section"],
        category: "notifications",
        symbol: "speaker.wave.2",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceGroup", "identity", 110).style("choices").folder("options").label(t("Localizable", "menu.notificationSound", "Notification Sound"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::SOUND.optional(), args::EVENT.optional(), args::VOLUME.optional(), args::FILE.optional()],
        targets: &["workspace-group"],
        cli_name: "notification set-group-sound",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.setAgentSound",
        group: GROUP,
        title: t("Localizable", "action.notifications.setAgentSound", "Notification Sound for Agent…"),
        keywords: &["sound", "chime", "alert", "audio", "mute", "volume", "notifications", "agent", "claude", "codex", "harness"],
        category: "notifications",
        symbol: "speaker.wave.2",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::AGENT_2, args::SOUND.optional(), args::EVENT.optional(), args::VOLUME.optional(), args::FILE.optional()],
        cli_name: "notification set-agent-sound",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.setEventSound",
        group: GROUP,
        title: t("Localizable", "action.notifications.setEventSound", "Notification Sound for Event…"),
        keywords: &["sound", "chime", "alert", "audio", "mute", "volume", "notifications", "event", "finished", "needs input", "permission", "error", "bell"],
        category: "notifications",
        symbol: "speaker.wave.2",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::EVENT_2, args::SOUND.optional(), args::FILE.optional()],
        cli_name: "notification set-event-sound",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.previewSound",
        group: GROUP,
        title: t("Localizable", "action.notifications.previewSound", "Preview Notification Sound"),
        keywords: &["sound", "chime", "alert", "audio", "mute", "volume", "notifications", "preview", "test", "play", "hear"],
        category: "notifications",
        symbol: "play.circle",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 117).folder("options")], ..SurfacePlan::DEFAULT },
        arguments: &[args::EVENT.optional()],
        targets: &["workspace"],
        cli_name: "notification preview-sound",
        ..Action::DEFAULT
    },
    Action {
        id: "notifications.importSound",
        group: GROUP,
        title: t("Localizable", "action.notifications.importSound", "Import Notification Sound…"),
        keywords: &["sound", "chime", "alert", "audio", "mute", "volume", "notifications", "import", "custom", "file", "own"],
        category: "notifications",
        symbol: "square.and.arrow.down",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::FILE.optional()],
        cli_name: "notification import-sound",
        ..Action::DEFAULT
    },
];
