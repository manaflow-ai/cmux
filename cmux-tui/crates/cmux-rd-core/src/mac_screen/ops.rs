//! The Mac Screen rules over one JSON channel (ops `mac_screen_*`), the shape the app's C ABI
//! (`cmux_layout_reducer_json`) carries: each session's reducer by id, and the stateless rules
//! (the offer, the document, the failure words, the path label, the connect stages).

use super::offer::{Customize, OfferInputs, Quality, customize, lacks_display, make_offer, wish};
use super::rd_host::{Host, HostInput, HostSession, line_kinds, setup};
use super::session::{Event, Session, failure_cause_of_ended, host_end, path_label};
use super::stage::Stage;
use cmux_rd_proto::rd_doc::{RdDocument, is_relayed, servers, udp_only};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashMap;

/// Every live session's reducer, by the app's session id.
#[derive(Default)]
pub struct MacScreen {
    sessions: HashMap<String, Session>,
    hosts: HashMap<String, Host>,
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
struct SessionEvent {
    id: String,
    event: Event,
}

#[derive(Deserialize)]
struct Text {
    text: String,
}

#[derive(Deserialize)]
#[serde(default)]
struct WishRequest {
    quality: Quality,
    refresh: i64,
    pane_width: Option<i64>,
    max_fps: Option<i64>,
}

impl Default for WishRequest {
    fn default() -> Self {
        WishRequest { quality: Quality::Auto, refresh: 60, pane_width: None, max_fps: None }
    }
}

#[derive(Deserialize)]
struct OfferRequest {
    key: String,
    #[serde(default)]
    inputs: OfferInputs,
    wanted_display: Option<i64>,
    linked_display: Option<u32>,
}

#[derive(Deserialize)]
struct CustomizeRequest {
    text: String,
    customize: Customize,
}

#[derive(Deserialize)]
struct LacksRequest {
    text: String,
    id: u32,
}

#[derive(Deserialize)]
struct HostOpen {
    id: String,
    #[serde(default)]
    session: HostSession,
}

#[derive(Deserialize)]
struct HostApply {
    id: String,
    input: HostInput,
}

#[derive(Deserialize)]
struct SetupRequest {
    session: HostSession,
    offer: String,
}

#[derive(Deserialize)]
struct PathRequest {
    kind: Option<String>,
}

impl MacScreen {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn serves(op: &str) -> bool {
        op.starts_with("mac_screen_")
    }

    pub fn call(&mut self, op: &str, request: Value) -> Result<Value, String> {
        match op {
            "mac_screen_session_open" => {
                let Id { id } = parse(request)?;
                let session = self.sessions.entry(id).or_default();
                encode(&*session)
            }
            "mac_screen_session_event" => {
                let SessionEvent { id, event } = parse(request)?;
                let session = self.sessions.entry(id).or_default();
                let effects = session.apply(event);
                Ok(
                    json!({ "state": encode(&*session)?, "path_label": encode(session.path_label())?, "effects": encode(effects)? }),
                )
            }
            "mac_screen_session_state" => {
                let Id { id } = parse(request)?;
                let session = self.sessions.get(&id).ok_or_else(|| format!("no session {id}"))?;
                Ok(
                    json!({ "state": encode(session)?, "path_label": encode(session.path_label())? }),
                )
            }
            "mac_screen_session_close" => {
                let Id { id } = parse(request)?;
                Ok(json!({ "closed": self.sessions.remove(&id).is_some() }))
            }
            "mac_screen_wish" => {
                let r: WishRequest = parse(request)?;
                encode(wish(r.quality, r.refresh, r.pane_width, r.max_fps))
            }
            "mac_screen_offer" => {
                let r: OfferRequest = parse(request)?;
                let (doc, wish) = make_offer(&r.key, &r.inputs, r.wanted_display, r.linked_display);
                Ok(json!({ "text": doc.text(), "doc": encode(&doc)?, "wish": encode(wish)? }))
            }
            "mac_screen_doc_parse" => {
                let Text { text } = parse(request)?;
                encode(RdDocument::parse(&text))
            }
            "mac_screen_doc_text" => {
                let doc: RdDocument = parse(request)?;
                Ok(json!({ "text": doc.text() }))
            }
            "mac_screen_customize" => {
                let r: CustomizeRequest = parse(request)?;
                let mut doc = RdDocument::parse(&r.text).ok_or("not a cmux.rd/1 document")?;
                customize(&mut doc, r.customize);
                Ok(json!({ "text": doc.text() }))
            }
            "mac_screen_lacks_display" => {
                let r: LacksRequest = parse(request)?;
                let doc = RdDocument::parse(&r.text).ok_or("not a cmux.rd/1 document")?;
                Ok(json!({ "lacks": lacks_display(&doc, r.id) }))
            }
            "mac_screen_servers" => {
                // The Mac's link speaks UDP TURN; the TCP and TLS relays stay out.
                let (stun, turn) = servers(&request);
                Ok(json!({ "stun": stun, "turn": encode(udp_only(&turn))? }))
            }
            "mac_screen_failure_cause" => {
                let Text { text } = parse(request)?;
                encode(failure_cause_of_ended(&text))
            }
            "mac_screen_host_end" => {
                let Text { text } = parse(request)?;
                encode(host_end(&text))
            }
            "mac_screen_path" => {
                let PathRequest { kind } = parse(request)?;
                let relayed = kind.as_deref().is_some_and(is_relayed);
                Ok(json!({ "relayed": relayed, "label": encode(path_label(kind.as_deref()))? }))
            }
            "mac_screen_stages" => {
                let stages: Vec<Value> = Stage::ALL
                    .iter()
                    .map(|s| {
                        json!({ "stage": s, "name": s.name(), "timing_key": s.timing_key(), "timeout_key": s.timeout_key() })
                    })
                    .collect();
                Ok(
                    json!({ "stages": stages, "connect_timeout_ms": super::stage::CONNECT_TIMEOUT_MS }),
                )
            }
            "mac_screen_host_open" => {
                let HostOpen { id, session } = parse(request)?;
                let host = Host::new(session);
                let state = encode(&host)?;
                self.hosts.insert(id, host);
                Ok(state)
            }
            "mac_screen_host_input" => {
                let HostApply { id, input } = parse(request)?;
                let host = self.hosts.get_mut(&id).ok_or_else(|| format!("no host {id}"))?;
                let effects = host.apply(input);
                Ok(json!({ "state": encode(&*host)?, "effects": encode(effects)? }))
            }
            "mac_screen_host_close" => {
                let Id { id } = parse(request)?;
                Ok(json!({ "closed": self.hosts.remove(&id).is_some() }))
            }
            "mac_screen_host_setup" => {
                let r: SetupRequest = parse(request)?;
                let offer = RdDocument::parse(&r.offer).ok_or("not a cmux.rd/1 document")?;
                encode(setup(&r.session, &offer))
            }
            "mac_screen_line_kinds" => {
                let line: cmux_rd_proto::app_line::AppLine = parse(request)?;
                Ok(json!({ "kinds": line_kinds(&line) }))
            }
            "mac_screen_exclude_windows" => {
                #[derive(Deserialize)]
                struct Ids {
                    ids: Vec<u32>,
                }
                let Ids { mut ids } = parse(request)?;
                ids.sort_unstable();
                ids.dedup();
                Ok(json!({ "exclude_windows": ids }))
            }
            _ => Err(format!("unknown op {op}")),
        }
    }
}

#[cfg(test)]
#[path = "ops_tests.rs"]
mod tests;
