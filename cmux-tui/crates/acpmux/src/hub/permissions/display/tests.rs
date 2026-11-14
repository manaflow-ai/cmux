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
    hub.apply_peer_notice(name, peer.generation, PeerNotice::sessions_from_values(sessions));
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
        PeerNotice::sessions_from_values(vec![row(
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
    let kid = hub.make_session(serde_json::from_value(kid_meta("kid", dir.path(), tags)).unwrap());
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
    let kid = hub.make_session(serde_json::from_value(kid_meta("kid", dir.path(), tags)).unwrap());
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
    let kid =
        hub.make_session(serde_json::from_value(kid_meta("kid", dir.path(), json!({}))).unwrap());
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
        let rows = hub.remote_sessions.read();
        rows.with_pair(&pair(h)).map(|r| r.receipt.mux_session_id.clone()).collect()
    };
    assert_eq!(names("a12"), ["m1"]);
    assert_eq!(names("a13"), ["m2"]);
    assert_eq!(hub.child_label("optchat-chief:h0me", "a12").as_deref(), Some("m1"));
    // A new list moves m1 to a14 and drops m2.
    let generation = hub.peer("cloud-vm").unwrap().generation;
    hub.apply_peer_notice(
        "cloud-vm",
        generation,
        PeerNotice::sessions_from_values(vec![row("m1", "a14")]),
    );
    assert!(names("a12").is_empty() && names("a13").is_empty());
    assert_eq!(names("a14"), ["m1"]);
    // Marking the peer's rows stale goes through the index too.
    let changed = hub.remote_sessions.write().mark_peer_stale("cloud-vm", Some(7));
    assert_eq!(changed.len(), 1, "{changed:?}");
    assert_eq!(names("a14"), ["m1"]);
    assert_eq!(hub.remote_sessions.read().pairs(), 1);
    hub.purge_peer_rows("cloud-vm");
    assert!(names("a14").is_empty());
    assert_eq!(hub.remote_sessions.read().pairs(), 0);
}
