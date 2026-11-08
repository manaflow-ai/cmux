// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CmuxRemoteActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "CmuxRemoteActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "remote.showStatus",
        group: GROUP,
        title: t("ActionCatalog", "action.remote.showStatus", "cmux Remote: Show Status"),
        keywords: &["cmux remote", "screen sharing", "computer use", "permissions", "accessibility", "screen recording", "status"],
        category: "remote",
        symbol: "display.and.arrow.down",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote show-status",
        ..Action::DEFAULT
    },
    Action {
        id: "remote.refreshPermissions",
        group: GROUP,
        title: t("ActionCatalog", "action.remote.refreshPermissions", "cmux Remote: Refresh Permissions"),
        keywords: &["cmux remote", "permissions", "accessibility", "screen recording", "grant", "refresh", "tcc"],
        category: "remote",
        symbol: "arrow.clockwise",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote refresh-permissions",
        ..Action::DEFAULT
    },
    Action {
        id: "remote.allowAccessibility",
        group: GROUP,
        title: t("ActionCatalog", "action.remote.allowAccessibility", "cmux Remote: Allow Accessibility"),
        keywords: &["cmux remote", "accessibility", "permission", "grant", "tcc", "computer use", "screen sharing"],
        category: "remote",
        symbol: "accessibility",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote allow-accessibility",
        ..Action::DEFAULT
    },
    Action {
        id: "remote.allowScreenRecording",
        group: GROUP,
        title: t("ActionCatalog", "action.remote.allowScreenRecording", "cmux Remote: Allow Screen Recording"),
        keywords: &["cmux remote", "screen recording", "permission", "grant", "tcc", "computer use", "screen sharing"],
        category: "remote",
        symbol: "record.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote allow-screen-recording",
        ..Action::DEFAULT
    },
    Action {
        id: "remote.restartComputerUse",
        group: GROUP,
        title: t("ActionCatalog", "action.remote.restartComputerUse", "cmux Remote: Restart Computer Use"),
        keywords: &["cmux remote", "computer use", "restart", "worker", "agents"],
        category: "remote",
        symbol: "arrow.clockwise.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote restart-computer-use",
        ..Action::DEFAULT
    },
    Action {
        id: "remote.restartScreenSharing",
        group: GROUP,
        title: t("ActionCatalog", "action.remote.restartScreenSharing", "cmux Remote: Restart Screen Sharing"),
        keywords: &["cmux remote", "screen sharing", "mac screen", "restart", "worker"],
        category: "remote",
        symbol: "arrow.clockwise.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote restart-screen-sharing",
        ..Action::DEFAULT
    },
    Action {
        id: "macScreen.shareThisMac",
        group: GROUP,
        title: t("ActionCatalog", "action.macScreen.shareThisMac", "Share This Mac"),
        keywords: &["mac", "screen", "sharing", "share", "allow", "device", "remote", "iphone"],
        category: "remote",
        symbol: "display",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote share-this-mac",
        ..Action::DEFAULT
    },
    Action {
        id: "macScreen.stopSharingThisMac",
        group: GROUP,
        title: t("ActionCatalog", "action.macScreen.stopSharingThisMac", "Turn Off Sharing This Mac"),
        keywords: &["mac", "screen", "sharing", "stop", "off", "disable", "device", "remote"],
        category: "remote",
        symbol: "display.trianglebadge.exclamationmark",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote stop-sharing-this-mac",
        ..Action::DEFAULT
    },
    Action {
        id: "macScreen.deviceAccess",
        group: GROUP,
        title: t("ActionCatalog", "action.macScreen.deviceAccess", "Set Device Access to This Mac…"),
        keywords: &["mac", "screen", "sharing", "device", "access", "permission", "view", "full control", "ask", "none"],
        category: "remote",
        symbol: "person.badge.key",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "remote device-access",
        ..Action::DEFAULT
    },
];
