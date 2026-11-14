//! The v2 list holds the rows of the same person's other machines that the mesh hub lists
//! (`mesh_book.rs`), as v1's list does (decision 210).
use super::*;
use crate::hub::session_pages::PageRow as _;
use crate::mesh::BookSession;
use acpmux_book::index::SummaryIndex;
use std::collections::BTreeMap;

const SSH: &str = "ssh-box";

fn v1_hub() -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    config.peers.insert(
        SSH.into(),
        crate::config::PeerConfig {
            link_host: None,
            wireguard: None,
            url: "ws://127.0.0.1:9/ssh-box".into(),
            token: None,
            peer_token: None,
            vm_boundary: false,
            github_broker: false,
        },
    );
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::build(config, store, crate::mailbox::Mailbox::memory(), false, false, None, false)
}

/// A v1 hub with its tee's queue installed, remote rows ready to be removed.
fn tee_on(v1: &Hub) -> Arc<TeeState> {
    let state = Arc::new(TeeState::default());
    v1.install_v2_tee(Arc::new(TeeHandle { state: state.clone() }));
    state.remote_ready();
    state
}

fn own(id: &str) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "fake", "cwd": "/tmp", "status": "closed",
        "createdAt": 1, "updatedAt": crate::store::now_ms()
    }))
    .unwrap()
}

fn session(host: &str, id: &str, state: &str) -> BookSession {
    BookSession {
        name: format!("chat-{id}"),
        session_id: id.into(),
        host: host.into(),
        daemon_id: format!("d-{host}"),
        harness: "claude".into(),
        state: state.into(),
        last_seen_at: 5,
    }
}

/// The book read after a heartbeat: `machines` and their sessions.
fn read_book(v1: &Hub, machines: &[(&str, &[(&str, &str)])]) {
    let mut hosts = BTreeMap::new();
    let mut sessions = Vec::new();
    for (host, rows) in machines {
        hosts.insert((*host).to_owned(), 5);
        sessions.extend(rows.iter().map(|(id, state)| session(host, id, state)));
    }
    v1.set_mesh_book(hosts, sessions);
}

/// An ssh peer's row, announced as a peer's listing announces it.
fn ssh_row(v1: &Hub, peer: &str, id: &str) {
    let summary = Hub::remote_summary(
        peer,
        json!({"sessionId": id, "name": id, "status": "idle", "harness": "codex", "updatedAt": 9}),
    );
    let receipt = crate::session_identity::SessionReceipt::new(peer, id, None, 1);
    v1.remote_sessions.write().insert(
        format!("{peer}/{id}"),
        RemoteSession { peer: peer.into(), summary: summary.clone().into(), receipt },
    );
    v1.announce_remote(peer, summary, "status");
}

fn add_ssh_peer(v1: &Hub, name: &str) {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9/peer", None, None, tx);
    v1.peers.lock().unwrap().insert(name.into(), peer);
    v1.events.origin_tee(name, OriginState::Connected, crate::store::now_ms());
}

/// What `Hub::remove_peer` does to the list and the tee, without the config save.
fn remove_ssh_peer(v1: &Hub, name: &str) {
    let peer = v1.peers.lock().unwrap().remove(name).unwrap();
    let gone = v1.remote_sessions.write().take_peer(name);
    v1.note_peer_removed(&peer);
    for (_, row) in gone {
        v1.announce_remote(name, row.summary.value(), "purged");
    }
}

/// One turn of the tee over `index`: every mark drained, the writer run to its end (origin
/// removals included). `reconcile` runs the start's walks first.
async fn turn(v1: &Hub, index: SummaryIndex, state: &TeeState, reconcile: bool) -> SummaryIndex {
    let (hub, writer) = acpmux_core::hub::Hub::new(index);
    let v2 = V2::new(hub, writer);
    let mut expiries = Expiries::default();
    if reconcile {
        let _ = super::reconcile(v1, &v2, state).await;
        reconcile_remote(v1, &v2, state).await;
    }
    while state.has_pending() {
        drain_marks(v1, &v2, state, &mut expiries);
    }
    v2.hub.close();
    v2.take_writer().unwrap().run().await.unwrap();
    (*v2.hub.snapshot()).clone()
}

