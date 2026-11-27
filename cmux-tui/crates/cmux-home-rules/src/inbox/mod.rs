//! The `inbox` area's ops: the Mac Home's conversation list rules (pins, sections, search, row
//! text, contacts and roster order, the list width, the group sheet and the source router), so
//! every platform's Home orders and names its chats alike. Each op reads a JSON request in the
//! Swift types' own Codable shapes and answers JSON; words stay Swift's (an answer names a kind).

pub mod group;
pub mod layout;
pub mod list;
pub mod model;
pub mod people;
pub mod pins;
pub mod router;
pub mod sidebar;
pub mod text;

use crate::ops::{OpError, parse, reply};
use model::{ChiefPlace, Contact, Participant, Row};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;

/// This area's op names (without the `inbox.` prefix).
pub const OPS: &[&str] = &[
    "agent_indicator",
    "agent_shortlist",
    "chief_default",
    "chief_place",
    "contacts_agents",
    "contacts_connections",
    "contacts_merged",
    "contacts_without_dm",
    "group_info",
    "group_member",
    "group_sheet_new",
    "group_sheet_step",
    "group_sheet_view",
    "invite_waiting",
    "lines",
    "list_time",
    "name_key",
    "needs_first_workspace",
    "participant_names",
    "pending_invites",
    "pins_arrange",
    "pins_is_pinned",
    "pins_leading",
    "pins_place",
    "pins_set_pinned",
    "pins_split",
    "roster_group_members",
    "roster_main_first",
    "router_merged_connection",
    "router_route",
    "router_step",
    "router_upload_rejection",
    "row_matches",
    "row_preview",
    "sections",
    "sidebar",
    "sidebar_neighbor",
    "sidebar_number",
    "sidebar_unread",
    "width_clamp",
    "width_column_minimum",
    "width_constants",
    "width_drag",
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowsReq {
    rows: Vec<Row>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PinsRowReq {
    pins: pins::Pins,
    row: Row,
    #[serde(default)]
    on: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PinsRowsReq {
    pins: pins::Pins,
    rows: Vec<Row>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PinsPlaceReq {
    pins: pins::Pins,
    id: String,
    index: i64,
    shown: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PinsArrangeReq {
    pins: pins::Pins,
    order: Vec<String>,
    #[serde(default)]
    positions: Vec<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PinsLeadingReq {
    pins: pins::Pins,
    #[serde(default)]
    main: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowsMeReq {
    rows: Vec<Row>,
    me: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WithoutDmReq {
    contacts: Vec<Contact>,
    rows: Vec<Row>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MergedReq {
    #[serde(default)]
    team: Vec<Contact>,
    #[serde(default)]
    connections: Vec<Contact>,
    #[serde(default)]
    agents: Vec<Contact>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RosterReq {
    contacts: Vec<Contact>,
    rows: Vec<Row>,
    #[serde(default)]
    main: Option<String>,
    #[serde(default)]
    me: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChiefDefaultReq {
    #[serde(default)]
    setting: Option<String>,
    #[serde(default)]
    local_running: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChiefPlaceReq {
    /// ChiefList's place: `thisMac`, `cloud` or `server` with a name.
    place: ChiefPlace,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShortlistReq {
    statuses: Vec<text::GlanceStatus>,
    #[serde(default = "five")]
    limit: usize,
}

fn five() -> usize {
    5
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndicatorReq {
    status: text::GlanceStatus,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParticipantsMeReq {
    participants: Vec<Participant>,
    #[serde(default)]
    me: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreviewReq {
    preview: String,
    #[serde(default)]
    last: Option<text::LastMessage>,
    #[serde(default)]
    participants: Vec<Participant>,
    #[serde(default)]
    me: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListTimeReq {
    time: f64,
    now: f64,
    #[serde(default)]
    utc_offset: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NameReq {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MatchReq {
    row: Row,
    needle: String,
    #[serde(default)]
    me: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnreadReq {
    pinned: Vec<Row>,
    rest: Vec<Row>,
    #[serde(default)]
    unread_marks: BTreeSet<String>,
    #[serde(default)]
    main_chief: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NeighborReq {
    order: Vec<String>,
    #[serde(default)]
    current: Option<String>,
    offset: i64,
    #[serde(default)]
    wrapping: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NumberReq {
    order: Vec<String>,
    number: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClampReq {
    width: f64,
    window: f64,
    #[serde(default)]
    minimum: Option<f64>,
    #[serde(default)]
    full_minimum: Option<f64>,
    #[serde(default)]
    transcript_minimum: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DragReq {
    proposed: f64,
    widest: f64,
    #[serde(default)]
    minimum: Option<f64>,
    #[serde(default)]
    full_minimum: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColumnReq {
    #[serde(default)]
    list_minimum: Option<f64>,
    #[serde(default)]
    divider: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceReq {
    workspaces: Vec<layout::Workspace>,
    #[serde(default)]
    leftover: Vec<String>,
    #[serde(default)]
    home: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroupInfoReq {
    is_group: bool,
    #[serde(default)]
    can_add_people: Option<bool>,
    #[serde(default)]
    can_rename: Option<bool>,
    #[serde(default)]
    member_count: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroupMemberReq {
    participant: Participant,
    #[serde(default)]
    me: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SheetNewReq {
    title: String,
    #[serde(default)]
    chief_replies: Option<String>,
    #[serde(default)]
    addable: Vec<Contact>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SheetStepReq {
    sheet: group::Sheet,
    event: group::Event,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SheetViewReq {
    sheet: group::Sheet,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouterStepReq {
    #[serde(default)]
    state: router::State,
    event: router::Event,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouterRouteReq {
    #[serde(default)]
    state: router::State,
    intent: router::Intent,
    #[serde(default)]
    chief: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConnectionReq {
    local: String,
    #[serde(default)]
    cloud: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadReq {
    owner: router::Owner,
    reason: String,
}

fn ids(rows: &[&Row]) -> Vec<String> {
    rows.iter().map(|row| row.id.clone()).collect()
}

/// Runs `inbox.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "pins_is_pinned" => {
            let r: PinsRowReq = parse(request)?;
            reply(&r.pins.is_pinned(&r.row))
        }
        "pins_split" => {
            let r: PinsRowsReq = parse(request)?;
            let (pinned, rest) = r.pins.split(&r.rows);
            Ok(json!({ "pinned": ids(&pinned), "rest": ids(&rest) }))
        }
        "pins_set_pinned" => {
            let mut r: PinsRowReq = parse(request)?;
            r.pins.set_pinned(r.on, &r.row);
            reply(&r.pins)
        }
        "pins_place" => {
            let mut r: PinsPlaceReq = parse(request)?;
            r.pins.place(&r.id, r.index, &r.shown);
            reply(&r.pins)
        }
        "pins_arrange" => {
            let mut r: PinsArrangeReq = parse(request)?;
            r.pins.arrange(&r.order, &r.positions);
            reply(&r.pins)
        }
        "pins_leading" => {
            let r: PinsLeadingReq = parse(request)?;
            reply(&r.pins.leading(r.main.as_deref()))
        }
        "sections" => reply(&list::sections(&parse::<RowsReq>(request)?.rows)),
        "lines" => reply(&list::lines(&parse::<RowsReq>(request)?.rows)),
        "pending_invites" => reply(&list::pending_invites(&parse::<RowsReq>(request)?.rows)),
        "contacts_connections" => {
            let r: RowsMeReq = parse(request)?;
            reply(&people::connections(&r.rows, &r.me))
        }
        "contacts_agents" => {
            let r: RowsMeReq = parse(request)?;
            reply(&people::agents(&r.rows, &r.me))
        }
        "contacts_without_dm" => {
            let r: WithoutDmReq = parse(request)?;
            reply(&people::without_dm(&r.contacts, &r.rows))
        }
        "contacts_merged" => {
            let r: MergedReq = parse(request)?;
            reply(&people::merged(&r.team, &r.connections, &r.agents))
        }
        "roster_main_first" => {
            let r: RosterReq = parse(request)?;
            reply(&people::main_first(&r.contacts, &r.rows, r.main.as_deref()))
        }
        "roster_group_members" => {
            let r: RosterReq = parse(request)?;
            reply(&people::group_members(&r.contacts, &r.rows, r.main.as_deref(), r.me.as_deref()))
        }
        "chief_default" => {
            let r: ChiefDefaultReq = parse(request)?;
            let default = people::ChiefDefault::from_setting(r.setting.as_deref());
            Ok(
                json!({ "default": default, "prefersLocal": default.prefers_local(r.local_running) }),
            )
        }
        "chief_place" => {
            // `HomeChiefPlace(_:unnamedServer:)`: an unnamed server keeps Swift's word for it.
            let r: ChiefPlaceReq = parse(request)?;
            match r.place {
                ChiefPlace::Server { name } if name.is_empty() => {
                    Ok(json!({ "kind": "unnamedServer" }))
                }
                place => reply(&place),
            }
        }
        "agent_shortlist" => {
            let r: ShortlistReq = parse(request)?;
            reply(&text::shortlist(&r.statuses, r.limit))
        }
        "agent_indicator" => reply(&text::indicator(parse::<IndicatorReq>(request)?.status)),
        "invite_waiting" => {
            let r: ParticipantsMeReq = parse(request)?;
            reply(&text::invite_waiting(&r.participants, r.me.as_deref()))
        }
        "participant_names" => {
            // `visibleName`, `initials` and `isChief` of each participant, for the views that draw one.
            let r: ParticipantsMeReq = parse(request)?;
            let names: Vec<Value> = r
                .participants
                .iter()
                .map(|p| {
                    json!({
                        "id": p.id,
                        "visibleName": p.visible_name(),
                        "initials": p.initials(),
                        "isChief": p.is_chief(),
                    })
                })
                .collect();
            Ok(Value::Array(names))
        }
        "row_preview" => {
            let r: PreviewReq = parse(request)?;
            reply(&text::preview(&r.preview, r.last.as_ref(), &r.participants, r.me.as_deref()))
        }
        "list_time" => {
            let r: ListTimeReq = parse(request)?;
            reply(&text::list_time(r.time, r.now, r.utc_offset))
        }
        "name_key" => reply(&sidebar::name_key(&parse::<NameReq>(request)?.name)),
        "row_matches" => {
            let r: MatchReq = parse(request)?;
            reply(&r.row.matches(&r.needle, r.me.as_deref()))
        }
        "sidebar" => reply(&sidebar::model(&parse::<sidebar::Request>(request)?)),
        "sidebar_unread" => {
            let r: UnreadReq = parse(request)?;
            reply(&sidebar::unread_conversations(
                &r.pinned,
                &r.rest,
                &r.unread_marks,
                r.main_chief.as_deref(),
            ))
        }
        "sidebar_neighbor" => {
            let r: NeighborReq = parse(request)?;
            reply(&sidebar::neighbor(&r.order, r.current.as_deref(), r.offset, r.wrapping))
        }
        "sidebar_number" => {
            let r: NumberReq = parse(request)?;
            reply(&sidebar::conversation_number(&r.order, r.number))
        }
        "width_constants" => Ok(json!({
            "minimum": layout::MINIMUM,
            "standard": layout::STANDARD,
            "fullMinimum": layout::FULL_MINIMUM,
            "transcriptMinimum": layout::TRANSCRIPT_MINIMUM,
        })),
        "width_clamp" => {
            let r: ClampReq = parse(request)?;
            reply(&layout::clamp(
                r.width,
                r.window,
                r.minimum.unwrap_or(layout::MINIMUM),
                r.full_minimum.unwrap_or(layout::FULL_MINIMUM),
                r.transcript_minimum.unwrap_or(layout::TRANSCRIPT_MINIMUM),
            ))
        }
        "width_drag" => {
            let r: DragReq = parse(request)?;
            reply(&layout::drag(
                r.proposed,
                r.minimum.unwrap_or(layout::MINIMUM),
                r.full_minimum.unwrap_or(layout::FULL_MINIMUM),
                r.widest,
            ))
        }
        "width_column_minimum" => {
            let r: ColumnReq = parse(request)?;
            reply(&layout::column_minimum(
                r.list_minimum.unwrap_or(layout::MINIMUM),
                r.divider.unwrap_or(1.0),
            ))
        }
        "needs_first_workspace" => {
            let r: WorkspaceReq = parse(request)?;
            reply(&layout::needs_first_workspace(&r.workspaces, &r.leftover, r.home.as_deref()))
        }
        "group_info" => {
            let r: GroupInfoReq = parse(request)?;
            reply(&group::info_flags(r.is_group, r.can_add_people, r.can_rename, r.member_count))
        }
        "group_member" => {
            let r: GroupMemberReq = parse(request)?;
            reply(&people::group_member(&r.participant, r.me.as_deref()))
        }
        "group_sheet_new" => {
            let r: SheetNewReq = parse(request)?;
            reply(&group::Sheet::new(&r.title, r.chief_replies, r.addable))
        }
        "group_sheet_step" => {
            let mut r: SheetStepReq = parse(request)?;
            let effects = group::step(&mut r.sheet, &r.event);
            Ok(json!({ "sheet": reply(&r.sheet)?, "effects": reply(&effects)? }))
        }
        "group_sheet_view" => {
            let r: SheetViewReq = parse(request)?;
            Ok(json!({
                "shownAddable": reply(&r.sheet.shown_addable())?,
                "canRename": r.sheet.can_rename(),
                "isRunning": r.sheet.is_running(),
            }))
        }
        "router_step" => {
            let mut r: RouterStepReq = parse(request)?;
            let effects = router::step(&mut r.state, &r.event);
            Ok(json!({ "state": reply(&r.state)?, "effects": reply(&effects)? }))
        }
        "router_route" => {
            let r: RouterRouteReq = parse(request)?;
            reply(&router::route(&r.state, &r.intent, &r.chief))
        }
        "router_merged_connection" => {
            let r: ConnectionReq = parse(request)?;
            reply(&router::merged_connection(&r.local, r.cloud.as_deref()))
        }
        "router_upload_rejection" => {
            let r: UploadReq = parse(request)?;
            reply(&router::upload_rejection(r.owner, &r.reason))
        }
        _ => Err(OpError::Unknown),
    }
}
