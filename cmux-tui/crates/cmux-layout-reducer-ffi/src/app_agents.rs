//! `cmux-app-agents` over the JSON channel (ops `app_agents_*`): the app's
//! agent-recents, new-tab, control-session and apps rules. The app reads its
//! models and the daemon's answers, sends the facts and acts on the answer.

use cmux_app_agents::{apps, chat_key, closed, control, new_tab, subagent_limit};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"app_agents_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SubagentParams {
    session_id: String,
    #[serde(default)]
    change: Option<subagent_limit::Change>,
}

#[derive(Deserialize)]
struct SubagentCurrent {
    #[serde(default)]
    reply: Value,
    setting: i64,
}

#[derive(Deserialize)]
struct SubagentDecide {
    answer: subagent_limit::Answer,
    #[serde(default)]
    min: Option<i64>,
    #[serde(default)]
    max: Option<i64>,
}

#[derive(Deserialize)]
struct ClosedRows {
    #[serde(default)]
    entries: Vec<closed::Entry>,
    #[serde(default)]
    home: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Deserialize)]
struct ClosedTitle {
    title: String,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClosedKind {
    kind: closed::ItemKind,
    #[serde(default)]
    agent_session: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeRequest {
    kind: new_tab::TabKind,
    #[serde(default)]
    text: String,
    #[serde(default)]
    search: bool,
    #[serde(default)]
    plan: Option<new_tab::Plan>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Beside {
    plan: new_tab::Plan,
    #[serde(default)]
    by_person: bool,
}

#[derive(Deserialize)]
struct ControlNames {
    #[serde(default)]
    candidates: Vec<control::Candidate>,
    #[serde(default)]
    defaults: Vec<String>,
}

#[derive(Deserialize)]
struct AppsReach {
    origin: apps::Origin,
    #[serde(default)]
    apps: Vec<apps::Reach>,
}

#[derive(Deserialize)]
struct AppsRefusal {
    refused: String,
    #[serde(default)]
    families: Vec<String>,
}

#[derive(Deserialize)]
struct ChatKey {
    key: String,
}

fn decision(decision: subagent_limit::Decision) -> Value {
    use subagent_limit::{Change, Decision};
    match decision {
        Decision::Cancelled => json!({"decision": "cancelled"}),
        Decision::Invalid => json!({"decision": "invalid"}),
        Decision::Change(Change::UseDefault) => json!({"decision": "useDefault"}),
        Decision::Change(Change::Set(value)) => json!({"decision": "set", "value": value}),
    }
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // `{sessionId, change?}`: the `_acpmux/subsession/limits` params (no change reads).
        b"app_agents_subagent_params" => {
            let request: SubagentParams = read(request)?;
            subagent_limit::params(&request.session_id, request.change)
        }
        // `{reply, setting}`: the limit acpmux reported (`current`, null without a run
        // limit) and what the dialog shows for it.
        b"app_agents_subagent_current" => {
            let request: SubagentCurrent = read(request)?;
            let current = subagent_limit::Current::from_reply(&request.reply);
            let dialog = subagent_limit::dialog(&current.unwrap_or_default(), request.setting);
            json!({
                "current": current,
                "placeholder": dialog.placeholder,
                "initial": dialog.initial,
                "status": dialog.status.map(|(running, queued)| json!({"running": running, "queued": queued})),
            })
        }
        // `{answer: {button, text, dismissal, cancel}, min?, max?}`: what the dialog's answer sends.
        b"app_agents_subagent_decide" => {
            let request: SubagentDecide = read(request)?;
            let (low, high) = subagent_limit::RANGE;
            let range = (request.min.unwrap_or(low), request.max.unwrap_or(high));
            decision(subagent_limit::decide(&request.answer, range))
        }
        // `{entries, home?, limit?}`: Recently Closed's rows, newest first.
        b"app_agents_closed_rows" => {
            let request: ClosedRows = read(request)?;
            let limit = request.limit.unwrap_or(closed::MAXIMUM_PUSHED);
            json!(closed::rows(&request.entries, request.home.as_deref(), limit))
        }
        b"app_agents_closed_title" => {
            let request: ClosedTitle = read(request)?;
            json!(closed::title(&request.title, request.url.as_deref(), request.cwd.as_deref()))
        }
        b"app_agents_closed_kind" => {
            let request: ClosedKind = read(request)?;
            json!(closed::kind(request.kind, request.agent_session))
        }
        // `Submission`: what `newTab.submit` opens.
        b"app_agents_new_tab_plan" => {
            let request: new_tab::Submission = read(request)?;
            json!(new_tab::plan(&request))
        }
        // `{kind, text, search, plan?}`: the tab a native pick opens (null: refused) and
        // whether it plans first (`plans`, asked before the plan is made).
        b"app_agents_new_tab_native" => {
            let request: NativeRequest = read(request)?;
            json!({
                "plans": new_tab::native_plans(request.kind, &request.text),
                "open": new_tab::native_request(request.kind, &request.text, request.search, request.plan.as_ref()),
            })
        }
        b"app_agents_new_tab_beside" => {
            let request: Beside = read(request)?;
            json!(new_tab::opens_beside_chat(&request.plan, request.by_person))
        }
        // `{candidates, defaults}`: every daemon's qualifier name and transport, in order.
        b"app_agents_control_names" => {
            let request: ControlNames = read(request)?;
            json!(control::name_all(&request.candidates, &request.defaults))
        }
        // `{origin, apps}`: whether a run from `origin` reaches each app.
        b"app_agents_apps_reaches" => {
            let request: AppsReach = read(request)?;
            json!(
                request
                    .apps
                    .iter()
                    .map(|app| apps::reaches(app, request.origin))
                    .collect::<Vec<_>>()
            )
        }
        // `{refused, families}`: the provider channel's next step.
        b"app_agents_apps_after_refusal" => {
            let request: AppsRefusal = read(request)?;
            json!(apps::after_refusal(&request.refused, &request.families))
        }
        b"app_agents_chat_key" => {
            let request: ChatKey = read(request)?;
            json!(chat_key::parse(&request.key))
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
