// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CmuxHelperActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "CmuxHelperActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "helperHost.showStatus",
        group: GROUP,
        title: t("ActionCatalog", "action.helperHost.showStatus", "cmux Computer Use: Show Status"),
        keywords: &["cmux computer use", "screen sharing", "computer use", "permissions", "accessibility", "screen recording", "status"],
        category: "remote",
        symbol: "display.and.arrow.down",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "helper-host show-status",
        ..Action::DEFAULT
    },
    Action {
        id: "helperHost.refreshPermissions",
        group: GROUP,
        title: t("ActionCatalog", "action.helperHost.refreshPermissions", "cmux Computer Use: Refresh Permissions"),
        keywords: &["cmux computer use", "permissions", "accessibility", "screen recording", "grant", "refresh", "tcc"],
        category: "remote",
        symbol: "arrow.clockwise",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "helper-host refresh-permissions",
        ..Action::DEFAULT
    },
    Action {
        id: "helperHost.allowAccessibility",
        group: GROUP,
        title: t("ActionCatalog", "action.helperHost.allowAccessibility", "cmux Computer Use: Allow Accessibility"),
        keywords: &["cmux computer use", "accessibility", "permission", "grant", "tcc", "computer use", "screen sharing"],
        category: "remote",
        symbol: "accessibility",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "helper-host allow-accessibility",
        ..Action::DEFAULT
    },
    Action {
        id: "helperHost.allowScreenRecording",
        group: GROUP,
        title: t("ActionCatalog", "action.helperHost.allowScreenRecording", "cmux Computer Use: Allow Screen Recording"),
        keywords: &["cmux computer use", "screen recording", "permission", "grant", "tcc", "computer use", "screen sharing"],
        category: "remote",
        symbol: "record.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "helper-host allow-screen-recording",
        ..Action::DEFAULT
    },
    Action {
        id: "helperHost.restartComputerUse",
        group: GROUP,
        title: t("ActionCatalog", "action.helperHost.restartComputerUse", "cmux Computer Use: Restart Computer Use"),
        keywords: &["cmux computer use", "computer use", "restart", "worker", "agents"],
        category: "remote",
        symbol: "arrow.clockwise.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "helper-host restart-computer-use",
        ..Action::DEFAULT
    },
    Action {
        id: "helperHost.restartScreenSharing",
        group: GROUP,
        title: t("ActionCatalog", "action.helperHost.restartScreenSharing", "cmux Computer Use: Restart Screen Sharing"),
        keywords: &["cmux computer use", "screen sharing", "mac screen", "restart", "worker"],
        category: "remote",
        symbol: "arrow.clockwise.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "helper-host restart-screen-sharing",
        ..Action::DEFAULT
    },
    Action {
        id: "helperHost.stopScreenSession",
        group: GROUP,
        title: t("ActionCatalog", "action.helperHost.stopScreenSession", "cmux Computer Use: End Screen Sharing Session"),
        keywords: &["cmux computer use", "screen sharing", "mac screen", "stop", "end", "disconnect", "viewer", "session"],
        category: "remote",
        symbol: "stop.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "helper-host stop-screen-session",
        ..Action::DEFAULT
    },
    Action {
        id: "macScreen.shareThisMac",
        group: GROUP,
        title: t("ActionCatalog", "action.macScreen.shareThisMac", "Share This Mac"),
        keywords: &["mac", "screen", "sharing", "share", "screen share", "share screen", "remote desktop", "vnc", "host", "turn on", "enable", "allow", "device", "remote", "iphone"],
        category: "remote",
        symbol: "display",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "mac-screen share-this-mac",
        ..Action::DEFAULT
    },
    Action {
        id: "macScreen.stopSharingThisMac",
        group: GROUP,
        title: t("ActionCatalog", "action.macScreen.stopSharingThisMac", "Turn Off Sharing This Mac"),
        keywords: &["mac", "screen", "sharing", "screen share", "share screen", "remote desktop", "vnc", "stop", "turn off", "off", "disable", "device", "remote"],
        category: "remote",
        symbol: "display.trianglebadge.exclamationmark",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "mac-screen stop-sharing-this-mac",
        ..Action::DEFAULT
    },
    Action {
        id: "macScreen.deviceAccess",
        group: GROUP,
        title: t("ActionCatalog", "action.macScreen.deviceAccess", "Set Device Access to This Mac…"),
        keywords: &["mac", "screen", "sharing", "device", "access", "permission", "view", "view only", "full control", "control", "ask", "none", "screen share", "vnc"],
        category: "remote",
        symbol: "person.badge.key",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "mac-screen device-access",
        ..Action::DEFAULT
    },
];
