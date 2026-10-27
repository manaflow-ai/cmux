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

/// Where each parent's children are: the sessions tagged with each `(mux.parent, mux.handle)`, kept
/// as tags are written (`Hub::set_tags`), as sessions are made (`Hub::make_session`: a load, a new
/// chat, a fork, an import) and as they are removed (`forget`). A lookup reads one entry instead of
/// every session; each entry is a hint that the lookup checks against the session's live tags
/// again, so a stale one names nobody, and an id no longer in the hub leaves the index there. A
/// peer's rows have their own index, kept with them (`remote_rows.rs`).
#[derive(Default)]
pub(crate) struct ChildTags(std::sync::Mutex<ChildIndex>, #[cfg(test)] Pause);

/// A test's hook at a named point of `note` or `child_label`, to run another writer there.
#[cfg(test)]
type PauseHook = Arc<dyn Fn(&'static str, &str) + Send + Sync>;
#[cfg(test)]
#[derive(Default)]
pub(crate) struct Pause(std::sync::Mutex<Option<PauseHook>>);

#[derive(Default)]
struct ChildIndex {
    /// Local sessions by `(mux.parent, mux.handle)`.
    local: HashMap<(String, String), std::collections::BTreeSet<String>>,
    /// Each indexed session's pair, to move it when its tags change.
    pair_of: HashMap<String, (String, String)>,
}

impl ChildTags {
    fn index(&self) -> std::sync::MutexGuard<'_, ChildIndex> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(test)]
    fn pause(&self, point: &'static str, id: &str) {
        let hook = self.1.0.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(hook) = hook {
            hook(point, id);
        }
    }

    #[cfg(not(test))]
    fn pause(&self, _point: &'static str, _id: &str) {}

    /// Indexes `session` under its live `mux.parent` and `mux.handle` tags now (or takes it out).
    /// A tag that expires later is dropped by the first lookup that meets it (`child_label`).
    /// The tags are read and published under the session's meta lock (taken before the index's,
    /// never the other way), so of two concurrent tag writes the later one's pair is what stays.
    pub(crate) fn note(&self, session: &Session) {
        self.pause("note.publish", &session.id);
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let pair = live_tag(&meta, PARENT_TAG).zip(live_tag(&meta, HANDLE_TAG));
        let mut index = self.index();
        if let Some(old) = index.pair_of.remove(&session.id)
            && let Some(ids) = index.local.get_mut(&old)
        {
            ids.remove(&session.id);
            if ids.is_empty() {
                index.local.remove(&old);
            }
        }
        if let Some(pair) = pair {
            index.local.entry(pair.clone()).or_default().insert(session.id.clone());
            index.pair_of.insert(session.id.clone(), pair);
        }
    }

    /// Takes session `id` out of the index: it was removed from the hub's sessions (a purge, a
    /// chat whose creation failed), or a lookup found it gone.
    pub(crate) fn forget(&self, id: &str) {
        let mut index = self.index();
        if let Some(old) = index.pair_of.remove(id)
            && let Some(ids) = index.local.get_mut(&old)
        {
            ids.remove(id);
            if ids.is_empty() {
                index.local.remove(&old);
            }
        }
    }

    fn local(&self, pair: &(String, String)) -> Vec<String> {
        self.index().local.get(pair).map(|ids| ids.iter().cloned().collect()).unwrap_or_default()
    }
}

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

/// What a tool call or an ask carries of the agent's own: its input, output and content, and the
/// ask's options. Whatever is inside them (a display-shaped field included) is the agent's data,
/// shown and approved as it is.
const AGENT_DATA: [&str; 4] = ["rawInput", "rawOutput", "content", "options"];

/// Drops the display line (`toolCall._meta.acpmux.display`) of every permission request in
/// `value`, wherever one sits: a pending prompt, an event record, the agent's own ask. What a peer
/// daemon sends (its pending prompts, its event records, its replies) carries no display line of
/// its own to this daemon's clients, since a peer on an older build passes on whatever its agent
/// wrote there. Only this daemon's own stamp (`Hub::stamp_permission_display`) reaches a person;
/// a peer's prompt shows its raw title, as before display lines. Nothing else changes: the
/// agent's data (`AGENT_DATA`) is never looked into.
pub(crate) fn drop_display_lines(value: &mut Value) {
    match value {
        Value::Object(map) => {
            if let Some(acpmux) = map
                .get_mut("toolCall")
                .and_then(|call| call.get_mut("_meta"))
                .and_then(|meta| meta.get_mut("acpmux"))
                .and_then(Value::as_object_mut)
            {
                acpmux.remove("display");
            }
            for (key, child) in map.iter_mut() {
                if !AGENT_DATA.contains(&key.as_str()) {
                    drop_display_lines(child);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(drop_display_lines),
        _ => {}
    }
}

impl Hub {
    /// A logged record as a client reads it (`events_page`): an ask acpmux recorded carries the
    /// display line worked out now, never one the log kept (an older build logged the agent's
    /// words as they came), and the agent's own ask (`in`) carries none.
    pub(in crate::hub) fn display_logged(
        &self,
        session: Option<&Session>,
        record: &mut crate::store::EventRecord,
    ) {
        match record.dir.as_str() {
            "mux"
                if matches!(
                    record.kind.as_str(),
                    "permission_request" | "permission_reissued" | "permission_auto"
                ) =>
            {
                if let Some(request) = record.msg.get_mut("request") {
                    match session {
                        Some(session) => self.stamp_permission_display(session, request),
                        None => drop_display_lines(request),
                    }
                }
            }
            // A group lists its asks' requests: each is read back as the ask itself is.
            "mux" if record.kind == "permission_group" => {
                let items = record.msg.pointer_mut("/group/items").and_then(Value::as_array_mut);
                for request in items.into_iter().flatten().filter_map(|i| i.get_mut("request")) {
                    match session {
                        Some(session) => self.stamp_permission_display(session, request),
                        None => drop_display_lines(request),
                    }
                }
            }
            "in" if record.msg.get("method").and_then(Value::as_str)
                == Some(crate::rpc::method::SESSION_REQUEST_PERMISSION) =>
            {
                if let Some(params) = record.msg.get_mut("params") {
                    drop_display_lines(params);
                }
            }
            _ => {}
        }
    }

    /// Stamps the request's `_meta.acpmux.display` when its tool reads as a
    /// sentence (see the module docs). A display the request came with (the
    /// agent's own words) is dropped first, from every request: only acpmux
    /// writes the line a person reads.
    pub(in crate::hub) fn stamp_permission_display(&self, session: &Session, request: &mut Value) {
        if let Some(acpmux) =
            request.pointer_mut("/toolCall/_meta/acpmux").and_then(Value::as_object_mut)
        {
            acpmux.remove("display");
        }
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
            let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
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
    /// Local sessions come from the index (`ChildTags`) and a peer's rows from theirs
    /// (`RemoteRows::with_pair`), never a walk over every session or row.
    fn child_label(&self, parent: &str, handle: &str) -> Option<String> {
        let pair = (parent.to_owned(), handle.to_owned());
        let (mut gone, mut stale) = (Vec::new(), Vec::new());
        let local = self.child_tags.local(&pair).into_iter().find_map(|id| {
            let found = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned();
            let Some(s) = found else {
                gone.push(id);
                return None;
            };
            // Checked and read under one guard: a retag between the two never names another child.
            let meta = s.meta.lock().unwrap_or_else(|e| e.into_inner());
            let mine = live_tag(&meta, PARENT_TAG).as_deref() == Some(parent)
                && live_tag(&meta, HANDLE_TAG).as_deref() == Some(handle);
            if !mine {
                drop(meta);
                stale.push(s);
                return None;
            }
            self.child_tags.pause("label.read", &s.id);
            live_tag(&meta, LABEL_TAG)
        });
        for id in gone {
            self.child_tags.pause("gone.forget", &id);
            // Still absent under the sessions lock: a session published since (an import, a fork,
            // which insert it under that lock and then index it) keeps its entry.
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            if !sessions.contains_key(&id) {
                self.child_tags.forget(&id);
            }
        }
        // Its tags expired or moved: indexed by what it carries now, so it is met once.
        for s in stale {
            self.child_tags.note(&s);
        }
        local.or_else(|| self.peer_child_label(&pair))
    }

    /// `child_label` among the rows peers list (a cloud subagent), whose rows carry their live tags.
    fn peer_child_label(&self, pair: &(String, String)) -> Option<String> {
        let label = |r: &RemoteSession| {
            let tags = r.summary.get("tags")?;
            let tag = |key: &str| tags.get(key).and_then(text);
            let mine = tag(PARENT_TAG).as_deref() == Some(pair.0.as_str())
                && tag(HANDLE_TAG).as_deref() == Some(pair.1.as_str());
            if mine { tag(LABEL_TAG) } else { None }
        };
        let rows = self.remote_sessions.lock().unwrap_or_else(|e| e.into_inner());
        rows.with_pair(pair).find_map(label)
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
        // Found again from the row it was found in, and again after that row moves away.
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12").as_deref(), Some("Nightly train"));
        let generation = hub.peers.lock().unwrap()["cloud-vm"].generation;
        hub.apply_peer_notice(
            "cloud-vm",
            generation,
            PeerNotice::Sessions(vec![row(
                "m3",
                json!({"mux.parent": "optchat-chief:h0me", "mux.handle": "a12", "mux.label": "Moved"}),
            )]),
        );
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12").as_deref(), Some("Moved"));
    }

    /// #24337 review: a child is found through the index, which follows its tags (a session made
    /// from a saved record, as a load makes it, then a tag change) and never names a session gone.
    #[test]
    fn the_child_index_follows_tags() {
        let (hub, _dir) = hub_with_peer("cloud-vm", vec![]);
        // A saved record with its tags, as a load reads it.
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "kid", "name": "kid", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 0, "updatedAt": 0,
            "tags": {"mux.parent": {"value": "optchat-chief:h0me"}, "mux.handle": {"value": "a12"},
                     "mux.label": {"value": "Nightly train"}},
        }))
        .unwrap();
        let kid = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(kid.id.clone(), kid.clone());
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12").as_deref(), Some("Nightly train"));

        let set: serde_json::Map<String, Value> =
            [("mux.handle".to_owned(), json!("a14"))].into_iter().collect();
        hub.set_tags(&kid, Some(&set), &[], None);
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12"), None, "its old handle");
        assert_eq!(hub.child_label("optchat-chief:h0me", "a14").as_deref(), Some("Nightly train"));

        hub.sessions.lock().unwrap().remove(&kid.id);
        assert_eq!(hub.child_label("optchat-chief:h0me", "a14"), None, "a session gone");
        // #24337 review: a session gone leaves no id in the index.
        let index = hub.child_tags.index();
        assert!(index.local.is_empty() && index.pair_of.is_empty(), "{:?}", index.local);
    }

    /// A child's saved record: `tags` over `{"mux.parent": "optchat-chief:h0me"}`.
    fn kid_meta(id: &str, cwd: &std::path::Path, tags: Value) -> Value {
        let mut all = json!({"mux.parent": {"value": "optchat-chief:h0me"}});
        all.as_object_mut().unwrap().extend(tags.as_object().unwrap().clone());
        json!({"schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "fake",
               "cwd": cwd, "status": "idle", "createdAt": 0, "updatedAt": 0, "tags": all})
    }

    /// Review 35 of #24337: a child whose tags expired leaves the index at the first lookup that
    /// meets it, so stale entries are not scanned again on every tell.
    #[test]
    fn an_expired_child_leaves_the_index() {
        let (hub, dir) = hub_with_peer("cloud-vm", vec![]);
        let tags = json!({"mux.handle": {"value": "a12", "expires_at": 1},
                          "mux.label": {"value": "Nightly train"}});
        let kid =
            hub.make_session(serde_json::from_value(kid_meta("kid", dir.path(), tags)).unwrap());
        hub.sessions.lock().unwrap().insert(kid.id.clone(), kid.clone());
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12"), None, "an expired handle");
        let index = hub.child_tags.index();
        assert!(index.local.is_empty() && index.pair_of.is_empty(), "{:?}", index.local);
    }

    /// Runs `write` on its own thread when `point` is first reached, and waits for it at most
    /// 300 ms: a writer the code under test holds out times out, one it lets in finishes first.
    /// The returned call waits for the writer to finish.
    fn race_at(
        hub: &Arc<Hub>,
        point: &'static str,
        write: impl FnOnce() + Send + 'static,
    ) -> impl FnOnce() {
        let write = std::sync::Mutex::new(Some(write));
        let writer = Arc::new(std::sync::Mutex::new(None::<std::thread::JoinHandle<()>>));
        let spawned = writer.clone();
        let hook: PauseHook = Arc::new(move |at, _id| {
            if at != point {
                return;
            }
            let Some(write) = write.lock().unwrap().take() else { return };
            let (done, finished) = std::sync::mpsc::channel();
            *spawned.lock().unwrap() = Some(std::thread::spawn(move || {
                write();
                let _ = done.send(());
            }));
            let _ = finished.recv_timeout(std::time::Duration::from_millis(300));
        });
        *hub.child_tags.1.0.lock().unwrap() = Some(hook);
        move || {
            let handle = writer.lock().unwrap().take();
            handle.expect("the race point was never reached").join().unwrap();
        }
    }

    fn retag(hub: &Arc<Hub>, kid: &Arc<Session>, tags: Value) -> impl FnOnce() + Send + 'static {
        let (hub, kid) = (hub.clone(), kid.clone());
        move || {
            let set = tags.as_object().unwrap().clone();
            hub.set_tags(&kid, Some(&set), &[], None);
        }
    }

    fn published_kid(hub: &Arc<Hub>, dir: &std::path::Path, tags: Value) -> Arc<Session> {
        let kid = hub.make_session(serde_json::from_value(kid_meta("kid", dir, tags)).unwrap());
        hub.sessions.lock().unwrap().insert(kid.id.clone(), kid.clone());
        kid
    }

    /// Review 101 of #24337: a lookup checks a child's pair and reads its label under one guard,
    /// so a retag between the two never puts another child's label on the card.
    #[test]
    fn a_retag_during_a_lookup_never_names_another_child() {
        let (hub, dir) = hub_with_peer("cloud-vm", vec![]);
        let tags = json!({"mux.handle": {"value": "a12"}, "mux.label": {"value": "Nightly train"}});
        let kid = published_kid(&hub, dir.path(), tags);
        let moved = json!({"mux.handle": "a15", "mux.label": "Another child"});
        let settle = race_at(&hub, "label.read", retag(&hub, &kid, moved));
        let label = hub.child_label("optchat-chief:h0me", "a12");
        settle();
        assert_eq!(label.as_deref(), Some("Nightly train"), "a label read after a retag");
        // Settled: the child now answers to its new handle only.
        assert_eq!(hub.child_label("optchat-chief:h0me", "a15").as_deref(), Some("Another child"));
    }

    /// Review 101 of #24337: two tag writes publish to the index in the order they wrote, so an
    /// older pair never overwrites a newer one.
    #[test]
    fn an_older_tag_write_never_overwrites_a_newer_one_in_the_index() {
        let (hub, dir) = hub_with_peer("cloud-vm", vec![]);
        let tags = json!({"mux.handle": {"value": "a12"}, "mux.label": {"value": "Nightly train"}});
        let kid = published_kid(&hub, dir.path(), tags);
        let settle = race_at(&hub, "note.publish", retag(&hub, &kid, json!({"mux.handle": "a14"})));
        retag(&hub, &kid, json!({"mux.handle": "a13"}))();
        settle();
        // Whichever write went last, the index holds what the child carries now.
        let now = live_tag(&kid.meta.lock().unwrap(), HANDLE_TAG).unwrap();
        let pair = ("optchat-chief:h0me".to_owned(), now.clone());
        assert_eq!(hub.child_tags.local(&pair).len(), 1, "{now} is not where the index has it");
    }

    /// Review 101 of #24337: a lookup that found a child not yet published drops only the entry it
    /// saw, so the publication's own index entry (an import's, a fork's) stays.
    #[test]
    fn a_lookup_never_drops_a_child_published_after_it_looked() {
        let (hub, dir) = hub_with_peer("cloud-vm", vec![]);
        let tags = json!({"mux.handle": {"value": "a12"}, "mux.label": {"value": "Nightly train"}});
        // Made, as an import or a fork makes it, and not yet in the hub's sessions.
        let kid =
            hub.make_session(serde_json::from_value(kid_meta("kid", dir.path(), tags)).unwrap());
        let (h, k) = (hub.clone(), kid.clone());
        let publish = std::sync::Mutex::new(Some(move || {
            h.sessions.lock().unwrap().insert(k.id.clone(), k.clone());
            h.child_tags.note(&k);
        }));
        let hook: PauseHook = Arc::new(move |at, _| {
            if at == "gone.forget"
                && let Some(publish) = publish.lock().unwrap().take()
            {
                publish();
            }
        });
        *hub.child_tags.1.0.lock().unwrap() = Some(hook);
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12"), None, "not yet published");
        let label = hub.child_label("optchat-chief:h0me", "a12");
        assert_eq!(label.as_deref(), Some("Nightly train"), "the published child was dropped");
    }

    /// Review 35 of #24337: an export carries the display line acpmux works out now, never one
    /// an older build logged from the agent's words; the tool's own input stays whole.
    #[test]
    fn an_export_carries_no_logged_display_line() {
        let (hub, dir) = hub_with_peer("cloud-vm", vec![]);
        let kid = hub
            .make_session(serde_json::from_value(kid_meta("kid", dir.path(), json!({}))).unwrap());
        hub.store.save(&kid.meta()).unwrap();
        let request = json!({"toolCall": {"title": "x",
            "rawInput": {"document": {"_meta": {"acpmux": {"display": {"headline": "the tool's own input"}}}}},
            "_meta": {"acpmux": {"display": {"headline": "Leo wants to say hi"}}}}});
        let record = json!({"seq": 1, "at": 0, "dir": "mux", "kind": "permission_request",
                            "msg": {"request": request}});
        hub.store.append("kid", &serde_json::from_value(record).unwrap()).unwrap();
        let out = hub.export(&kid, &dir.path().join("out")).unwrap();
        let log = std::fs::read_to_string(out.join("events").join("000001.ndjson")).unwrap();
        assert!(!log.contains("Leo wants to say hi"), "{log}");
        assert!(log.contains("the tool's own input"), "{log}");
    }

    /// Review 35 of #24337: an import that fails leaves nothing in the child index.
    #[tokio::test]
    async fn a_failed_import_leaves_no_child_in_the_index() {
        let (hub, dir) = hub_with_peer("cloud-vm", vec![]);
        let fake = crate::config::HarnessProfile {
            kind: Default::default(),
            argv: vec!["true".into()],
            env: Default::default(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        };
        hub.config.write().await.harnesses.insert("fake".into(), fake);
        let bundle = dir.path().join("bundle");
        std::fs::create_dir_all(bundle.join("events")).unwrap();
        let tags = json!({"mux.handle": {"value": "a12"}, "mux.label": {"value": "Nightly train"}});
        let meta = kid_meta("kid", dir.path(), tags);
        std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
        std::fs::write(bundle.join("events").join("000001.ndjson"), "not a record\n").unwrap();
        assert!(hub.import(&bundle, None).await.is_err(), "an unreadable log fails the import");
        let index = hub.child_tags.index();
        assert!(index.local.is_empty() && index.pair_of.is_empty(), "{:?}", index.local);
    }

    /// #24337 review: a peer's rows are indexed by `(mux.parent, mux.handle)` as they are written,
    /// so naming a peer's child reads only the rows of that pair, and a row that moves or goes
    /// leaves nothing behind.
    #[test]
    fn the_peer_index_follows_its_rows() {
        let row = |id: &str, handle: &str| {
            json!({"sessionId": id, "name": id,
                   "tags": {"mux.parent": "optchat-chief:h0me", "mux.handle": handle, "mux.label": id}})
        };
        let (hub, _dir) = hub_with_peer("cloud-vm", vec![row("m1", "a12"), row("m2", "a13")]);
        let pair = |h: &str| ("optchat-chief:h0me".to_owned(), h.to_owned());
        let names = |h: &str| -> Vec<String> {
            let rows = hub.remote_sessions.lock().unwrap();
            rows.with_pair(&pair(h)).map(|r| r.receipt.mux_session_id.clone()).collect()
        };
        assert_eq!(names("a12"), ["m1"]);
        assert_eq!(names("a13"), ["m2"]);
        assert_eq!(hub.child_label("optchat-chief:h0me", "a12").as_deref(), Some("m1"));
        // A new list moves m1 to a14 and drops m2.
        let generation = hub.peer("cloud-vm").unwrap().generation;
        hub.apply_peer_notice("cloud-vm", generation, PeerNotice::Sessions(vec![row("m1", "a14")]));
        assert!(names("a12").is_empty() && names("a13").is_empty());
        assert_eq!(names("a14"), ["m1"]);
        // Marking the peer's rows stale goes through the index too.
        let changed = hub.remote_sessions.lock().unwrap().mark_peer_stale("cloud-vm", Some(7));
        assert_eq!(changed.len(), 1, "{changed:?}");
        assert_eq!(names("a14"), ["m1"]);
        assert_eq!(hub.remote_sessions.lock().unwrap().pairs(), 1);
        hub.purge_peer_rows("cloud-vm");
        assert!(names("a14").is_empty());
        assert_eq!(hub.remote_sessions.lock().unwrap().pairs(), 0);
    }
}
