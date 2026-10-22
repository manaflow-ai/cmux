//! A person-readable line for a permission request whose title and input mean
//! nothing to a person: the tool's raw name and its JSON. Leo 2026-10-21 (cmux
//! #89(4)): "The approval prompt from a paired device shows raw JSON
//! ("mcp__optchat__tell wants to run: {"id":"a12","message":…}"). Render it
//! as a human card: "Chief wants to message a12 · Nightly train", with a
//! preview of the message".
//!
//! The hub stamps `toolCall._meta.acpmux.display` (`actor`, `action`,
//! `target`, `targetLabel`, `headline`, `preview`) into the request before
//! anything records or shows it, so every route that carries the request
//! (the event, `_acpmux/permission_pending`, `_acpmux/info`) carries the line,
//! and the request a person answers is the one the hub keeps. Clients show
//! `headline` and `preview` when present and the raw title otherwise; the
//! request's title and input are left as they are.
//!
//! The names come from orchestrator tags: the asker's `mux.label` (else its
//! session name) says who asks, and the target is the session whose
//! `mux.handle` is the input's id among the asker's children (`mux.parent`
//! equal to the asker's `mux.children`), named by its `mux.label`. Two Chiefs
//! on one daemon each have an a12; only the asker's own is named.

use super::*;

/// Who a session is on an approval card.
const LABEL_TAG: &str = "mux.label";
/// What a parent calls a child (the Chief's subagent id, `a12`).
const HANDLE_TAG: &str = "mux.handle";
/// On a parent: the `mux.parent` value its children carry.
const CHILDREN_TAG: &str = "mux.children";
const PARENT_TAG: &str = "mux.parent";

/// The longest preview, in characters, ellipsis included.
const PREVIEW_CHARS: usize = 280;

/// A tool whose request reads as "<actor> wants to <action> <target>": the
/// input field that names the target and the one whose text is previewed.
struct Spoken {
    tool: &'static str,
    action: &'static str,
    target: &'static str,
    text: &'static str,
}

/// The tools a person approves by what they do. `mcp__optchat__tell` is the
/// Chief's message to one of its subagents (optchat-chief `tools.rs`).
const SPOKEN: &[Spoken] =
    &[Spoken { tool: "mcp__optchat__tell", action: "message", target: "id", text: "message" }];

impl Hub {
    /// Stamps the request's `_meta.acpmux.display` when its tool reads as a
    /// sentence (see the module docs); any other request is left alone.
    pub(super) fn stamp_permission_display(&self, session: &Session, request: &mut Value) {
        let Some(display) = self.permission_display(session, request) else { return };
        let Some(call) = request.get_mut("toolCall").and_then(Value::as_object_mut) else { return };
        let meta = call.entry("_meta").or_insert_with(|| json!({}));
        if !meta.is_object() {
            *meta = json!({});
        }
        let Some(meta) = meta.as_object_mut() else { return };
        let acpmux = meta.entry("acpmux").or_insert_with(|| json!({}));
        if !acpmux.is_object() {
            *acpmux = json!({});
        }
        if let Some(acpmux) = acpmux.as_object_mut() {
            acpmux.insert("display".into(), display);
        }
    }

    fn permission_display(&self, session: &Session, request: &Value) -> Option<Value> {
        let call = request.get("toolCall")?;
        let tool = call
            .pointer("/_meta/claude/tool")
            .or_else(|| call.pointer("/_meta/claudeCode/toolName"))
            .or_else(|| call.get("title"))
            .and_then(Value::as_str)?;
        let spoken = SPOKEN.iter().find(|s| s.tool == tool)?;
        let input = call.get("rawInput")?;
        let target = text(input.get(spoken.target)?)?;
        let (actor, children) = {
            let meta = session.meta.lock().unwrap();
            let actor = live_tag(&meta, LABEL_TAG).unwrap_or_else(|| meta.name.clone());
            (actor, live_tag(&meta, CHILDREN_TAG))
        };
        let target_label = children.and_then(|parent| self.child_label(&parent, &target));
        let mut headline = format!("{actor} wants to {} {target}", spoken.action);
        let mut display = json!({"actor": actor, "action": spoken.action, "target": target});
        if let Some(label) = target_label {
            headline.push_str(" · ");
            headline.push_str(&label);
            display["targetLabel"] = Value::String(label);
        }
        display["headline"] = Value::String(headline);
        if let Some(preview) = input.get(spoken.text).and_then(Value::as_str).map(one_line) {
            display["preview"] = Value::String(preview);
        }
        Some(display)
    }