/// The keys of a v2 walk of every row, closed ones too.
fn v2_keys(index: &SummaryIndex) -> Vec<(String, String)> {
    let mut keys = Vec::new();
    let mut anchor: Option<SortKey> = None;
    loop {
        let page = index.read_page(anchor.as_ref(), ReadSide::After, false, 256, 256 * 1024, None);
        let page = page.unwrap();
        keys.extend(page.rows.iter().map(|row| (row.origin.clone(), row.chat_id.clone())));
        match page.after_key {
            Some(next) if page.has_after => anchor = Some(next),
            _ => break,
        }
    }
    keys.sort();
    keys
}

fn v1_keys(v1: &Hub) -> Vec<(String, String)> {
    let list = v1.list_rows(false, false);
    let mut keys: Vec<_> = list
        .rows()
        .iter()
        .map(|row| (row.peer().unwrap_or("local").to_owned(), row.session_id().to_owned()))
        .collect();
    keys.sort();
    keys
}

fn origin(index: &SummaryIndex, id: &str) -> Option<OriginState> {
    index.origin(id).map(|origin| origin.state)
}

fn reset(state: &TeeState) {
    state.remote_submits.store(0, Ordering::Relaxed);
    state.origin_writes.store(0, Ordering::Relaxed);
}

fn counts(state: &TeeState) -> (u64, u64) {
    (state.remote_submits.load(Ordering::Relaxed), state.origin_writes.load(Ordering::Relaxed))
}

/// The differential: own rows, an ssh peer's rows and hub rows. A v2 walk holds v1's keys, and
/// each hub row's summary holds what the v1 row says for the fields a summary keeps.
#[tokio::test]
async fn a_v2_walk_holds_the_keys_of_v1s_list_with_hub_rows() {
    let v1 = v1_hub();
    let state = tee_on(&v1);
    v1.insert_test_session(own("own-1"));
    v1.insert_test_session(own("own-2"));
    ssh_row(&v1, SSH, "ssh-1");
    read_book(
        &v1,
        &[
            ("machine-b", &[("b-1", "running"), ("b-2", "waiting")]),
            ("machine-c", &[("c-1", "ready")]),
        ],
    );
    let index = turn(&v1, SummaryIndex::new(), &state, true).await;

    let keys = v2_keys(&index);
    assert_eq!(keys, v1_keys(&v1));
    assert_eq!(keys.len(), 6, "{keys:?}");
    assert_eq!(origin(&index, "machine-b"), Some(OriginState::Connected));
    assert_eq!(origin(&index, "machine-c"), Some(OriginState::Connected));

    let list = v1.list_rows(false, false);
    for row in
        list.rows().iter().filter(|row| row.peer().is_some_and(|p| p.starts_with("machine-")))
    {
        let value = list.value(&v1, row, false);
        assert_eq!(value["via"], "hub");
        let summary = index.get_row(&RowKey::new(row.peer().unwrap(), row.session_id())).unwrap();
        assert_eq!(summary.title, value["name"].as_str().unwrap());
        assert_eq!(summary.harness, value["harness"].as_str().unwrap());
        assert_eq!(summary.state, value["status"].as_str().unwrap());
        assert_eq!(summary.last_activity, value["updatedAt"].as_u64().unwrap());
        assert_eq!(u64::from(summary.unread), value["unreadTurns"].as_u64().unwrap_or(0));
        assert_eq!(summary.workspace, None);
        assert_eq!(summary.folder, None);
        assert!(!summary.pinned);
        let extra: Value = serde_json::from_str(summary.extra.get()).unwrap();
        assert!(extra.get("via").is_none(), "via is not in the index: {extra}");
    }
}

#[tokio::test]
async fn a_changed_hub_row_is_one_submit_and_an_unchanged_heartbeat_none() {
    let v1 = v1_hub();
    let state = tee_on(&v1);
    read_book(&v1, &[("machine-b", &[("b-1", "running"), ("b-2", "ready")])]);
    let index = turn(&v1, SummaryIndex::new(), &state, true).await;
    reset(&state);

    read_book(&v1, &[("machine-b", &[("b-1", "waiting"), ("b-2", "ready")])]);
    let index = turn(&v1, index, &state, false).await;
    assert_eq!(counts(&state), (1, 0), "one changed row is one submit and no origin write");
    assert_eq!(index.get_row(&RowKey::new("machine-b", "b-1")).unwrap().state, "waiting");
    assert_eq!(v2_keys(&index), v1_keys(&v1));
    reset(&state);

    let marks = state.marks.load(Ordering::Relaxed);
    let seq = index.seq();
    read_book(&v1, &[("machine-b", &[("b-1", "waiting"), ("b-2", "ready")])]);
    assert!(!state.has_pending(), "a heartbeat that changes nothing marks nothing");
    let index = turn(&v1, index, &state, false).await;
    assert_eq!(counts(&state), (0, 0));
    assert_eq!(state.marks.load(Ordering::Relaxed), marks);
    assert_eq!(index.seq(), seq);
}

