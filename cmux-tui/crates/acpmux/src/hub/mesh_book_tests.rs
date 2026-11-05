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
            session("0198f2a4-0000-7000-8000-00000000000c", "theirs", "teammate-box", "d-t", "ready"),
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
    assert_eq!(hub.mesh_book_host(B_ID).as_deref(), Some("machine-b"));
    assert_eq!(hub.remote_matches("machine-b/fix-login"), 0);
}

/// The hub's row notices `events` holds now, as `(kind, row)`; other notices are skipped.
fn notices(events: &mut tokio::sync::broadcast::Receiver<HubEvent>) -> Vec<(String, Value)> {
    let mut out = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let Some(remote) = event.remote {
            out.push((event.record.kind.clone(), remote.summary));
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
    let first = notices(&mut events);
    assert_eq!(first.len(), 1, "{first:?}");
    assert_eq!(first[0].0, "status");
    let writes = hub.remote_sessions.lock().unwrap().writes;

    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    assert_eq!(notices(&mut events), [], "an unchanged book announces nothing");
    assert_eq!(hub.remote_sessions.lock().unwrap().writes, writes, "nor rebuilds the list");

    let mut waiting = book();
    waiting.sessions[1].state = "waiting".into();
    hub.apply_mesh_book(waiting, "person-1", Some("d-a"));
    let changed = notices(&mut events);
    assert_eq!(changed.len(), 1, "{changed:?}");
    assert_eq!(changed[0].1["status"], "waiting");

    hub.set_mesh_book(Default::default(), Vec::new());
    let gone = notices(&mut events);
    assert_eq!(gone.iter().map(|(kind, _)| kind.as_str()).collect::<Vec<_>>(), ["purged"]);
    assert!(hub.all_session_summaries().is_empty());
    assert!(hub.peers().is_empty());
}
