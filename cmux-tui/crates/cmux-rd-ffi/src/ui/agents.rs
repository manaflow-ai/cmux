//! Agents sharing a Mac, and the person's signed yes (`CmuxRemoteAgentShare`,
//! `CmuxRemoteShareApproval`): what the app sends the daemon to redeem an
//! agent's ticket, how it reads the answer, and the approval's canonical
//! bytes and wire object (one source with the target's acpmux:
//! `cmux-share-approval`). The daemon decides; these only shape its in and out.

use cmux_share_approval::{ShareApproval, VERSION};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::{Answer, args};

pub(crate) fn handle(name: &str, a: &Value) -> Answer {
    Some(match name {
        "redeemParams" => args::<RedeemArgs>(a).map(|r| redeem_params(&r)),
        "redeemRefused" => {
            Ok(Value::Bool(redeem_refused(a.get("error").and_then(Value::as_str).unwrap_or(""))))
        }
        "redeemGrant" => Ok(redeem_grant(a.get("answer").unwrap_or(&Value::Null))),
        "notice" => Ok(notice(a.get("notice").unwrap_or(&Value::Null))),
        "approval" => args::<ApprovalArgs>(a).map(|r| approval(r)),
        _ => return None,
    })
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub(crate) struct DeviceRef {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct RedeemArgs {
    pub ticket: String,
    /// The hub's value of "My agents can turn screen sharing and control on my machines" now.
    pub allowed: bool,
    /// The signed-in account (hub user id), empty when unknown.
    pub account: String,
    pub this_device: DeviceRef,
    /// This Mac's sharing is already on (the person's own share).
    pub already_shared: bool,
    /// Another of this account's devices, when the change is for it.
    pub target: Option<DeviceRef>,
}

/// `agent.redeem`'s params. A share the person already has on stays theirs (no agent countdown),
/// so `already_shared` goes only with no target; a listed target is this account's.
fn redeem_params(r: &RedeemArgs) -> Value {
    let mut params = Map::new();
    params.insert("ticket".into(), json!(r.ticket));
    params.insert("allowed".into(), json!(r.allowed));
    params.insert("account".into(), json!(r.account));
    params
        .insert("this_device".into(), json!({"id": r.this_device.id, "name": r.this_device.name}));
    match &r.target {
        None if r.already_shared => {
            params.insert("already_shared".into(), json!(true));
        }
        None => {}
        Some(target) => {
            params.insert(
                "target".into(),
                json!({"id": target.id, "name": target.name, "account": r.account}),
            );
        }
    }
    Value::Object(params)
}

/// Whether `agent.redeem`'s failure refuses outright (another account's device); any other
/// failure (a daemon without agent tickets, no daemon) leaves the decision to the person.
fn redeem_refused(error: &str) -> bool {
    error.contains("agents.other_account") || error.contains("is not a device of this account")
}

/// The grant in `agent.redeem`'s answer, or null when the person decides (`dialog` is not false).
fn redeem_grant(answer: &Value) -> Value {
    if answer.get("dialog").and_then(Value::as_bool) != Some(false) {
        return Value::Null;
    }
    let text = |v: Option<&Value>| v.and_then(Value::as_str).unwrap_or("").to_owned();
    json!({
        "session": text(answer.get("agent").and_then(|a| a.get("session"))),
        "label": text(answer.get("agent_label")),
        "notice": answer.get("notice").cloned().unwrap_or(Value::Null),
        "action": text(answer.get("action")),
    })
}

/// The quiet notice for an agent's change: which line (`shared` or `unshared`), the device, and
/// whether it offers Turn Off (only when it turned sharing on and the daemon names a turn-off).
fn notice(notice: &Value) -> Value {
    let shared = notice.get("kind").and_then(Value::as_str) == Some("shared");
    json!({
        "kind": if shared { "shared" } else { "unshared" },
        "device": notice.get("device_name").and_then(Value::as_str).unwrap_or(""),
        "offersTurnOff": shared && notice.get("turn_off").and_then(Value::as_str).is_some(),
    })
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ApprovalArgs {
    target: String,
    target_name: String,
    asker: String,
    asker_name: String,
    confirmed_by: String,
    confirmed_at: u64,
    nonce: String,
    signature: String,
}

/// The approval's signed bytes and its wire object (`remote.confirm`'s `approval`).
fn approval(a: ApprovalArgs) -> Value {
    let approval = ShareApproval {
        v: VERSION.to_owned(),
        target: a.target,
        target_name: a.target_name,
        asker: a.asker,
        asker_name: a.asker_name,
        confirmed_by: a.confirmed_by,
        confirmed_at: a.confirmed_at,
        nonce: a.nonce,
        signature: a.signature,
    };
    json!({"canonical": approval.canonical(), "wire": approval.wire()})
}

#[cfg(test)]
#[path = "agents_tests.rs"]
mod tests;