#[tokio::test]
async fn a_machine_that_leaves_the_book_takes_its_rows_and_origin() {
    let v1 = v1_hub();
    let state = tee_on(&v1);
    read_book(&v1, &[("machine-b", &[("b-1", "running")]), ("machine-c", &[("c-1", "ready")])]);
    let index = turn(&v1, SummaryIndex::new(), &state, true).await;
    reset(&state);

    read_book(&v1, &[("machine-c", &[("c-1", "ready")])]);
    // The same call that announces its rows gone states its origin removed.
    assert!(state.origins.lock().unwrap().contains_key("machine-b"));
    let index = turn(&v1, index, &state, false).await;
    assert_eq!(origin(&index, "machine-b"), Some(OriginState::Removed));
    assert_eq!(origin(&index, "machine-c"), Some(OriginState::Connected));
    assert_eq!(v2_keys(&index), [("machine-c".to_owned(), "c-1".to_owned())]);
    assert_eq!(v2_keys(&index), v1_keys(&v1));
}

#[tokio::test]
async fn a_stopped_relay_empties_the_hub_rows() {
    let v1 = v1_hub();
    let state = tee_on(&v1);
    v1.insert_test_session(own("own-1"));
    read_book(&v1, &[("machine-b", &[("b-1", "running")]), ("machine-c", &[("c-1", "ready")])]);
    let index = turn(&v1, SummaryIndex::new(), &state, true).await;

    v1.set_mesh_book(BTreeMap::new(), Vec::new());
    let index = turn(&v1, index, &state, false).await;
    assert_eq!(origin(&index, "machine-b"), Some(OriginState::Removed));
    assert_eq!(origin(&index, "machine-c"), Some(OriginState::Removed));
    assert_eq!(v2_keys(&index), [("local".to_owned(), "own-1".to_owned())]);
    assert_eq!(v2_keys(&index), v1_keys(&v1));
}

/// A machine the hub listed is added as an ssh peer: the book skips it from then on. Its one
/// origin stays, its book rows leave and the peer's arrive, none twice and none lost.
#[tokio::test]
async fn a_hub_machine_that_turns_ssh_peer_keeps_one_origin() {
    let v1 = v1_hub();
    let state = tee_on(&v1);
    read_book(&v1, &[("machine-b", &[("b-1", "running"), ("b-2", "ready")])]);
    let index = turn(&v1, SummaryIndex::new(), &state, true).await;

    add_ssh_peer(&v1, "machine-b");
    ssh_row(&v1, "machine-b", "b-1");
    ssh_row(&v1, "machine-b", "b-3");
    read_book(&v1, &[]);
    let index = turn(&v1, index, &state, false).await;
    assert_eq!(origin(&index, "machine-b"), Some(OriginState::Connected));
    let keys = v2_keys(&index);
    assert_eq!(keys, v1_keys(&v1));
    assert_eq!(
        keys,
        [("machine-b".to_owned(), "b-1".to_owned()), ("machine-b".to_owned(), "b-3".to_owned())]
    );
    assert_eq!(index.get_row(&RowKey::new("machine-b", "b-1")).unwrap().harness, "codex");
    assert_eq!(index.origins().filter(|o| o.id == "machine-b").count(), 1);
}

/// An ssh peer is removed and the hub lists its machine next: one origin, the cut kept, the
/// book's rows in and the peer's gone.
#[tokio::test]
async fn an_ssh_peer_that_turns_hub_machine_keeps_one_origin() {
    let v1 = v1_hub();
    let state = tee_on(&v1);
    add_ssh_peer(&v1, "machine-b");
    ssh_row(&v1, "machine-b", "b-1");
    ssh_row(&v1, "machine-b", "b-3");
    let index = turn(&v1, SummaryIndex::new(), &state, false).await;
    assert_eq!(v2_keys(&index).len(), 2);

    remove_ssh_peer(&v1, "machine-b");
    read_book(&v1, &[("machine-b", &[("b-1", "running"), ("b-2", "ready")])]);
    let index = turn(&v1, index, &state, false).await;
    assert_eq!(origin(&index, "machine-b"), Some(OriginState::Connected));
    let keys = v2_keys(&index);
    assert_eq!(keys, v1_keys(&v1));
    assert_eq!(
        keys,
        [("machine-b".to_owned(), "b-1".to_owned()), ("machine-b".to_owned(), "b-2".to_owned())]
    );
    assert_eq!(index.get_row(&RowKey::new("machine-b", "b-1")).unwrap().harness, "claude");
}

