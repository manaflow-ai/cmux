//! Chiefs from the person's page (`chief-profile-ws-v1`, cmux#13742): a real
//! headless daemon with its WebSocket listener. A page that presented the
//! daemon's credential lists, creates and renames a Chief and sets its
//! picture; widening its tools or deleting it needs the person's gesture in
//! the cmux app, which a WebSocket never carries, so both are refused and
//! nothing changes.

use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

use super::super::*;
use super::{TOKEN, Ws, ws_addr};

/// A 1x1 PNG.
const PNG: &[u8] = &[
    0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13, b'I', b'H', b'D', b'R', 0, 0,
    0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 10, b'I', b'D', b'A', b'T',
    0x78, 0x9c, 0x63, 0, 1, 0, 0, 5, 0, 1, 0x0d, 0x0a, 0x2d, 0xb4, 0, 0, 0, 0, b'I', b'E', b'N',
    b'D', 0xae, 0x42, 0x60, 0x82,
];

impl Ws {
    /// One `cmux.protocol/2` request; the whole response.
    fn v2(&mut self, operation: &str, fields: Value, key: Option<&str>) -> Value {
        let id = format!("chief-{}", self.next);
        self.next += 1;
        let mut params = fields.as_object().cloned().unwrap_or_default();
        params.insert("machine".into(), json!("current"));
        params.insert("session".into(), json!("current"));
        let mut frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                               "operation": operation, "params": params});
        if let Some(key) = key {
            frame["idempotency_key"] = json!(key);
        }
        self.socket.send(Message::Text(frame.to_string().into())).unwrap();
        loop {
            let value = self.read();
            if value.get("event").is_some() {
                self.events.push_back(value);
                continue;
            }
            if value["id"] == json!(id) {
                return value;
            }
        }
    }
}

fn ok(response: &Value) -> Value {
    assert_eq!(response["ok"], true, "{response}");
    response["result"].clone()
}

fn gesture_required(response: &Value) {
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "origin.forbidden", "{response}");
    assert_eq!(response["error"]["details"]["reason"], "gesture_required", "{response}");
}

#[test]
fn the_persons_page_makes_a_chief_with_a_picture_but_cannot_widen_or_delete_it() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("ws-chief-profiles", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "chief-profile-ws-v1"), "{identity}");

    let listed = ok(&page.v2("chief.profile.list", json!({}), None));
    assert_eq!(listed["chiefs"][0]["id"], "agent_mux", "{listed}");

    let made = ok(&page.v2(
        "chief.profile.create",
        json!({"display_name": "Ops", "role": "Release captain", "personality": "Brief.",
               "instructions": "Ask before any merge."}),
        Some("ws-chief-create"),
    ));
    let id = made["value"]["id"].as_str().unwrap().to_owned();
    assert!(id.starts_with("agent_"), "{made}");
    assert_eq!(made["value"]["tools"], json!(["spawn", "tell", "workspaces"]), "{made}");
    // A retry with the same key is the same Chief.
    let again = ok(&page.v2(
        "chief.profile.create",
        json!({"display_name": "Ops", "role": "Release captain", "personality": "Brief.",
               "instructions": "Ask before any merge."}),
        Some("ws-chief-create"),
    ));
    assert_eq!(again["value"]["id"], json!(id), "{again}");
    assert_eq!(again["replayed"], true, "{again}");

    let renamed = ok(&page.v2(
        "chief.profile.update",
        json!({"chief": id, "display_name": "Ops Chief"}),
        Some("ws-chief-rename"),
    ));
    assert_eq!(renamed["value"]["display_name"], "Ops Chief", "{renamed}");
    let data = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, PNG);
    let pictured = ok(&page.v2(
        "chief.profile.avatar.set",
        json!({"chief": id, "media_type": "image/png", "data": data}),
        Some("ws-chief-avatar"),
    ));
    assert_eq!(pictured["value"]["avatar"]["media_type"], "image/png", "{pictured}");
    let picture = ok(&page.v2("chief.profile.avatar.get", json!({"chief": id}), None));
    assert_eq!(picture["avatar"]["data"], json!(data), "{picture}");

    gesture_required(&page.v2(
        "chief.profile.update",
        json!({"chief": id, "tools": ["browser", "spawn"]}),
        Some("ws-chief-widen"),
    ));
    gesture_required(&page.v2(
        "chief.profile.create",
        json!({"display_name": "Wide", "harnesses": ["codex"]}),
        Some("ws-chief-wide"),
    ));
    gesture_required(&page.v2(
        "chief.profile.delete",
        json!({"chief": id}),
        Some("ws-chief-delete"),
    ));

    let kept = ok(&page.v2("chief.profile.get", json!({"chief": id}), None));
    assert_eq!(kept["tools"], json!(["spawn", "tell", "workspaces"]), "{kept}");
    let listed = ok(&page.v2("chief.profile.list", json!({}), None));
    assert_eq!(listed["chiefs"].as_array().unwrap().len(), 2, "{listed}");
}
