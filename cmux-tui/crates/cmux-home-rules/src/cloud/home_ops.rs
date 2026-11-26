//! The Home ops of the cloud area (part 2): reach plan, Chiefs, archive,
//! message requests, subscriptions and edit-echo holds.

use super::{archive, chiefs, edit_echo, reach, requests, server, subscriptions};
use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, HashMap};

fn invalid(what: &str) -> OpError {
    OpError::Invalid(format!("not a {what} reply"))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanRequest {
    #[serde(default)]
    chiefs: Vec<reach::CloudChief>,
    #[serde(default)]
    hosts: Vec<reach::PairedServer>,
    #[serde(default)]
    local: Option<reach::LocalServer>,
    #[serde(default)]
    link: Option<reach::LinkPeers>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouteRequest {
    host: reach::PairedServer,
    #[serde(default)]
    install: Option<String>,
    #[serde(default)]
    local: Option<reach::LocalServer>,
    #[serde(default)]
    link: Option<reach::LinkPeers>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThisMacRequest {
    host: reach::PairedServer,
    #[serde(default)]
    install: Option<String>,
    local: reach::LocalServer,
    #[serde(default)]
    link: Option<reach::LinkPeers>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DiffRequest {
    #[serde(default)]
    shown: Vec<reach::Reach>,
    #[serde(default)]
    desired: Vec<reach::Reach>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NameRequest {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NewReachRequest {
    #[serde(rename = "hostID")]
    host_id: String,
    #[serde(rename = "installID")]
    install_id: String,
    name: String,
    route: reach::Route,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LinkRequest {
    show: Value,
    #[serde(default)]
    peers: Option<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetupFileRequest {
    #[serde(default)]
    environment: HashMap<String, String>,
    home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValueRequest {
    value: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChiefListRequest {
    #[serde(default)]
    chiefs: Vec<reach::CloudChief>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShownRequest {
    #[serde(default)]
    chiefs: chiefs::Chiefs,
    #[serde(default)]
    choice: chiefs::Choice,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OtherHostRequest {
    #[serde(default)]
    chiefs: chiefs::Chiefs,
    conversation: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabRequest {
    #[serde(default)]
    chiefs: chiefs::Chiefs,
    #[serde(default)]
    local: Option<String>,
    #[serde(default)]
    local_has_history: bool,
    #[serde(default)]
    choice: chiefs::Choice,
    #[serde(default)]
    prefers_local: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlacementRequest {
    #[serde(default)]
    chiefs: chiefs::Chiefs,
    conversation: String,
    #[serde(default)]
    records: Vec<chiefs::Record>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenRequest {
    chief: String,
    #[serde(default)]
    panes: Vec<chiefs::Pane>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MoveRequest {
    #[serde(default)]
    from: Vec<String>,
    chief: String,
    #[serde(default)]
    panes: Vec<chiefs::Pane>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StaleRequest {
    #[serde(default)]
    stale: Vec<String>,
    chief: String,
    #[serde(default)]
    panes: Vec<chiefs::Pane>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OkValueRequest {
    reply: Map<String, Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnsureRequest {
    #[serde(default)]
    chiefs: Vec<reach::CloudChief>,
    chief_name: String,
    placed_name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreatedRequest {
    #[serde(default)]
    replayed: bool,
    #[serde(default)]
    sent_before: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArchivePlanRequest {
    id: String,
    #[serde(default)]
    account: archive::Account,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArchiveAfterRequest {
    reply: archive::Reply,
    #[serde(default)]
    attempt: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArchiveOutcomeRequest {
    step: archive::Step,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArchiveSyncRequest {
    #[serde(default)]
    hidden: BTreeSet<String>,
    #[serde(default)]
    account: archive::Account,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadStepRequest {
    #[serde(default)]
    state: requests::Reads,
    event: requests::ReadEvent,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListedRequest {
    #[serde(default)]
    listed: Vec<requests::Request>,
    #[serde(default)]
    answering: BTreeSet<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TakeRequest {
    #[serde(default)]
    items: Vec<requests::Request>,
    conversation: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RestoreRequest {
    #[serde(default)]
    items: Vec<requests::Request>,
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    request: Option<requests::Request>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerRequest {
    server: server::Server,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SubscribeRequest {
    #[serde(default)]
    state: subscriptions::Subs,
    conversation: String,
    generation: u64,
    #[serde(default)]
    max: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RepliedRequest {
    #[serde(default)]
    state: subscriptions::Subs,
    conversation: String,
    generation: u64,
    reply_state: String,
    #[serde(default)]
    account: Option<String>,
    #[serde(default)]
    identity_cloud_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FailedRequest {
    #[serde(default)]
    state: subscriptions::Subs,
    conversation: String,
    generation: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EditableRequest {
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    closed: bool,
}

/// Runs one of this module's ops; `None` for a name this module does not route.
pub fn call(name: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match name {
        "reach_plan" => parse::<PlanRequest>(request).and_then(|r| {
            reply(&reach::make(&r.chiefs, &r.hosts, r.local.as_ref(), r.link.as_ref()))
        }),
        "reach_route" => parse::<RouteRequest>(request).map(|r| {
            let route =
                reach::route(&r.host, r.install.as_deref(), r.local.as_ref(), r.link.as_ref());
            json!({ "route": route })
        }),
        "reach_is_this_mac" => parse::<ThisMacRequest>(request).map(|r| {
            let mine = reach::is_this_mac(&r.host, r.install.as_deref(), &r.local, r.link.as_ref());
            json!({ "thisMac": mine })
        }),
        "reach_diff" => {
            parse::<DiffRequest>(request).and_then(|r| reply(&reach::diff(&r.shown, &r.desired)))
        }
        "reach_dns_label" => parse::<NameRequest>(request).map(
            |r| json!({ "label": reach::dns_label(&r.name), "route": reach::brain_route(&r.name) }),
        ),
        "reach_new" => parse::<NewReachRequest>(request).map(|r| {
            match reach::Reach::new(&r.host_id, &r.install_id, &r.name, r.route) {
                Ok(reach) => json!({ "reach": reach, "machineID": reach.machine_id() }),
                Err(field) => json!({ "invalid": field }),
            }
        }),
        "reach_link_peers" => parse::<LinkRequest>(request).map(|r| {
            let link = reach::link_peers(&r.show, r.peers.as_ref());
            let files = link.as_ref().map(reach::LinkPeers::watched_files).unwrap_or_default();
            let registration = link.as_ref().and_then(reach::LinkPeers::registration_file);
            json!({ "link": link, "watchedFiles": files, "registrationFile": registration })
        }),
        "reach_default_link_setup_file" => parse::<SetupFileRequest>(request)
            .map(|r| json!({ "file": reach::default_link_setup_file(&r.environment, &r.home) })),
        "reach_parse_chiefs" => parse::<ValueRequest>(request).and_then(|r| {
            reach::parse_chiefs(&r.value).map_err(invalid).map(|chiefs| json!({ "chiefs": chiefs }))
        }),
        "reach_parse_hosts" => parse::<ValueRequest>(request)
            .and_then(|r| reach::parse_hosts(&r.value).map_err(invalid))
            .and_then(|page| reply(&page)),
        "chiefs_list" => parse::<ChiefListRequest>(request).and_then(|r| {
            reply(&chiefs::Chiefs {
                hosted: chiefs::hosted_in(&r.chiefs).cloned(),
                placed: chiefs::placed_in(&r.chiefs).cloned(),
            })
        }),
        "chiefs_placed_only" => {
            parse::<ChiefListRequest>(request).and_then(|r| reply(&chiefs::placed_only(&r.chiefs)))
        }
        "chiefs_shown" => parse::<ShownRequest>(request).map(|r| {
            json!({
                "chief": r.chiefs.shown(r.choice),
                "canSwitch": r.chiefs.can_switch(),
            })
        }),
        "chiefs_other_host" => parse::<OtherHostRequest>(request).map(|r| {
            json!({
                "other": r.chiefs.other_host(&r.conversation),
                "chief": r.chiefs.chief_for(&r.conversation),
            })
        }),
        "chiefs_tab" => parse::<TabRequest>(request).map(|r| {
            let tab = r.chiefs.chief_tab(
                r.local.as_deref(),
                r.local_has_history,
                r.choice,
                r.prefers_local,
            );
            json!({ "conversation": tab })
        }),
        "chiefs_placement" => parse::<PlacementRequest>(request)
            .map(|r| json!({ "placement": r.chiefs.placement(&r.conversation, &r.records) })),
        "chiefs_is_open" => parse::<OpenRequest>(request)
            .map(|r| json!({ "open": chiefs::is_open(&r.chief, &r.panes) })),
        "chiefs_move" => parse::<MoveRequest>(request)
            .and_then(|r| reply(&chiefs::move_tab(&r.from, &r.chief, &r.panes))),
        "chiefs_stale_tabs" => parse::<StaleRequest>(request)
            .map(|r| json!({ "close": chiefs::stale_tabs(&r.stale, &r.chief, &r.panes) })),
        "chiefs_ok_value" => {
            parse::<OkValueRequest>(request).and_then(|r| reply(&chiefs::ok_value(&r.reply)))
        }
        "chiefs_ensure" => parse::<EnsureRequest>(request)
            .and_then(|r| reply(&chiefs::ensure(&r.chiefs, &r.chief_name, &r.placed_name))),
        "chiefs_created_here" => parse::<CreatedRequest>(request)
            .map(|r| json!({ "createdHere": chiefs::created_here(r.replayed, r.sent_before) })),
        "archive_plan" => parse::<ArchivePlanRequest>(request)
            .and_then(|r| reply(&archive::plan(&r.id, &r.account))),
        "archive_after" => parse::<ArchiveAfterRequest>(request)
            .and_then(|r| reply(&archive::after(&r.reply, r.attempt))),
        "archive_outcome" => parse::<ArchiveOutcomeRequest>(request)
            .map(|r| json!({ "outcome": archive::outcome(&r.step) })),
        "archive_sync" => parse::<ArchiveSyncRequest>(request).map(|r| {
            let actions: Map<String, Value> = r
                .hidden
                .iter()
                .map(|id| {
                    let sync = archive::sync_one(id, &r.hidden, &r.account);
                    (id.clone(), json!(sync))
                })
                .collect();
            json!({ "sync": actions })
        }),
        "requests_read_step" => parse::<ReadStepRequest>(request)
            .and_then(|r| reply(&requests::read_step(r.state, r.event))),
        "requests_listed" => parse::<ListedRequest>(request)
            .map(|r| json!({ "items": requests::listed(r.listed, &r.answering) })),
        "requests_take" => parse::<TakeRequest>(request)
            .and_then(|r| reply(&requests::take(r.items, &r.conversation))),
        "requests_restore" => parse::<RestoreRequest>(request)
            .map(|r| json!({ "items": requests::restore(r.items, r.index, r.request) })),
        "server_rules" => parse::<ServerRequest>(request).map(|r| {
            json!({
                "sendsToken": server::sends_token(&r.server),
                "url": server::self_hosted_url(&r.server),
            })
        }),
        "subs_subscribe" => parse::<SubscribeRequest>(request).and_then(|r| {
            let max = r.max.unwrap_or(subscriptions::MAX_SUBSCRIPTIONS);
            reply(&subscriptions::subscribe(r.state, &r.conversation, r.generation, max))
        }),
        "subs_replied" => parse::<RepliedRequest>(request).and_then(|r| {
            reply(&subscriptions::replied(
                r.state,
                &r.conversation,
                r.generation,
                &r.reply_state,
                r.account.as_deref(),
                r.identity_cloud_id.as_deref(),
            ))
        }),
        "subs_failed" => parse::<FailedRequest>(request)
            .and_then(|r| reply(&subscriptions::failed(r.state, &r.conversation, r.generation))),
        "subs_editable" => parse::<EditableRequest>(request)
            .and_then(|r| reply(&subscriptions::editable(r.target.as_deref(), r.closed))),
        "echo_step" => parse::<edit_echo::StepRequest>(request).and_then(|r| {
            let (state, effects) = edit_echo::step(r.state, r.event);
            reply(&edit_echo::StepReply { state, effects })
        }),
        _ => return None,
    })
}
