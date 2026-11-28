//! The `dock` area: what the Home dock holds, keeps and moves, as plans computed from state
//! (CmuxNextHomeEngine's HomeDock, HomeChiefTabKey, HomeChiefActionPlan, HomeSidebarLaunchCache,
//! HomePinMigration, HomeSidebarSource's pin rules, ChiefTeleport and HomeChiefDirectMessages).
//! The app keeps the I/O; each op reads the state it sends.

pub mod action_plan;
pub mod chief_move;
pub mod chief_tab_key;
pub mod direct_messages;
pub mod home_dock;
pub mod launch_cache;
pub mod pins;
pub mod tree;

use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use tree::{Pane, Screen, Tab, Workspace};

pub const OPS: &[&str] = &[
    "page_tab",
    "page_is_docked",
    "is_chief_tab",
    "keeps_tab",
    "is_placeholder_shell",
    "placeholder_shell",
    "ensure_plan",
    "pin_plan",
    "allow_tabs_plan",
    "ids_ready",
    "placeholder_plan",
    "reveal_when_docked",
    "opens_link",
    "chief_tab_open",
    "chief_tab_key_step",
    "chief_action_plan",
    "launch_cache_fingerprint",
    "launch_cache_path",
    "launch_cache_inbox_key",
    "launch_cache_load_accepts",
    "launch_cache_step",
    "pin_migration_run",
    "pin_migration_adopted",
    "pin_drop",
    "sidebar_shows",
    "sidebar_hide",
    "sidebar_owner_of",
    "sidebar_place",
    "sidebar_mark_unread",
    "move_targets",
    "move_plan",
    "move_rollback",
    "move_target_home",
    "chief_dm_key",
    "chief_dm_request",
    "chief_dm_records",
    "chief_dm_missing",
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HomeReq {
    #[serde(default)]
    workspace: Option<Workspace>,
    #[serde(default)]
    capabilities: home_dock::Capabilities,
    #[serde(default)]
    fresh: bool,
    #[serde(default)]
    dock_takes_tabs: bool,
    #[serde(default)]
    checked: bool,
    #[serde(default)]
    checked_ever: bool,
    #[serde(default)]
    home: String,
    #[serde(default)]
    classic: bool,
    #[serde(default)]
    ready: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabReq {
    tab: Tab,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenReq {
    screen: Screen,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeepsReq {
    id: String,
    workspace: Workspace,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LinkReq {
    #[serde(default)]
    scheme: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PageTabReply<'a> {
    tab: &'a Tab,
    pane: &'a Pane,
    #[serde(rename = "screenResourceID")]
    screen_resource_id: Option<&'a String>,
    docked: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChiefOpenReq {
    chief: String,
    #[serde(default)]
    workspaces: Vec<Workspace>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyStepReq {
    #[serde(default)]
    state: chief_tab_key::KeyState,
    event: chief_tab_key::KeyEvent,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ActionPlanReq {
    front: action_plan::Front,
    #[serde(default)]
    chiefs: Vec<action_plan::Chief>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShapeReq {
    shape: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnerReq {
    owner: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnersReq {
    owners: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoadReq {
    schema: String,
    file_schema: String,
    account: String,
    file_account: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SaveStepReq {
    #[serde(default)]
    state: launch_cache::SaveState,
    event: launch_cache::SaveEvent,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MigrationRunReq {
    #[serde(default)]
    cloud: Option<String>,
    #[serde(default)]
    rows: Vec<pins::PinRow>,
    #[serde(default)]
    kept: Vec<String>,
    #[serde(default)]
    sending: BTreeSet<String>,
    #[serde(default)]
    refused: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MigrationAdoptedReq {
    ids: Vec<String>,
    #[serde(default)]
    accepted: Vec<String>,
    #[serde(default)]
    sending: BTreeSet<String>,
    #[serde(default)]
    refused: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PinDropReq {
    #[serde(default)]
    pins: pins::Pins,
    gone: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShowsReq {
    rows: Vec<pins::SeqRow>,
    #[serde(default)]
    hidden: BTreeMap<String, u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HideReq {
    id: String,
    #[serde(default)]
    rows: Vec<pins::SeqRow>,
    #[serde(default)]
    hidden: BTreeMap<String, u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnerOfReq {
    id: String,
    #[serde(default)]
    inboxes: Vec<Option<Vec<String>>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaceReq {
    #[serde(default)]
    pinned: Vec<String>,
    id: String,
    index: i64,
    base: u64,
    #[serde(default)]
    inboxes: Vec<Option<Vec<String>>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MarkReq {
    on: bool,
    id: String,
    #[serde(default)]
    marks: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TargetsReq {
    local_home: String,
    #[serde(default)]
    hosts: Vec<chief_move::Host>,
    cloud: chief_move::Cloud,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MovePlanReq {
    to: String,
    kind: chief_move::Kind,
    source_home: String,
    #[serde(default)]
    target_home: String,
    #[serde(default)]
    token_file: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RollbackReq {
    source_home: String,
    #[serde(default)]
    token_file: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TargetHomeReq {
    home: String,
    user_home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DmKeyReq {
    chief: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DmRequestReq {
    me: Value,
    chief: String,
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DmRecordsReq {
    listed: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DmMissingReq {
    all: Value,
    #[serde(default)]
    listed: Vec<String>,
}

/// Runs the dock op `name` on `request`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "page_tab" => {
            let req: HomeReq = ops::parse(request)?;
            let placed = req.workspace.as_ref().and_then(home_dock::page_tab);
            ops::reply(&placed.map(|placed| PageTabReply {
                tab: placed.tab,
                pane: placed.pane,
                screen_resource_id: placed.screen.resource_id.as_ref(),
                docked: home_dock::is_docked(placed.pane, placed.screen),
            }))
        }
        "page_is_docked" => {
            let req: HomeReq = ops::parse(request)?;
            ops::reply(&req.workspace.as_ref().is_some_and(home_dock::page_is_docked))
        }
        "is_chief_tab" => {
            let req: TabReq = ops::parse(request)?;
            ops::reply(&home_dock::is_chief_tab(&req.tab))
        }
        "keeps_tab" => {
            let req: KeepsReq = ops::parse(request)?;
            ops::reply(&home_dock::keeps_tab(&req.id, &req.workspace))
        }
        "is_placeholder_shell" => {
            let req: TabReq = ops::parse(request)?;
            ops::reply(&home_dock::is_placeholder_shell(&req.tab, &req.home))
        }
        "placeholder_shell" => {
            let req: ScreenReq = ops::parse(request)?;
            ops::reply(&home_dock::placeholder_shell(&req.screen, &req.home).map(|tab| tab.surface))
        }
        "ensure_plan" => {
            let req: HomeReq = ops::parse(request)?;
            ops::reply(&home_dock::ensure_plan(req.workspace.as_ref(), req.capabilities))
        }
        "pin_plan" => {
            let req: HomeReq = ops::parse(request)?;
            ops::reply(&home_dock::pin_plan(req.workspace.as_ref(), req.capabilities))
        }
        "allow_tabs_plan" => {
            let req: HomeReq = ops::parse(request)?;
            ops::reply(&home_dock::allow_tabs_plan(
                req.workspace.as_ref(),
                req.capabilities,
                req.fresh,
                req.dock_takes_tabs,
            ))
        }
        "ids_ready" => {
            let req: HomeReq = ops::parse(request)?;
            ops::reply(&home_dock::ids_ready(req.workspace.as_ref()))
        }
        "placeholder_plan" => {
            let req: HomeReq = ops::parse(request)?;
            ops::reply(&home_dock::placeholder_plan(
                req.workspace.as_ref(),
                req.checked,
                req.checked_ever,
                &req.home,
            ))
        }
        "reveal_when_docked" => {
            let req: HomeReq = ops::parse(request)?;
            ops::reply(
                &req.workspace.as_ref().is_some_and(|home| {
                    home_dock::reveal_when_docked(home, req.classic, req.ready)
                }),
            )
        }
        "opens_link" => {
            let req: LinkReq = ops::parse(request)?;
            ops::reply(&home_dock::opens_link(req.scheme.as_deref()))
        }
        "chief_tab_open" => {
            let req: ChiefOpenReq = ops::parse(request)?;
            ops::reply(&chief_tab_key::is_open(&req.chief, &req.workspaces))
        }
        "chief_tab_key_step" => {
            let req: KeyStepReq = ops::parse(request)?;
            ops::reply(&chief_tab_key::step(req.state, req.event))
        }
        "chief_action_plan" => {
            let req: ActionPlanReq = ops::parse(request)?;
            Ok(json!({
                "stop": ops::reply(&action_plan::stop(&req.front, &req.chiefs))?,
                "settings": ops::reply(&action_plan::settings(&req.front, &req.chiefs))?,
            }))
        }
        "launch_cache_fingerprint" => {
            let req: ShapeReq = ops::parse(request)?;
            ops::reply(&launch_cache::fingerprint(&req.shape))
        }
        "launch_cache_path" => {
            let req: OwnerReq = ops::parse(request)?;
            ops::reply(&launch_cache::relative_path(&req.owner))
        }
        "launch_cache_inbox_key" => {
            let req: OwnersReq = ops::parse(request)?;
            ops::reply(&launch_cache::inbox_key(&req.owners))
        }
        "launch_cache_load_accepts" => {
            let req: LoadReq = ops::parse(request)?;
            ops::reply(&launch_cache::load_accepts(
                &req.schema,
                &req.file_schema,
                &req.account,
                &req.file_account,
            ))
        }
        "launch_cache_step" => {
            let req: SaveStepReq = ops::parse(request)?;
            ops::reply(&launch_cache::step(req.state, req.event))
        }
        "pin_migration_run" => {
            let req: MigrationRunReq = ops::parse(request)?;
            ops::reply(&pins::migration_run(
                req.cloud.as_deref(),
                &req.rows,
                &req.kept,
                &req.sending,
                &req.refused,
            ))
        }
        "pin_migration_adopted" => {
            let req: MigrationAdoptedReq = ops::parse(request)?;
            ops::reply(&pins::migration_adopted(
                &req.ids,
                &req.accepted,
                &req.sending,
                &req.refused,
            ))
        }
        "pin_drop" => {
            let req: PinDropReq = ops::parse(request)?;
            ops::reply(&pins::drop_pins(req.pins, &req.gone))
        }
        "sidebar_shows" => {
            let req: ShowsReq = ops::parse(request)?;
            let shown: Vec<&str> = req
                .rows
                .iter()
                .filter(|row| pins::shows(row, &req.hidden))
                .map(|row| row.id.as_str())
                .collect();
            ops::reply(&shown)
        }
        "sidebar_hide" => {
            let req: HideReq = ops::parse(request)?;
            ops::reply(&pins::hide(&req.id, &req.rows, req.hidden))
        }
        "sidebar_owner_of" => {
            let req: OwnerOfReq = ops::parse(request)?;
            ops::reply(&pins::owner_of(&req.id, &req.inboxes))
        }
        "sidebar_place" => {
            let req: PlaceReq = ops::parse(request)?;
            ops::reply(&pins::place(&req.pinned, &req.id, req.index, req.base, &req.inboxes))
        }
        "sidebar_mark_unread" => {
            let req: MarkReq = ops::parse(request)?;
            ops::reply(&pins::mark_unread(req.on, &req.id, &req.marks))
        }
        "move_targets" => {
            let req: TargetsReq = ops::parse(request)?;
            ops::reply(&chief_move::targets(&req.local_home, &req.hosts, &req.cloud))
        }
        "move_plan" => {
            let req: MovePlanReq = ops::parse(request)?;
            ops::reply(&chief_move::plan(
                &req.to,
                &req.kind,
                &req.source_home,
                &req.target_home,
                req.token_file.as_deref(),
            ))
        }
        "move_rollback" => {
            let req: RollbackReq = ops::parse(request)?;
            ops::reply(&chief_move::rollback(&req.source_home, req.token_file.as_deref()))
        }
        "move_target_home" => {
            let req: TargetHomeReq = ops::parse(request)?;
            ops::reply(&chief_move::target_home(&req.home, &req.user_home))
        }
        "chief_dm_key" => {
            let req: DmKeyReq = ops::parse(request)?;
            ops::reply(&direct_messages::key(&req.chief))
        }
        "chief_dm_request" => {
            let req: DmRequestReq = ops::parse(request)?;
            Ok(direct_messages::request(&req.me, &req.chief, &req.name))
        }
        "chief_dm_records" => {
            let req: DmRecordsReq = ops::parse(request)?;
            ops::reply(&direct_messages::records(&req.listed))
        }
        "chief_dm_missing" => {
            let req: DmMissingReq = ops::parse(request)?;
            ops::reply(&direct_messages::missing(&req.all, &req.listed))
        }
        _ => Err(OpError::Unknown),
    }
}
