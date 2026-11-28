//! The device hub rules over one JSON channel (ops `rd_hub_*`), the shape the app's C ABI
//! (`cmux_layout_reducer_json`) carries: each viewer tab's reducer by id, this Mac's host
//! reducer, and the stateless rules (end reasons, refusals, approval buttons, access levels,
//! default sharing).

use super::access::{Access, ApprovalChoice, Scope, hub_startup_message, scope_to_request};
use super::host::{Host, HostEvent};
use super::reason::{EndReason, HubError, HubReason, Refusal};
use super::sharing::{default_sharing_step, sharing_state};
use super::viewer::{Phase, Ticket, Viewer, ViewerEvent};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashMap;

/// The host reducers (one per app host, by its id; `""` when the request names none) and every
/// viewer tab's, by the app's tab id.
#[derive(Default)]
pub struct RdHub {
    hosts: HashMap<String, Host>,
    viewers: HashMap<String, Viewer>,
}

/// The host a request names (`host`, taken out of the request), else `""`.
fn host_id(request: &mut Value) -> String {
    match request.as_object_mut().and_then(|o| o.remove("host")) {
        Some(Value::String(id)) => id,
        _ => String::new(),
    }
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, String> {
    serde_json::from_value(request).map_err(|e| e.to_string())
}

fn encode(value: impl serde::Serialize) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct Id {
    id: String,
}

#[derive(Deserialize)]
struct Open {
    id: String,
    device_id: String,
}

#[derive(Deserialize)]
struct TabPhase {
    id: String,
    phase: Phase,
}

#[derive(Deserialize)]
struct TabEvent {
    id: String,
    event: ViewerEvent,
}

#[derive(Deserialize)]
struct TabTicket {
    id: String,
    ticket: Ticket,
}

#[derive(Deserialize)]
struct ReasonRequest {
    reason: Option<String>,
}

#[derive(Deserialize)]
struct Why {
    why: String,
}

#[derive(Deserialize)]
struct ErrorRequest {
    error: HubError,
}

#[derive(Deserialize)]
struct ApprovalRequest {
    choice: ApprovalChoice,
    requested: Scope,
}

#[derive(Deserialize)]
struct ScopeRequest {
    #[serde(default)]
    last: Scope,
    access: Option<Access>,
}

#[derive(Deserialize)]
struct SharingRequest {
    shared: Option<bool>,
    #[serde(default)]
    grant_known: bool,
    #[serde(default)]
    screen_recording: bool,
    turned_off: Option<bool>,
}

#[derive(Deserialize)]
struct StartupRequest {
    #[serde(default)]
    startup_failed: bool,
}

impl RdHub {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn serves(op: &str) -> bool {
        op.starts_with("rd_hub_")
    }

    fn host_reply(host: &Host) -> Result<Value, String> {
        Ok(json!({
            "state": encode(host)?,
            "indicator": encode(host.indicator())?,
            "no_session_reason": encode(host.no_session_reason())?,
        }))
    }

    fn viewer(&self, id: &str) -> Result<&Viewer, String> {
        self.viewers.get(id).ok_or_else(|| format!("no viewer {id}"))
    }

    pub fn call(&mut self, op: &str, request: Value) -> Result<Value, String> {
        match op {
            "rd_hub_viewer_open" => {
                let Open { id, device_id } = parse(request)?;
                let viewer = self.viewers.entry(id).or_insert_with(|| Viewer::new(device_id));
                encode(&*viewer)
            }
            "rd_hub_viewer_event" => {
                let TabEvent { id, event } = parse(request)?;
                let viewer = self.viewers.get_mut(&id).ok_or_else(|| format!("no viewer {id}"))?;
                let effects = viewer.apply(event);
                Ok(json!({ "state": encode(&*viewer)?, "effects": encode(effects)? }))
            }
            "rd_hub_viewer_state" => {
                let Id { id } = parse(request)?;
                encode(self.viewer(&id)?)
            }
            "rd_hub_viewer_accepts" => {
                let TabTicket { id, ticket } = parse(request)?;
                Ok(json!({ "accepts": self.viewer(&id)?.accepts(&ticket) }))
            }
            "rd_hub_viewer_set_phase" => {
                let TabPhase { id, phase } = parse(request)?;
                let viewer = self.viewers.get_mut(&id).ok_or_else(|| format!("no viewer {id}"))?;
                viewer.phase = phase;
                encode(&*viewer)
            }
            "rd_hub_viewer_close" => {
                let Id { id } = parse(request)?;
                Ok(json!({ "closed": self.viewers.remove(&id).is_some() }))
            }
            "rd_hub_host_event" => {
                let mut request = request;
                let host = self.hosts.entry(host_id(&mut request)).or_default();
                let event: HostEvent = parse(request)?;
                let effects = host.apply(event);
                let mut reply = Self::host_reply(host)?;
                reply["effects"] = encode(effects)?;
                Ok(reply)
            }
            "rd_hub_host_state" => {
                let mut request = request;
                let id = host_id(&mut request);
                Self::host_reply(self.hosts.get(&id).unwrap_or(&Host::default()))
            }
            "rd_hub_host_close" => {
                let mut request = request;
                Ok(json!({ "closed": self.hosts.remove(&host_id(&mut request)).is_some() }))
            }
            "rd_hub_end_reason" => {
                let ReasonRequest { reason } = parse(request)?;
                let end = EndReason::parse(reason.as_deref());
                Ok(json!({
                    "reason": end,
                    "failure_detail": EndReason::failure_detail(reason.as_deref()),
                    "can_reconnect": end.can_reconnect(),
                    "removes_access": end.removes_access(),
                    "message": encode(end.message())?,
                }))
            }
            "rd_hub_failure" => {
                let Why { why } = parse(request)?;
                Ok(json!({ "reason": HubReason::failure(&why) }))
            }
            "rd_hub_refusal" => {
                let ErrorRequest { error } = parse(request)?;
                let refusal = Refusal::from_error(&error);
                Ok(json!({ "refusal": encode(&refusal)?, "can_retry": refusal.can_retry() }))
            }
            "rd_hub_approval" => {
                let ApprovalRequest { choice, requested } = parse(request)?;
                Ok(
                    json!({ "answer": encode(choice.answer(requested))?, "title": encode(choice.title())? }),
                )
            }
            "rd_hub_access" => {
                let levels: Vec<Value> = Access::ALL
                    .iter()
                    .map(|a| {
                        json!({
                            "access": a,
                            "value": a.value(),
                            "title": a.title(),
                            "allows_requests": a.allows_requests(),
                            "grants_view": a.grants(Scope::View),
                            "grants_full": a.grants(Scope::Full),
                        })
                    })
                    .collect();
                let scopes: Vec<Value> = [Scope::View, Scope::Full]
                    .iter()
                    .map(|s| json!({ "scope": s, "title": s.title() }))
                    .collect();
                let choices: Vec<Value> = ApprovalChoice::ALL
                    .iter()
                    .map(|c| json!({ "choice": c, "title": c.title() }))
                    .collect();
                Ok(json!({ "levels": levels, "scopes": scopes, "choices": choices }))
            }
            "rd_hub_scope_to_request" => {
                let ScopeRequest { last, access } = parse(request)?;
                Ok(json!({ "scope": scope_to_request(last, access) }))
            }
            "rd_hub_sharing" => {
                let r: SharingRequest = parse(request)?;
                let step =
                    default_sharing_step(r.shared, r.grant_known, r.screen_recording, r.turned_off);
                let state = sharing_state(
                    r.shared.unwrap_or(false),
                    r.grant_known,
                    r.screen_recording,
                    r.turned_off.unwrap_or(false),
                );
                Ok(json!({ "step": step, "state": state }))
            }
            "rd_hub_startup_message" => {
                let StartupRequest { startup_failed } = parse(request)?;
                Ok(json!({ "message": encode(hub_startup_message(startup_failed))? }))
            }
            _ => Err(format!("unknown op {op}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_viewer_lives_by_id_until_closed() {
        let mut m = RdHub::new();
        assert!(RdHub::serves("rd_hub_viewer_event") && !RdHub::serves("mac_screen_offer"));
        let open = m.call("rd_hub_viewer_open", json!({"id": "t1", "device_id": "host"})).unwrap();
        assert_eq!(open["phase"], json!({"phase": "idle"}));
        assert!(
            m.call("rd_hub_viewer_event", json!({"id": "t9", "event": {"event": "denied"}}))
                .is_err()
        );
        let reply = m
            .call(
                "rd_hub_viewer_event",
                json!({"id": "t1", "event": {"event": "request", "scope": "view", "hub": true}}),
            )
            .unwrap();
        assert_eq!(reply["state"]["phase"], json!({"phase": "requesting", "scope": "view"}));
        assert_eq!(
            reply["effects"].as_array().unwrap().last().unwrap(),
            &json!({"effect": "send_request", "scope": "view"})
        );
        let ticket =
            json!({"session_id": "s1", "role": "viewer", "peer_id": "host", "scope": "view"});
        assert_eq!(
            m.call("rd_hub_viewer_accepts", json!({"id": "t1", "ticket": ticket})).unwrap()["accepts"],
            true
        );
        let reply = m
            .call(
                "rd_hub_viewer_event",
                json!({"id": "t1", "event": {"event": "request_returned", "scope": "view", "hub": true,
                    "answer": {"ok": {"id": "s1", "state": "pending", "scope": null}}}}),
            )
            .unwrap();
        assert_eq!(reply["state"]["phase"]["phase"], "waiting_for_approval");
        let reply = m
            .call(
                "rd_hub_viewer_event",
                json!({"id": "t1", "event": {"event": "request_returned", "scope": "view", "hub": true,
                    "answer": {"err": {"error": "server", "status": 403, "code": "permission_none", "message": ""}}}}),
            )
            .unwrap();
        assert_eq!(
            reply["state"]["phase"]["phase"], "waiting_for_approval",
            "only while requesting"
        );
        assert_eq!(
            m.call("rd_hub_viewer_state", json!({"id": "t1"})).unwrap()["last_scope"],
            "view"
        );
        assert_eq!(m.call("rd_hub_viewer_close", json!({"id": "t1"})).unwrap()["closed"], true);
        assert!(m.call("rd_hub_viewer_state", json!({"id": "t1"})).is_err());
        assert!(m.call("rd_hub_nope", Value::Null).is_err());
    }

    #[test]
    fn the_host_serves_and_names_its_viewer() {
        let mut m = RdHub::new();
        assert_eq!(
            m.call("rd_hub_host_state", Value::Null).unwrap()["no_session_reason"]["key"],
            "macScreen.indicator.noSession"
        );
        let ticket = json!({"session_id": "s1", "scope": "view", "viewer_id": "v1", "viewer_name": "Studio", "own_account": true});
        let reply = m
            .call(
                "rd_hub_host_event",
                json!({"event": "serve", "ticket": ticket, "hub": true, "consent_gate": true}),
            )
            .unwrap();
        assert_eq!(reply["effects"][0]["effect"], "start");
        assert_eq!(reply["no_session_reason"], Value::Null);
        let reply = m
            .call("rd_hub_host_event", json!({"event": "viewer_connected", "session_id": "s1"}))
            .unwrap();
        assert_eq!(reply["indicator"]["key"], "macScreen.indicator.viewing");
        let reply = m.call("rd_hub_host_event", json!({"event": "stop", "hub": true})).unwrap();
        assert_eq!(
            reply["effects"],
            json!([{"effect": "end_then_stop", "session_id": "s1", "reason": "host_stopped"}])
        );
    }

    #[test]
    fn hosts_live_by_id_and_a_viewer_takes_a_phase() {
        let mut m = RdHub::new();
        let ticket = json!({"session_id": "s1", "scope": "full", "viewer_id": "v1", "viewer_name": "Air", "own_account": true});
        m.call(
            "rd_hub_host_event",
            json!({"host": "h1", "event": "serve", "ticket": ticket, "hub": true, "consent_gate": false}),
        )
        .unwrap();
        let state = |m: &mut RdHub, id: &str| {
            m.call("rd_hub_host_state", json!({"host": id})).unwrap()["state"]["session"].clone()
        };
        assert_eq!(state(&mut m, "h1")["id"], "s1");
        assert_eq!(state(&mut m, "h2"), Value::Null);
        assert_eq!(m.call("rd_hub_host_close", json!({"host": "h1"})).unwrap()["closed"], true);
        assert_eq!(state(&mut m, "h1"), Value::Null);

        m.call("rd_hub_viewer_open", json!({"id": "t1", "device_id": "host"})).unwrap();
        let phase = json!({"phase": "streaming", "session_id": "s1", "scope": "view"});
        let state = m.call("rd_hub_viewer_set_phase", json!({"id": "t1", "phase": phase})).unwrap();
        assert_eq!(state["phase"], phase);
        let refused = json!({"phase": "refused", "refusal": {"refusal": "other", "reason": "x"}, "requested": "full"});
        let state =
            m.call("rd_hub_viewer_set_phase", json!({"id": "t1", "phase": refused})).unwrap();
        assert_eq!(state["phase"], refused);
    }

    #[test]
    fn the_stateless_rules_answer() {
        let mut m = RdHub::new();
        let end = m.call("rd_hub_end_reason", json!({"reason": "failed: no helper"})).unwrap();
        assert_eq!(
            (end["reason"].clone(), end["failure_detail"].clone()),
            (json!("failed"), json!("no helper"))
        );
        assert_eq!(
            m.call("rd_hub_end_reason", json!({"reason": null})).unwrap()["reason"],
            "other"
        );
        assert_eq!(
            m.call("rd_hub_failure", json!({"why": "a\nb"})).unwrap()["reason"],
            "failed: a b"
        );
        let r = m.call("rd_hub_refusal", json!({"error": {"error": "server", "status": 404, "code": "not_found", "message": ""}})).unwrap();
        assert_eq!(r, json!({"refusal": {"refusal": "not_found"}, "can_retry": false}));
        let a = m
            .call("rd_hub_approval", json!({"choice": "always_full", "requested": "view"}))
            .unwrap();
        assert_eq!(
            a["answer"],
            json!({"decision": "always", "scope": "view", "then_permission": "full"})
        );
        let levels = m.call("rd_hub_access", Value::Null).unwrap();
        assert_eq!(levels["levels"].as_array().unwrap().len(), 4);
        assert_eq!(levels["choices"][0]["title"]["text"], "Deny");
        assert_eq!(
            m.call("rd_hub_scope_to_request", json!({"last": "full", "access": "view"})).unwrap()["scope"],
            "view"
        );
        let s = m
            .call("rd_hub_sharing", json!({"shared": false, "grant_known": true, "screen_recording": true, "turned_off": false}))
            .unwrap();
        assert_eq!(s, json!({"step": "turn_on", "state": "off"}));
        assert_eq!(
            m.call("rd_hub_startup_message", json!({"startup_failed": false})).unwrap()["message"],
            Value::Null
        );
    }
}
