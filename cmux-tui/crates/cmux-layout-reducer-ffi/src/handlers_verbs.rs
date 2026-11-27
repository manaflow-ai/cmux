//! The verb handlers' small rules over the JSON channel (ops `handlers_verbs_*`,
//! `cmux_window_rules::handlers_verbs`): Forward Port's `--port`, List Forwarded
//! Ports' text, Switch Host's pick, Open as Pane's folder, a workspace's PR links,
//! Duplicate Tab's plan, a tab move that becomes a split, a group walk and edge, and
//! where Remove from Group puts a workspace, and a Space move's index.

use cmux_window_rules::handlers_verbs as verbs;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"handlers_verbs_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Port {
    #[serde(default)]
    port: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Forwards {
    #[serde(default)]
    forwards: Vec<verbs::Forward>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PrLinks {
    #[serde(default)]
    entries: Vec<verbs::StatusLinks>,
    pr_key: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Duplicates {
    #[serde(default)]
    tabs: Vec<verbs::DuplicateTab>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MoveSplit {
    action: String,
    tabs_in_pane: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroupWalk {
    count: usize,
    #[serde(default)]
    active: Option<usize>,
    offset: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroupEdge {
    direction: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Ungroup {
    #[serde(default)]
    ungrouped_first: bool,
    #[serde(default)]
    first_unpinned_group: Option<usize>,
    node_count: usize,
    group_node: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RoomMove {
    verb: String,
    from: usize,
    count: usize,
    #[serde(default)]
    position: Option<i64>,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"handlers_verbs_port_argument" => {
            json!({"port": verbs::port_argument(&read::<Port>(request)?.port)})
        }
        b"handlers_verbs_port_list_text" => {
            json!({"text": verbs::port_list_text(&read::<Forwards>(request)?.forwards)})
        }
        b"handlers_verbs_switch_host" => {
            serde_json::to_value(verbs::switch_host(&read(request)?)).map_err(|_| ERR_INVALID)?
        }
        b"handlers_verbs_pane_folder" => json!({"folder": verbs::pane_folder(&read(request)?)}),
        b"handlers_verbs_pr_links" => {
            let request: PrLinks = read(request)?;
            json!({"links": verbs::pr_links(&request.entries, &request.pr_key)})
        }
        b"handlers_verbs_duplicate_plan" => {
            serde_json::to_value(verbs::duplicate_plan(&read::<Duplicates>(request)?.tabs))
                .map_err(|_| ERR_INVALID)?
        }
        b"handlers_verbs_move_split" => {
            let request: MoveSplit = read(request)?;
            json!({"direction": verbs::move_split(&request.action, request.tabs_in_pane)})
        }
        b"handlers_verbs_group_walk" => {
            let request: GroupWalk = read(request)?;
            json!({"order": verbs::group_walk(request.count, request.active, request.offset)})
        }
        b"handlers_verbs_group_edge" => {
            json!({"edge": verbs::group_edge(&read::<GroupEdge>(request)?.direction)})
        }
        b"handlers_verbs_ungroup_index" => {
            let r: Ungroup = read(request)?;
            json!({"index": verbs::ungroup_index(r.ungrouped_first, r.first_unpinned_group, r.node_count, r.group_node)})
        }
        b"handlers_verbs_room_move" => {
            let r: RoomMove = read(request)?;
            json!({"index": verbs::room_move(&r.verb, r.from, r.count, r.position)})
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
