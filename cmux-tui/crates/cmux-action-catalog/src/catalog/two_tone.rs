// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `TwoToneActionCatalog` actions: one per `appearance.twoTone` value.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "TwoToneActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "appearance.twoTone.off",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.off", "Two-Tone: Off"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "off", "none", "single", "one tone"],
        category: "settings",
        symbol: "rectangle",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-off",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.auto",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.auto", "Two-Tone: From Theme"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "auto", "from theme", "theme", "automatic"],
        category: "settings",
        symbol: "paintpalette",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-from-theme",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.inkSakura",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.inkSakura", "Two-Tone: Ink & Sakura"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "ink", "sakura", "cherry blossom", "pink", "dark", "japanese"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-ink-sakura",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.charcoalRose",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.charcoalRose", "Two-Tone: Charcoal & Rose"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "charcoal", "rose", "pink", "dark", "grey"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-charcoal-rose",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.inkMagenta",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.inkMagenta", "Two-Tone: Ink Blue & Magenta"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "ink", "blue", "magenta", "purple", "dark"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-ink-magenta",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.creamForest",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.creamForest", "Two-Tone: Cream & Forest"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "cream", "forest", "green", "light"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-cream-forest",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.navySand",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.navySand", "Two-Tone: Navy & Sand"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "navy", "sand", "blue", "beige"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-navy-sand",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.boneOxblood",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.boneOxblood", "Two-Tone: Bone & Oxblood"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "bone", "oxblood", "red", "burgundy", "light"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-bone-oxblood",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.slateMatcha",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.slateMatcha", "Two-Tone: Slate & Matcha"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "slate", "matcha", "green", "grey", "tea"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-slate-matcha",
        ..Action::DEFAULT
    },
    Action {
        id: "appearance.twoTone.plumAmber",
        group: GROUP,
        title: t("SettingsActions", "action.appearance.twoTone.plumAmber", "Two-Tone: Plum & Amber"),
        keywords: &["two-tone", "two tone", "duotone", "sidebar", "tone", "colors", "appearance", "look", "plum", "amber", "purple", "orange", "gold"],
        category: "settings",
        symbol: "rectangle.lefthalf.filled",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noObject"), mcp_exemption: Some("systemChange"), ..SurfacePlan::DEFAULT },
        cli_name: "settings two-tone-plum-amber",
        ..Action::DEFAULT
    },
];
