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
    BookDaemon {
        daemon_id: id.into(),
        host: host.into(),
        user: user.into(),
        last_seen_at: 5,
        ..Default::default()
    }
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

fn reading() -> Value {
    json!({
        "ram": {"freeBytes": 34_000_000_000u64, "totalBytes": 68_000_000_000u64},
        "load": [1.5, 1.0, 0.5], "cpus": 16, "liveSessions": 2,
        "pressure": {"ok": true, "over": [], "cores": 16}, "build": "0.1.0",
    })
}

fn with_health(mut book: AddressBook, host: &str, health: Value, at: u64) -> AddressBook {
    for d in book.daemons.iter_mut().filter(|d| d.host == host) {
        d.health = Some(health.clone());
        d.health_at = Some(at);
    }
    book
}

fn peer(hub: &Hub, name: &str) -> Value {
    hub.peers().into_iter().find(|p| p["name"] == name).expect("a peer")
}

/// A hub machine's row carries the health the book returned for it, as a linked peer's row
/// does, so placement and `machine ls` read it; a field the hub should not have sent is dropped.
#[test]
fn a_hub_row_with_fresh_health_carries_it() {
    let hub = hub();
    let mut sent = reading();
    sent["path"] = json!("/home/someone");
    hub.apply_mesh_book(with_health(book(), "machine-b", sent, 1_000), "person-1", Some("d-a"));
    let b = peer(&hub, "machine-b");
    assert_eq!(b["health"], reading());
    let at = b["healthAt"].as_u64().expect("healthAt");
    assert!(crate::store::now_ms().saturating_sub(at) < 5_000, "this machine's clock: {at}");
    assert_eq!(b.get("healthStaleSecs"), None);
    assert!(crate::cli::peer_status::resources(&b).contains("ram 34.0 GB free"), "{b}");
    // A teammate's machine's reading is not kept.
    let mut teammate = with_health(book(), "teammate-box", reading(), 1_000);
    teammate.daemons.retain(|d| d.host != "machine-b");
    assert!(health_by_host(&teammate, "person-1", Some("d-a"), &|_| false).is_empty());
}

/// A reading the book has not renewed for longer than the bound reads as unread, and says how
/// old it is; a renewed one (a newer hub time) is fresh again.
#[test]
fn a_stale_hub_reading_is_not_carried_and_says_its_age() {
    let hub = hub();
    hub.apply_mesh_book(
        with_health(book(), "machine-b", reading(), 1_000),
        "person-1",
        Some("d-a"),
    );
    let aged = crate::store::now_ms() - crate::mesh_health::HUB_HEALTH_STALE_MS - 30_000;
    hub.mesh_book.lock().unwrap().health.get_mut("machine-b").unwrap().read_at = aged;
    // The same reading again (the same hub time) does not renew it.
    hub.apply_mesh_book(
        with_health(book(), "machine-b", reading(), 1_000),
        "person-1",
        Some("d-a"),
    );
    let b = peer(&hub, "machine-b");
    assert_eq!(b.get("health"), None, "{b}");
    assert_eq!(b["healthAt"], json!(aged));
    let secs = b["healthStaleSecs"].as_u64().expect("its age");
    assert!((120..125).contains(&secs), "{secs}");
    let line = crate::cli::peer_status::resources(&b);
    assert!(line.starts_with("resources unknown (the hub's last reading is 12"), "{line}");
    hub.apply_mesh_book(
        with_health(book(), "machine-b", reading(), 2_000),
        "person-1",
        Some("d-a"),
    );
    assert_eq!(peer(&hub, "machine-b")["health"], reading());
}

/// A hub that sends no health (one from before it) lists the machine as today: no health, no
/// age, and a reading kept from before is dropped with it; a stop drops every reading.
#[test]
fn a_book_with_no_health_reads_as_today() {
    let hub = hub();
    hub.apply_mesh_book(
        with_health(book(), "machine-b", reading(), 1_000),
        "person-1",
        Some("d-a"),
    );
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    let b = peer(&hub, "machine-b");
    for key in ["health", "healthAt", "healthStaleSecs"] {
        assert_eq!(b.get(key), None, "{key}: {b}");
    }
    assert_eq!(crate::cli::peer_status::resources(&b), "resources unknown");
    hub.apply_mesh_book(
        with_health(book(), "machine-b", reading(), 1_000),
        "person-1",
        Some("d-a"),
    );
    hub.set_mesh_book(Default::default(), Vec::new());
    assert!(hub.mesh_book.lock().unwrap().health.is_empty());
}
