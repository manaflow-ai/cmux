// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentHarnessActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentHarnessActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agent.harness.add",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.harness.add", "Add ACP Agent…"),
        keywords: &["agent", "harness", "acp", "acpmux", "custom", "bring your own", "add", "install", "profile"],
        category: "agents",
        symbol: "plus.app",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::COMMAND_3.optional(), args::ARGS.optional(), args::REGISTRY.optional(), args::EXAMPLE.optional(), args::ID.optional(), args::NAME_5.optional(), args::PROTOCOL.optional(), args::REPLACE.optional()],
        cli_name: "agent add-harness",
        ..Action::DEFAULT
    },
    Action {
        id: "agent.harness.addFromRegistry",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.harness.addFromRegistry", "Add Agent from ACP Registry…"),
        keywords: &["agent", "harness", "acp", "registry", "install", "gemini", "cursor", "goose", "add"],
        category: "agents",
        symbol: "shippingbox",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action agent-harness-add-from-registry",
        ..Action::DEFAULT
    },
    Action {
        id: "agent.harness.remove",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.harness.remove", "Remove Agent…"),
        keywords: &["agent", "harness", "acp", "remove", "delete", "uninstall", "profile"],
        category: "agents",
        symbol: "minus.square",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::ID.optional()],
        cli_name: "agent remove-harness",
        ..Action::DEFAULT
    },
    Action {
        id: "agent.harness.restore",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.harness.restore", "Restore Removed Agent"),
        keywords: &["agent", "harness", "restore", "undo", "removed"],
        category: "agents",
        symbol: "arrow.uturn.backward",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::BACKUP.optional()],
        cli_name: "agent restore-harness",
        ..Action::DEFAULT
    },
    Action {
        id: "agent.harness.doctor",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.harness.doctor", "Check Agent…"),
        keywords: &["agent", "harness", "acp", "doctor", "check", "test", "diagnose", "handshake"],
        category: "agents",
        symbol: "stethoscope",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::ID.optional()],
        cli_name: "agent check-harness",
        ..Action::DEFAULT
    },
    Action {
        id: "agent.harness.setIcon",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.harness.setIcon", "Set Agent Icon…"),
        keywords: &["agent", "harness", "acp", "icon", "emoji", "symbol", "logo", "mark", "profile"],
        category: "agents",
        symbol: "face.smiling",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::HARNESS_PROFILE, args::HARNESS_ICON],
        cli_name: "action agent-harness-set-icon",
        ..Action::DEFAULT
    },
    Action {
        id: "agent.harness.updateAll",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.harness.updateAll", "Update Agent CLIs"),
        keywords: &["agent", "harness", "cli", "update", "upgrade", "version", "outdated", "npm", "brew", "codex", "claude", "gemini"],
        category: "agents",
        symbol: "arrow.down.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::ID.optional(), args::INTENT.optional()],
        cli_name: "action agent-harness-update-all",
        is_person_only: true,
        ..Action::DEFAULT
    },
];
