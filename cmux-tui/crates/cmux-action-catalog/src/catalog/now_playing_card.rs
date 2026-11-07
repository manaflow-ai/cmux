// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `NowPlayingCardActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "NowPlayingCardActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "nowPlaying.playPause",
        group: GROUP,
        title: t("MusicActions", "action.nowPlaying.playPause", "Play/Pause Media"),
        keywords: &["media", "music", "now playing", "play", "pause", "resume", "song"],
        category: "window",
        symbol: "playpause",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("nowPlayingCard", "navigate", 0).label(t("MusicActions", "menu.nowPlaying.playPause", "Play/Pause"))], ..SurfacePlan::DEFAULT },
        cli_name: "media play-pause",
        ..Action::DEFAULT
    },
    Action {
        id: "tab.pictureInPicture",
        group: GROUP,
        title: t("MusicActions", "action.tab.pictureInPicture", "Picture in Picture"),
        keywords: &["pip", "picture in picture", "video", "float", "floating", "pop out", "always on top", "media", "tab"],
        category: "tab",
        symbol: "pip",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "identity", 211).folder("options"), Placement::at("nowPlayingCard", "navigate", 10)], ..SurfacePlan::DEFAULT },
        targets: &["tab"],
        cli_name: "media picture-in-picture",
        ..Action::DEFAULT
    },
    Action {
        id: "nowPlaying.hideCard",
        group: GROUP,
        title: t("MusicActions", "action.nowPlaying.hideCard", "Hide Media Card"),
        keywords: &["media", "music", "now playing", "player", "card", "hide", "dismiss", "close", "sidebar"],
        category: "window",
        symbol: "xmark",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("nowPlayingCard", "close", 0).label(t("MusicActions", "menu.nowPlaying.hide", "Hide"))], ..SurfacePlan::DEFAULT },
        cli_name: "media hide-card",
        ..Action::DEFAULT
    },
    Action {
        id: "nowPlaying.hideCardUntilRelaunch",
        group: GROUP,
        title: t("MusicActions", "action.nowPlaying.hideCardUntilRelaunch", "Hide Media Card Until Relaunch"),
        keywords: &["media", "music", "now playing", "player", "card", "hide", "dismiss", "relaunch", "sidebar"],
        category: "window",
        symbol: "eye.slash",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("nowPlayingCard", "close", 10).label(t("MusicActions", "menu.nowPlaying.hideUntilRelaunch", "Hide Until Relaunch"))], ..SurfacePlan::DEFAULT },
        cli_name: "media hide-card-until-relaunch",
        ..Action::DEFAULT
    },
    Action {
        id: "nowPlaying.disableCard",
        group: GROUP,
        title: t("MusicActions", "action.nowPlaying.disableCard", "Never Show Media Card"),
        keywords: &["media", "music", "now playing", "player", "card", "hide", "never", "turn off", "disable", "sidebar"],
        category: "settings",
        symbol: "eye.slash.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("nowPlayingCard", "close", 100)], ..SurfacePlan::DEFAULT },
        cli_name: "media disable-card",
        ..Action::DEFAULT
    },
    Action {
        id: "nowPlaying.showCard",
        group: GROUP,
        title: t("MusicActions", "action.nowPlaying.showCard", "Show Media Card"),
        keywords: &["media", "music", "now playing", "player", "card", "show", "turn on", "enable", "sidebar"],
        category: "settings",
        symbol: "music.note.list",
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("sidebarFooter", "view", 120)], ..SurfacePlan::DEFAULT },
        cli_name: "media show-card",
        ..Action::DEFAULT
    },
];
