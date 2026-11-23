// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `MusicActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "MusicActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "music.open",
        group: GROUP,
        title: t("MusicActions", "action.music.open", "Play Music…"),
        keywords: &["music", "songs", "audio", "player", "play", "folder", "mp3", "now playing"],
        category: "window",
        symbol: "music.note",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        arguments: &[args::PATH.optional(), args::URL.optional()],
        cli_name: "action music-open",
        ..Action::DEFAULT
    },
    Action {
        id: "music.stop",
        group: GROUP,
        title: t("MusicActions", "action.music.stop", "Stop Music"),
        keywords: &["music", "songs", "audio", "player", "stop", "now playing"],
        category: "window",
        symbol: "stop.fill",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action music-stop",
        ..Action::DEFAULT
    },
];
