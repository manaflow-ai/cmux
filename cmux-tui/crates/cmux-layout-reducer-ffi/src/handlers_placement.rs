//! `cmux-window-rules`' placement handlers over the JSON channel (ops
//! `handlers_placement_*`): how New ▸ Kind ▸ Placement reaches its place,
//! the beside-the-chat steps, a chat column's and a new chat's openings, the
//! dock actions' edges and modes, and the New Tab kinds' actions. The app
//! sends the facts it read and runs the answer.

use cmux_window_rules::handlers_placement::{
    self as rules, BesideFacts, BesideFocusFacts, BesideStepFacts, ChatRouteFacts, ChatSide,
    ColumnTab, DockRefusal, NewAtFacts, NewChatFacts, Respawn,
};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"handlers_placement_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KindPlace<'a> {
    #[serde(borrow, default)]
    kind: Option<&'a str>,
    #[serde(borrow, default)]
    place: Option<&'a str>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoneChat {
    panes: usize,
    #[serde(default)]
    tabs: Vec<ColumnTab>,
    #[serde(default)]
    ignoring_pages: bool,
}

#[derive(Deserialize)]
struct BesideDock {
    #[serde(default)]
    respawn: Option<Respawn>,
}

#[derive(Deserialize)]
struct Side {
    side: ChatSide,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DockedFocus {
    #[serde(default)]
    focus: bool,
    #[serde(default)]
    chat_had_focus: bool,
    #[serde(default)]
    dock_found: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DockAsk<'a> {
    #[serde(borrow, default)]
    action: &'a str,
    #[serde(borrow, default)]
    edge: Option<&'a str>,
    #[serde(borrow, default)]
    mode: Option<&'a str>,
    #[serde(borrow, default)]
    setting_edge: Option<&'a str>,
    #[serde(borrow, default)]
    setting_mode: Option<&'a str>,
}

#[derive(Deserialize)]
struct DockFailure {
    refusal: DockRefusal,
    #[serde(default)]
    undocking: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaneRoute<'a> {
    #[serde(borrow, default)]
    origin: &'a str,
    #[serde(default)]
    names_pane: bool,
}

/// Answers one `handlers_placement_*` op.
pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"handlers_placement_new_at" => json!(rules::new_at(&read::<NewAtFacts>(request)?)),
        b"handlers_placement_new_at_gate" => {
            let ask: KindPlace = read(request)?;
            let place = ask.place.unwrap_or(rules::SUBMENU_PLACE);
            json!({"gate": rules::new_at_gate(ask.kind.ok_or(ERR_INVALID)?, place), "place": place})
        }
        b"handlers_placement_direction" => {
            let ask: KindPlace = read(request)?;
            json!({"direction": rules::direction(ask.place.unwrap_or_default())})
        }
        b"handlers_placement_beside_chat" => {
            json!(rules::beside_chat(&read::<BesideFacts>(request)?))
        }
        b"handlers_placement_beside_step" => {
            json!(rules::beside_step(&read::<BesideStepFacts>(request)?))
        }
        b"handlers_placement_beside_focus" => {
            json!(rules::beside_focus(&read::<BesideFocusFacts>(request)?))
        }
        b"handlers_placement_lone_chat" => {
            let ask: LoneChat = read(request)?;
            json!({"lone": rules::lone_chat(ask.panes, &ask.tabs, ask.ignoring_pages)})
        }
        b"handlers_placement_chat_route" => {
            json!(rules::chat_route(&read::<ChatRouteFacts>(request)?))
        }
        b"handlers_placement_beside_dock_open" => {
            json!(rules::beside_dock_open(read::<BesideDock>(request)?.respawn.as_ref()))
        }
        b"handlers_placement_new_chat_opening" => {
            json!(rules::new_chat_opening(&read::<NewChatFacts>(request)?))
        }
        b"handlers_placement_agent_tab_target" => {
            json!(rules::agent_tab_target(read::<Side>(request)?.side))
        }
        b"handlers_placement_docked_focus" => {
            let ask: DockedFocus = read(request)?;
            json!(rules::docked_focus(ask.focus, ask.chat_had_focus, ask.dock_found))
        }
        b"handlers_placement_dock_settings" => {
            let ask: DockAsk = read(request)?;
            json!(rules::dock_settings(ask.setting_edge, ask.setting_mode))
        }
        b"handlers_placement_dock_ask" => {
            let ask: DockAsk = read(request)?;
            let settings = rules::dock_settings(ask.setting_edge, ask.setting_mode);
            json!(rules::dock_ask(ask.action, ask.edge, ask.mode, &settings).ok_or(ERR_INVALID)?)
        }
        b"handlers_placement_dock_failure" => {
            let ask: DockFailure = read(request)?;
            json!(rules::dock_failure(ask.refusal, ask.undocking))
        }
        b"handlers_placement_new_tab_action" => {
            let ask: KindPlace = read(request)?;
            json!({"action": rules::new_tab_action(ask.kind.ok_or(ERR_INVALID)?)})
        }
        b"handlers_placement_selected_kind" => {
            let ask: KindPlace = read(request)?;
            json!({"selectedKind": rules::selected_kind(ask.kind)})
        }
        b"handlers_placement_pane_route" => {
            let ask: PaneRoute = read(request)?;
            json!({"followsSetting": rules::pane_route_follows_setting(ask.origin, ask.names_pane)})
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