    /// The `mux.label` of the child of `parent` whose handle is `handle`: a
    /// session here, else one a peer lists (a cloud subagent), whose row
    /// carries its live tags.
    fn child_label(&self, parent: &str, handle: &str) -> Option<String> {
        let local = self.sessions().iter().find_map(|s| {
            let meta = s.meta.lock().unwrap();
            let mine = live_tag(&meta, PARENT_TAG).as_deref() == Some(parent)
                && live_tag(&meta, HANDLE_TAG).as_deref() == Some(handle);
            if mine { live_tag(&meta, LABEL_TAG) } else { None }
        });
        local.or_else(|| {
            let rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
            rows.values().find_map(|r| {
                let tags = r.summary.get("tags")?;
                let tag = |key: &str| tags.get(key).and_then(text);
                let mine = tag(PARENT_TAG).as_deref() == Some(parent)
                    && tag(HANDLE_TAG).as_deref() == Some(handle);
                if mine { tag(LABEL_TAG) } else { None }
            })
        })
    }
}

/// `key`'s value on `meta`, unless it expired or is blank.
fn live_tag(meta: &SessionMeta, key: &str) -> Option<String> {
    let tag = meta.tags.get(key)?;
    if tag.expires_at.is_some_and(|e| e <= now_ms()) {
        return None;
    }
    text(&Value::String(tag.value.clone()))
}

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

/// `text` on one line (runs of whitespace, line breaks included, become one
/// space), at most [`PREVIEW_CHARS`] characters with an ellipsis when cut.
fn one_line(text: &str) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() <= PREVIEW_CHARS {
        return line;
    }
    let cut: String = line.chars().take(PREVIEW_CHARS - 1).collect();
    format!("{}…", cut.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::PeerNotice;

    /// A hub with peer `name` registered (its link never runs) that lists `sessions`.
    fn hub_with_peer(name: &str, sessions: Vec<Value>) -> (Arc<Hub>, cmux_unix_socket::TestDir) {
        let dir = cmux_unix_socket::short_test_dir("acpmux-pd");
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, dir.path()).unwrap();
        let hub = Hub::new(cfg, store);
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
        hub.apply_peer_notice(name, peer.generation, PeerNotice::Sessions(sessions));
        (hub, dir)
    }

    fn row(id: &str, tags: Value) -> Value {
        json!({"sessionId": id, "name": id, "status": "idle", "turnCount": 1, "updatedAt": 5, "tags": tags})
    }

    /// A cloud subagent (optchat-chief `OPTCHAT_SUBAGENT_PEER`) runs on a
    /// peer: its tags come with the peer's session list.
    #[test]
    fn a_child_on_a_peer_is_named_too() {
        let (hub, _dir) = hub_with_peer(
            "cloud-vm",
            vec![
                row(
                    "m1",
                    json!({"mux.parent": "optchat-chief:h0me", "mux.handle": "a12", "mux.label": "Nightly train"}),
                ),
                row(
                    "m2",
                    json!({"mux.parent": "optchat-chief:0ther", "mux.handle": "a13", "mux.label": "Not ours"}),
                ),
            ],
        );
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12").as_deref(), Some("Nightly train"));
        assert_eq!(hub.child_label("optchat-chief:h0me", "a13"), None, "another Chief's child");
    }
}
