//! The Mac Screen rules over one JSON channel (ops `mac_screen_*`), the shape the app's C ABI
//! (`cmux_layout_reducer_json`) carries: each session's reducer by id, and the stateless rules
//! (the offer, the document, the failure words, the path label, the connect stages).

use super::offer::{Customize, OfferInputs, Quality, customize, lacks_display, make_offer, wish};
use super::session::{Event, Session, failure_cause_of_ended, host_end, path_label};
use super::stage::Stage;
use cmux_rd_proto::rd_doc::{RdDocument, is_relayed, servers};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashMap;

/// Every live session's reducer, by the app's session id.
#[derive(Default)]
pub struct MacScreen {
    sessions: HashMap<String, Session>,
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
                let (stun, turn) = servers(&request);
                Ok(json!({ "stun": stun, "turn": encode(turn)? }))
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
            _ => Err(format!("unknown op {op}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_lives_by_id_until_closed() {
        let mut m = MacScreen::new();
        assert!(
            MacScreen::serves("mac_screen_session_event") && !MacScreen::serves("tab_discard_plan")
        );
        let open = m.call("mac_screen_session_open", json!({"id": "a"})).unwrap();
        assert_eq!(open["phase"], "ended");
        let reply = m
            .call(
                "mac_screen_session_event",
                json!({"id": "a", "event": {"event": "connect", "signaling": true, "process_started": true}}),
            )
            .unwrap();
        assert_eq!(reply["state"]["phase"], "connecting");
        assert_eq!(reply["effects"][1], json!({"effect": "schedule_deadline", "ms": 15000}));
        let reply = m
            .call(
                "mac_screen_session_event",
                json!({"id": "a", "event": {"event": "process_line", "line": {"path": {"kind": "direct_lan", "rtt_ms": 2.0}}}}),
            )
            .unwrap();
        assert_eq!(reply["path_label"]["key"], "macScreen.rd.pathLan");
        assert_eq!(
            m.call("mac_screen_session_state", json!({"id": "a"})).unwrap()["state"]["phase"],
            "connecting"
        );
        assert_eq!(m.call("mac_screen_session_close", json!({"id": "a"})).unwrap()["closed"], true);
        assert!(m.call("mac_screen_session_state", json!({"id": "a"})).is_err());
        assert!(m.call("mac_screen_nope", Value::Null).is_err());
    }

    #[test]
    fn the_stateless_rules_answer() {
        let mut m = MacScreen::new();
        let w = m.call("mac_screen_wish", json!({"quality": "smooth", "refresh": 120})).unwrap();
        assert_eq!(w, json!({"max_width": 1920, "max_fps": 120}));
        let key = "ab".repeat(32);
        let offer = m.call("mac_screen_offer", json!({"key": key, "linked_display": 5})).unwrap();
        let text = offer["text"].as_str().unwrap().to_owned();
        assert!(text.contains("a=cmux-rd-display-id:5\r\n"));
        assert_eq!(m.call("mac_screen_doc_parse", json!({"text": text})).unwrap()["key"], key);
        assert_eq!(m.call("mac_screen_doc_parse", json!({"text": "v=0"})).unwrap(), Value::Null);
        let hidden = m
            .call(
                "mac_screen_customize",
                json!({"text": text, "customize": {"show_cursor": false}}),
            )
            .unwrap();
        assert!(hidden["text"].as_str().unwrap().contains("a=cmux-rd-cursor:0\r\n"));
        assert_eq!(
            m.call("mac_screen_lacks_display", json!({"text": text, "id": 5})).unwrap()["lacks"],
            false
        );
        assert_eq!(
            m.call("mac_screen_failure_cause", json!({"text": "link failed: x"})).unwrap(),
            json!({"link": "x"})
        );
        assert_eq!(
            m.call("mac_screen_host_end", json!({"text": "failed: y"})).unwrap(),
            json!({"host_failed": "y"})
        );
        assert_eq!(
            m.call("mac_screen_host_end", json!({"text": "stopped"})).unwrap(),
            json!("host_stopped_sharing")
        );
        let path = m.call("mac_screen_path", json!({"kind": "turn_relay"})).unwrap();
        assert_eq!(
            (path["relayed"].clone(), path["label"]["text"].clone()),
            (json!(true), json!("Relayed"))
        );
        let stages = m.call("mac_screen_stages", Value::Null).unwrap();
        assert_eq!(stages["stages"][0]["timeout_key"], "macScreen.card.noAnswer");
        assert_eq!(stages["connect_timeout_ms"], 15000);
    }
}
