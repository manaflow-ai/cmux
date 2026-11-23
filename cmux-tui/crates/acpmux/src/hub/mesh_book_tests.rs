use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::BookDaemon;

fn hub() -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({})).expect("config");
    config.store.mode = StoreMode::Memory;
    let store =
        crate::store::open(&config.store, std::path::Path::new("/nonexistent")).expect("store");
    Hub::new(config, store)
}

fn daemon(id: &str, host: &str, user: &str) -> BookDaemon {
    BookDaemon { daemon_id: id.into(), host: host.into(), user: user.into(), last_seen_at: 5 }
}

fn session(id: &str, name: &str, host: &str, daemon: &str, state: &str) -> BookSession {
    BookSession {
        name: name.into(),
        session_id: id.into(),
        host: host.into(),
        daemon_id: daemon.into(),
        harness: "claude".into(),
        state: state.into(),
        last_seen_at: 5,
        ..Default::default()
    }
}

const B_ID: &str = "0198f2a4-0000-7000-8000-00000000000b";

fn book() -> AddressBook {
    AddressBook {
        daemons: vec![
            daemon("d-a", "machine-a", "person-1"),
            daemon("d-b", "machine-b", "person-1"),
            daemon("d-t", "teammate-box", "person-2"),
            daemon("d-s", "ssh-box", "person-1"),
        ],
        sessions: vec![
            session("0198f2a4-0000-7000-8000-00000000000a", "here", "machine-a", "d-a", "ready"),
            session(B_ID, "fix-login", "machine-b", "d-b", "running"),
            session(
                "0198f2a4-0000-7000-8000-00000000000c",
                "theirs",
                "teammate-box",
                "d-t",
                "ready",
            ),
            session("0198f2a4-0000-7000-8000-00000000000d", "linked", "ssh-box", "d-s", "ready"),
        ],
    }
}

/// Only the same person's other machines are listed: never this daemon, a teammate's machine,
/// or a host an ssh peer already lists.
#[test]
fn only_the_same_persons_other_hub_machines_are_listed() {
    let (hosts, sessions) = mine(book(), "person-1", Some("d-a"), &|host| host == "ssh-box");
    assert_eq!(hosts.keys().collect::<Vec<_>>(), ["machine-b"]);
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, B_ID);
    let (hosts, _) = mine(book(), "", Some("d-a"), &|_| false);
    assert!(hosts.is_empty(), "no person known lists nothing");
}

/// A hub machine's chat is in the list, `resolve` and `peers` as an ssh peer's is, marked
/// `via: "hub"`; it stays out of the ssh rows, so a read of it is still the hub's to route.
#[tokio::test]
async fn a_hub_machines_chat_is_listed_resolved_and_its_machine_is_a_peer() {
    let hub = hub();
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));

    let all = hub.all_session_summaries();
    let row = all.iter().find(|s| s["sessionId"] == B_ID).expect("listed");
    assert_eq!(row["name"], "machine-b/fix-login");
    assert_eq!(row["peer"], "machine-b");
    assert_eq!(row["via"], "hub");
    assert_eq!(row["qualifiedSessionId"], format!("machine-b/{B_ID}"));
    assert!(all.iter().all(|s| s["name"] != "teammate-box/theirs"), "{all:?}");

    let found = hub.locate("machine-b/fix-login", false, true).expect("resolved");
    assert!(found.to_string().contains(B_ID), "{found}");

    let peers = hub.peers();
    let b = peers.iter().find(|p| p["name"] == "machine-b").expect("a peer");
    assert_eq!((b["via"].clone(), b["sessions"].clone()), (json!("hub"), json!(1)));

    assert!(hub.mesh_may_route(&format!("machine-b/{B_ID}")), "still the hub's to route");
    // `acpmux wait` names it by id, `HOST/ID` or `HOST/name`.
    for key in [B_ID.to_owned(), format!("machine-b/{B_ID}"), "machine-b/fix-login".into()] {
        assert_eq!(hub.mesh_book_resolve(&key).as_deref(), Some(B_ID), "{key}");
    }
    assert_eq!(hub.mesh_book_resolve("machine-b/nobody"), None);
    assert_eq!(hub.mesh_book_host(B_ID).as_deref(), Some("machine-b"));
    assert_eq!(hub.remote_matches("machine-b/fix-login"), 0);
}

/// The hub's row notices `events` holds now, as `(kind, row)`; other notices are skipped.
fn notices(events: &mut tokio::sync::broadcast::Receiver<HubEvent>) -> Vec<(String, Value)> {
    let mut out = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Some(remote) = event.remote {
            out.push((event.record.kind.clone(), remote.summary.value()));
        }
    }
    out
}

