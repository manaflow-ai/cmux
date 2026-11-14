// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `VoiceRoomActionCatalog` actions.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "VoiceRoomActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "voiceRoom.open",
        group: GROUP,
        title: t("ActionCatalog", "action.voiceRoom.open", "Open Voice Room"),
        keywords: &["voice", "room", "call", "meeting", "talk", "transcribe", "screen", "chief", "labs"],
        category: "agents",
        symbol: "person.wave.2",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action voice-room-open",
        ..Action::DEFAULT
    },
    Action {
        id: "voiceRoom.stop",
        group: GROUP,
        title: t("ActionCatalog", "action.voiceRoom.stop", "Stop Voice Room"),
        keywords: &["voice", "room", "call", "meeting", "stop", "recording", "mic", "labs"],
        category: "agents",
        symbol: "stop.circle",
        surface_plan: SurfacePlan { cli: Some(Decision::Exempt("guiOnly")), context_menu_exemption: Some("noObject"), ..SurfacePlan::DEFAULT },
        cli_name: "action voice-room-stop",
        ..Action::DEFAULT
    },
];