/// A restart: the index from disk holds the last run's hub rows; the new run has read no book.
/// None is listed until the first read, as v1 lists none.
#[tokio::test]
async fn a_restart_lists_no_hub_row_until_the_first_book_read() {
    let mut row = Summary::new("b-1");
    row.origin = "machine-b".into();
    let record = acpmux_book::index::OriginRecord {
        seq: 2,
        id: "machine-b".into(),
        state: OriginState::Connected,
        since: 1,
        extra: None,
    };
    let last_run = SummaryIndex::new().apply(1, row).apply_origin(2, record);
    let v1 = v1_hub();
    let state = tee_on(&v1);
    let index = turn(&v1, last_run, &state, true).await;
    assert!(v2_keys(&index).is_empty(), "{:?}", v2_keys(&index));
    assert_eq!(origin(&index, "machine-b"), Some(OriginState::Removed));
    assert_eq!(v2_keys(&index), v1_keys(&v1));

    read_book(&v1, &[("machine-b", &[("b-1", "running")])]);
    let index = turn(&v1, index, &state, false).await;
    assert_eq!(origin(&index, "machine-b"), Some(OriginState::Connected));
    assert_eq!(v2_keys(&index), [("machine-b".to_owned(), "b-1".to_owned())]);
    assert_eq!(v2_keys(&index), v1_keys(&v1));
}

/// A keyed page of the v2 list reads a hub row through v1 (`V1PageProvider`).
#[tokio::test]
async fn the_page_provider_reads_a_hub_row() {
    use acpmux_core::hub::PageProvider as _;
    let v1 = v1_hub();
    read_book(&v1, &[("machine-b", &[("b-1", "running")])]);
    let provider = V1PageProvider::new(v1.clone());
    let row = provider.row(&RowKey::new("machine-b", "b-1")).unwrap().unwrap();
    assert_eq!(row.state, "running");
    assert!(provider.row(&RowKey::new("machine-b", "b-9")).unwrap().is_none());
}

/// The `initialize` features of a local connection to `v1`.
async fn local_features(v1: &Arc<Hub>) -> Vec<Value> {
    let (input, incoming) = tokio::sync::mpsc::channel(8);
    let (output, mut outgoing) = tokio::sync::mpsc::channel(8);
    let task = tokio::spawn(crate::server::serve_connection(v1.clone(), incoming, output));
    let hello = crate::rpc::Message::request(1, "initialize", json!({"protocolVersion": 1}));
    input.send(hello.to_line()).await.unwrap();
    // timeout: Test-only deadline detects a missing reply; no user request is cancelled.
    let line = tokio::time::timeout(std::time::Duration::from_secs(10), outgoing.recv())
        .await
        .unwrap()
        .unwrap();
    drop(input);
    task.abort();
    let reply: Value = serde_json::from_str(&line).unwrap();
    reply["result"]["_meta"]["acpmux"]["features"].as_array().unwrap().clone()
}

/// `listHubRows` is a fact of the daemon's index: a local connection's `initialize` names it
/// when v2 serves `list`, and not with v2 off or `list` not allowed (decision 212).
#[tokio::test]
async fn initialize_names_list_hub_rows_only_with_the_v2_list() {
    let named = |features: &[Value]| features.iter().any(|f| f == HUB_ROWS_FEATURE);
    let off = v1_hub();
    assert!(!named(&local_features(&off).await), "v2 off");

    for (surfaces, expected) in [(&["list"][..], true), (&["chat"][..], false)] {
        let v1 = v1_hub();
        let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
        let surfaces = surfaces.iter().map(|s| (*s).to_owned()).collect();
        let v2 = Arc::new(V2::with_surfaces(hub, writer, surfaces));
        let (tee, _task) = start_v2_tee(v1.clone(), v2);
        v1.install_v2_tee(tee);
        let features = local_features(&v1).await;
        assert_eq!(named(&features), expected, "{features:?}");
        assert!(!features.iter().any(|f| f == "listStream"), "5h names no listStream");
    }
}