/// A heartbeat that changes nothing tells no client anything; a state change and a machine
/// leaving do, and stopping the relay empties the list.
#[tokio::test]
async fn only_a_change_is_announced_and_a_stop_empties_the_list() {
    let hub = hub();
    let mut events = hub.events.subscribe();
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    // No ssh peer here, so ssh-box is listed through the hub too.
    let first = notices(&mut events);
    assert_eq!(first.len(), 2, "{first:?}");
    assert!(first.iter().all(|(kind, _)| kind == "status"), "{first:?}");
    let writes = hub.remote_sessions.read().writes;

    let mut later = book();
    for d in &mut later.daemons {
        d.last_seen_at += 30_000;
    }
    hub.apply_mesh_book(later, "person-1", Some("d-a"));
    assert_eq!(notices(&mut events), [], "an unchanged book announces nothing");
    assert_eq!(hub.remote_sessions.read().writes, writes, "nor rebuilds the list");

    let mut waiting = book();
    waiting.sessions[1].state = "waiting".into();
    hub.apply_mesh_book(waiting, "person-1", Some("d-a"));
    let changed = notices(&mut events);
    assert_eq!(changed.len(), 1, "{changed:?}");
    assert_eq!(changed[0].1["status"], "waiting");
    let pending = hub.pending_session_summaries();
    assert_eq!(pending.len(), 1, "a waiting hub chat is listed with the asks: {pending:?}");

    hub.set_mesh_book(Default::default(), Vec::new());
    let gone = notices(&mut events);
    assert_eq!(
        gone.iter().map(|(kind, _)| kind.as_str()).collect::<Vec<_>>(),
        ["purged", "purged"]
    );
    assert!(hub.all_session_summaries().is_empty());
    assert!(hub.peers().is_empty());
}

/// Every session row lists the same keys whichever machine it came from: a hub row lists each of
/// `ROW_KEYS` as a local row does, null when the hub does not say, and the hub's values when it
/// does. No reader can drop or misfile another machine's chat for a key it lacks.
#[tokio::test]
async fn a_hub_row_lists_every_key_a_local_row_does() {
    let hub = hub();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "local-contract", "name": "here",
        "harness": "fake", "cwd": "/work/app", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .expect("meta");
    hub.store.save(&meta).expect("save");
    let local = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(local.id.clone(), local.clone());
    hub.update_live_session_index(&local);

    let mut full = book();
    let b = &mut full.sessions[1];
    b.cwd = Some("/work/login".into());
    b.title = Some("Fix the login".into());
    b.title_source = Some("agent".into());
    b.name_given = Some(true);
    b.model = Some("opus".into());
    b.agent_session_id = Some("agent-b".into());
    b.host_build = Some("build-b".into());
    hub.apply_mesh_book(full, "person-1", Some("d-a"));

    let all = hub.all_session_summaries();
    let local_row = all.iter().find(|s| s["sessionId"] == "local-contract").expect("local");
    let bare = all.iter().find(|s| s["name"] == "ssh-box/linked").expect("a bare hub row");
    let rich = all.iter().find(|s| s["sessionId"] == B_ID).expect("a full hub row");
    for key in ROW_KEYS {
        assert!(local_row.get(key).is_some(), "a local row lists {key}: {local_row}");
        assert!(bare.get(key).is_some(), "a hub row lists {key} with nothing known: {bare}");
        assert!(rich.get(key).is_some(), "a hub row lists {key}: {rich}");
    }
    assert_eq!(bare["cwd"], Value::Null);
    assert_eq!(bare["harness"], "claude");
    assert_eq!(rich["cwd"], "/work/login");
    assert_eq!(rich["title"], "Fix the login");
    assert_eq!(rich["titleSource"], "agent");
    assert_eq!(rich["nameGiven"], true);
    assert_eq!(rich["model"], "opus");
    assert_eq!(rich["agentSessionId"], "agent-b");
    assert_eq!(rich["sessionReceipt"]["agentSessionId"], "agent-b");
    assert_eq!(rich["hostBuild"], "build-b");
}

/// A hub row's folder or title changing builds it again and tells clients; the same book again
/// does not.
#[tokio::test]
async fn a_hub_rows_metadata_change_is_announced() {
    let hub = hub();
    let mut events = hub.events.subscribe();
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    let _ = notices(&mut events);
    let mut moved = book();
    moved.sessions[1].cwd = Some("/work/other".into());
    hub.apply_mesh_book(moved.clone(), "person-1", Some("d-a"));
    let changed = notices(&mut events);
    assert_eq!(changed.len(), 1, "{changed:?}");
    assert_eq!(changed[0].1["cwd"], "/work/other");
    hub.apply_mesh_book(moved, "person-1", Some("d-a"));
    assert_eq!(notices(&mut events), [], "an unchanged book announces nothing");
}

/// A heartbeat lists a session's folder, and leaves out one the hub would refuse for length
/// rather than lose the whole heartbeat.
#[test]
fn a_heartbeat_lists_the_folder_the_hub_takes() {
    use crate::mesh::{MAX_CWD_UNITS, heartbeat_cwd};
    assert_eq!(heartbeat_cwd("/work/app").as_deref(), Some("/work/app"));
    assert_eq!(heartbeat_cwd(""), None);
    let longest = format!("/{}", "a".repeat(MAX_CWD_UNITS - 1));
    assert_eq!(heartbeat_cwd(&longest).as_deref(), Some(longest.as_str()));
    assert_eq!(heartbeat_cwd(&format!("{longest}b")), None);
}
