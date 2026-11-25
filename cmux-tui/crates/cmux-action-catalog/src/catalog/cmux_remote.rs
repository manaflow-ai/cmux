// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CmuxRemoteActionCatalog` actions.

use super::args;
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
        id: "remote.setQuality",
        group: GROUP,
        title: t("ActionCatalog", "action.remote.setQuality", "Set Screen Sharing Quality…"),
        keywords: &["screen sharing", "screen share", "remote desktop", "vnc", "quality", "sharp text", "smooth motion", "low bandwidth", "auto", "bitrate", "resolution", "lag"],
        category: "remote",
        symbol: "dial.medium",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("guiOnly"), ..SurfacePlan::DEFAULT },
        arguments: &[args::REMOTE_QUALITY],
        targets: &["tab"],
        cli_name: "action remote-set-quality",
        ..Action::DEFAULT
    },
    Action {
        id: "macScreen.shareThisMac",
        group: GROUP,
        title: t("ActionCatalog", "action.macScreen.shareThisMac", "Share This Mac"),
        keywords: &["mac", "screen", "sharing", "share", "screen share", "share screen", "remote desktop", "vnc", "host", "turn on", "enable", "allow", "device", "remote", "iphone"],
        category: "remote",
        symbol: "display",
        surfaces: PALETTE | CONTEXT_MENU,
        // This Mac's sidebar header menu, beside its hover-only screen button (Leo 2026-11-14: "in
        // screen sharing we also want the interaction pathways better"). The app shows the row only
        // on the header whose screen button is Share (This Mac's).
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("ownerVerb")), context_menus: &[Placement::at("machineSection", "connection", 150)], ..SurfacePlan::DEFAULT },
        cli_name: "remote share-this-mac",
        ..Action::DEFAULT
    },
    Action {
        id: "machine.viewScreen",
        group: GROUP,
        title: t("ActionCatalog", "action.machine.viewScreen", "View Screen"),
        description: Some("Shows the machine's screen from its sidebar header's menu, as the header's View screen button does: a Cloud machine's desktop (cloudOpenDesktop), or a Mac's shared screen in a Screen Sharing tab. Offered only on a header that shows View screen: a Cloud machine, or a Mac with an online screen device; a Linux or unidentified SSH machine has none. The palette and CLI reach the same screens through cloud open-desktop and Screen Sharing."),
        keywords: &["machine", "screen", "screen sharing", "screen share", "view", "remote desktop", "vnc", "desktop", "display"],
        category: "remote",
        symbol: "display",
        surfaces: CONTEXT_MENU,
        surface_plan: SurfacePlan { palette: Decision::Exempt("duplicateOfDefault"), cli: Some(Decision::Exempt("guiOnly")), context_menus: &[Placement::at("machineSection", "connection", 151)], ..SurfacePlan::DEFAULT },
        targets: &["machine"],
        cli_name: "machine view-screen",
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
        cli_name: "remote stop-sharing-this-mac",
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
        cli_name: "remote device-access",
        ..Action::DEFAULT
    },
];
