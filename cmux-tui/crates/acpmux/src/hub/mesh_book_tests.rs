use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{BookDaemon, Heartbeat, SessionRow};

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
        stuck_reason: None,
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
    hub.apply_mesh_book(waiting.clone(), "person-1", Some("d-a"));
    let changed = notices(&mut events);
    assert_eq!(changed.len(), 1, "{changed:?}");
    assert_eq!(changed[0].1["status"], "waiting");
    let pending = hub.pending_session_summaries();
    assert_eq!(pending.len(), 1, "a waiting hub chat is listed with the asks: {pending:?}");

    // A sandbox refusal is part of the row's identity: it emits once, then an unchanged
    // heartbeat stays quiet, and recovery emits a row that has cleared the reason.
    waiting.sessions[1].state = "failed".into();
    waiting.sessions[1].stuck_reason = Some("cannot create .git/index.lock".into());
    hub.apply_mesh_book(waiting.clone(), "person-1", Some("d-a"));
    let failed = notices(&mut events);
    assert_eq!(failed.len(), 1, "{failed:?}");
    assert_eq!(failed[0].1["status"], "idle");
    assert_eq!(failed[0].1["lastTurn"]["status"], "failed");
    assert_eq!(failed[0].1["stuckReason"], "cannot create .git/index.lock");
    hub.apply_mesh_book(waiting.clone(), "person-1", Some("d-a"));
    assert_eq!(notices(&mut events), [], "an unchanged failure heartbeat announces nothing");

    waiting.sessions[1].state = "waiting".into();
    waiting.sessions[1].stuck_reason = None;
    hub.apply_mesh_book(waiting, "person-1", Some("d-a"));
    let recovered = notices(&mut events);
    assert_eq!(recovered.len(), 1, "{recovered:?}");
    assert_eq!(recovered[0].1["status"], "waiting");
    assert!(recovered[0].1.get("stuckReason").is_none(), "{recovered:?}");

    hub.set_mesh_book(Default::default(), Vec::new());
    let gone = notices(&mut events);
    assert_eq!(
        gone.iter().map(|(kind, _)| kind.as_str()).collect::<Vec<_>>(),
        ["purged", "purged"]
    );
    assert!(hub.all_session_summaries().is_empty());
    assert!(hub.peers().is_empty());
}

#[test]
fn a_failed_heartbeat_without_a_reason_still_projects_failure() {
    let row = row_of(
        "s-1",
        &Fields {
            name: "child",
            harness: "claude",
            state: "failed",
            stuck_reason: None,
            cwd: None,
            title: None,
            title_source: None,
            name_given: None,
            model: None,
            agent_session_id: None,
            host_build: None,
            handle: None,
            tags: None,
            updated_at: None,
        },
    );
    assert_eq!(row["status"], "idle");
    assert_eq!(row["lastTurn"]["status"], "failed");
}

#[test]
fn heartbeat_roundtrip_preserves_an_optional_stuck_reason() {
    let heartbeat = Heartbeat {
        host: "machine-b".into(),
        sessions: vec![SessionRow {
            name: "blocked".into(),
            session_id: "s-1".into(),
            harness: "claude".into(),
            state: "failed".into(),
            stuck_reason: Some("cannot write .git".into()),
            team_address: None,
            cwd: None,
            title: None,
            title_source: None,
            name_given: None,
            model: None,
            agent_session_id: None,
            host_build: None,
            handle: None,
            former_names: Vec::new(),
            roles: Vec::new(),
            tags: None,
            updated_at: None,
        }],
        leaving: false,
        health: None,
    };
    let wire = serde_json::to_value(&heartbeat).expect("heartbeat JSON");
    assert_eq!(wire["sessions"][0]["stuckReason"], "cannot write .git");
    let decoded: Heartbeat = serde_json::from_value(wire).expect("heartbeat decode");
    assert_eq!(decoded, heartbeat);

    let mut without_reason_heartbeat = heartbeat.clone();
    without_reason_heartbeat.sessions[0].stuck_reason = None;
    let without_reason =
        serde_json::to_value(without_reason_heartbeat).expect("heartbeat without reason JSON");
    assert!(without_reason["sessions"][0].get("stuckReason").is_none());
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
    b.tags = Some([("succeeds".to_owned(), "gcp-agent-lane-5/old".to_owned())].into());
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
    assert_eq!(rich["tags"], json!({"succeeds": "gcp-agent-lane-5/old"}));
    assert_eq!(bare["tags"], Value::Null);
}

/// A hub row's tags changing builds it again and tells clients: a `succeeds=` tag set on another
/// machine reaches this one's list (Leo, 2026-11-21: "We cannot ever afford to let these things
/// get away from us.").
#[tokio::test]
async fn a_hub_rows_tags_change_is_announced() {
    let hub = hub();
    let mut events = hub.events.subscribe();
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    let _ = notices(&mut events);
    let mut tagged = book();
    tagged.sessions[1].tags = Some([("goal".to_owned(), "ci-linux".to_owned())].into());
    hub.apply_mesh_book(tagged.clone(), "person-1", Some("d-a"));
    assert_eq!(notices(&mut events).len(), 1);
    let row =
        hub.all_session_summaries().into_iter().find(|s| s["sessionId"] == B_ID).expect("row");
    assert_eq!(row["tags"], json!({"goal": "ci-linux"}));
    hub.apply_mesh_book(tagged, "person-1", Some("d-a"));
    assert!(notices(&mut events).is_empty(), "the same tags again announce nothing");
}

/// The tags a heartbeat lists: strings only, keys and values bounded, at most `MAX_TAGS`, and the
/// whole set under the hub's byte cap; none when nothing is left.
#[test]
fn heartbeat_tags_are_bounded() {
    use crate::mesh::{MAX_TAG_VALUE, MAX_TAGS, MAX_TAGS_BYTES, heartbeat_tags};
    assert_eq!(heartbeat_tags(&json!({})), None);
    assert_eq!(heartbeat_tags(&Value::Null), None);
    let kept = heartbeat_tags(&json!({
        "succeeds": "a/b", "n": 1, "": "x", "long": "v".repeat(MAX_TAG_VALUE + 1),
    }))
    .expect("one kept");
    assert_eq!(kept, [("succeeds".to_owned(), "a/b".to_owned())].into());
    let many: serde_json::Map<String, Value> =
        (0..MAX_TAGS + 8).map(|i| (format!("k{i:03}"), json!("v"))).collect();
    assert_eq!(heartbeat_tags(&Value::Object(many)).expect("many").len(), MAX_TAGS);
    let big: serde_json::Map<String, Value> =
        (0..MAX_TAGS).map(|i| (format!("k{i:03}"), json!("v".repeat(MAX_TAG_VALUE)))).collect();
    let cut = heartbeat_tags(&Value::Object(big)).expect("cut");
    assert!(serde_json::to_vec(&cut).unwrap().len() <= MAX_TAGS_BYTES);
    assert!(cut.len() < MAX_TAGS && cut.contains_key("k000"));
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

/// A heartbeat lists a session's title, its source, whether its name was given, its model and
/// its agent's session id, so the hub can hand another machine the row a local one lists; a
/// title past the hub's bound is left out, and its source with it.
#[tokio::test]
async fn a_heartbeat_carries_the_rows_metadata_and_leaves_out_a_long_title() {
    let hub = hub();
    let add = |id: &str, name: &str, title: &str| {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": name, "nameGiven": true,
            "harness": "fake", "cwd": "/work/app", "status": "idle", "createdAt": 1,
            "updatedAt": 1, "title": title, "titleSource": "generated",
            "agentSessionId": format!("agent-{id}"), "modelRequest": "opus",
        }))
        .expect("meta");
        hub.store.save(&meta).expect("save");
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
        hub.update_live_session_index(&session);
    };
    add("short", "fix-login", "Fix the login");
    add("long", "long-title", &"t".repeat(crate::mesh::MAX_META_UNITS + 1));

    let rows = hub.mesh_rows().await;
    let short = rows.iter().find(|r| r.session_id == "short").expect("listed");
    assert_eq!(short.title.as_deref(), Some("Fix the login"));
    assert_eq!(short.title_source.as_deref(), Some("generated"));
    assert_eq!(short.name_given, Some(true));
    assert_eq!(short.model.as_deref(), Some("opus"));
    assert_eq!(short.agent_session_id.as_deref(), Some("agent-short"));
    assert_eq!(short.cwd.as_deref(), Some("/work/app"));
    let wire = serde_json::to_value(short).expect("json");
    assert_eq!(wire["titleSource"], "generated");
    assert_eq!(wire["agentSessionId"], "agent-short");
    assert!(wire.get("hostBuild").is_none(), "no live host lists no build: {wire}");

    let long = rows.iter().find(|r| r.session_id == "long").expect("still listed");
    assert_eq!(long.title, None, "a title the hub would null is left out");
    assert_eq!(long.title_source, None);
    assert_eq!(long.name_given, Some(true));
}

/// A text the hub would store as null is left out of the heartbeat.
#[test]
fn heartbeat_meta_leaves_out_what_the_hub_would_null() {
    use crate::mesh::{MAX_META_UNITS, heartbeat_meta};
    assert_eq!(heartbeat_meta("opus").as_deref(), Some("opus"));
    assert_eq!(heartbeat_meta(""), None);
    assert!(heartbeat_meta(&"é".repeat(MAX_META_UNITS)).is_some());
    assert_eq!(heartbeat_meta(&"😀".repeat(MAX_META_UNITS / 2 + 1)), None, "UTF-16 units");
}

/// An ssh peer's machine keeps its hub carrier route: `remote.pipe` (`tools/carrier-pipe`) names
/// it when its ssh is what is down. Only its chats and the app's workspace targets leave it out,
/// so it is never listed twice (2026-11-22: every fleet lane VM the controller held as an ssh peer
/// was `machine.unknown` on the carrier).
#[cfg(feature = "hub-carrier")]
#[tokio::test]
async fn an_ssh_peers_machine_keeps_its_carrier_route_but_is_listed_once() {
    let hub = hub();
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("ssh-box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("ssh-box".to_owned(), peer);
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));

    let machines = hub.mesh_book_machines();
    assert!(machines.contains(&("d-s".to_owned(), "ssh-box".to_owned())), "{machines:?}");
    assert!(machines.contains(&("d-b".to_owned(), "machine-b".to_owned())), "{machines:?}");
    assert!(machines.iter().all(|(key, _)| key != "d-t" && key != "d-a"), "{machines:?}");
    assert_eq!(crate::cmux_tui_service::book_machine(&machines, "ssh-box").as_deref(), Some("d-s"));

    let routes = hub.mesh_book_route_machines();
    assert_eq!(routes, [("d-b".to_owned(), "machine-b".to_owned())]);
    let all = hub.all_session_summaries();
    assert!(all.iter().all(|s| s["name"] != "ssh-box/linked"), "{all:?}");
}

/// A chat's given handle (`acpmux rename ... --handle`) reaches another machine through the hub:
/// its heartbeat lists it (a derived one stays off the wire), the hub row lists it, and
/// `resolve` and `wait` find the chat by `HANDLE` and `HOST/HANDLE`. Leo, 2026-11-23: "the
/// renaming paradigm still hasn't hit yet, and the send/recieve messages are still only the
/// older names".
#[tokio::test]
async fn a_given_handle_rides_the_heartbeat_and_names_the_hub_row() {
    let hub = hub();
    let add = |id: &str, name: &str, handle: Option<String>| {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": name, "harness": "fake",
            "cwd": "/work/app", "status": "idle", "createdAt": 1, "updatedAt": 1,
            "handle": handle,
        }))
        .expect("meta");
        hub.store.save(&meta).expect("save");
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
        hub.update_live_session_index(&session);
    };
    let derived_id = "0198f2a4-0000-7000-8000-0000000000d2";
    add("given", "claude-sr2-coord-old", Some("Mango".into()));
    add("plain", "no-handle", None);
    add(derived_id, "derived", Some(crate::session_handle::default_handle(derived_id)));
    let rows = hub.mesh_rows().await;
    let row = |id: &str| rows.iter().find(|r| r.session_id == id).expect("listed");
    assert_eq!(row("given").handle.as_deref(), Some("Mango"));
    let wire = serde_json::to_value(row("given")).expect("json");
    assert_eq!(wire["handle"], "Mango", "{wire}");
    for id in ["plain", derived_id] {
        let wire = serde_json::to_value(row(id)).expect("json");
        assert!(wire.get("handle").is_none(), "a derived handle stays off the wire: {wire}");
    }

    let mut full = book();
    full.sessions[1].handle = Some("Mango".into());
    // An invalid handle from the hub is no handle.
    full.sessions[3].handle = Some("not a handle".into());
    hub.apply_mesh_book(full, "person-1", Some("d-a"));
    let all = hub.all_session_summaries();
    let named = all.iter().find(|s| s["sessionId"] == B_ID).expect("listed");
    assert_eq!(named["handle"], "Mango", "{named}");
    assert_eq!(named["displayName"], "Mango", "{named}");
    let bare = all.iter().find(|s| s["name"] == "ssh-box/linked").expect("listed");
    assert_eq!(bare["handle"], Value::Null, "{bare}");

    for key in ["Mango", "mango", "machine-b/Mango"] {
        let found = hub.locate(key, false, true).expect(key);
        assert!(found.to_string().contains(B_ID), "{key}: {found}");
        assert_eq!(hub.mesh_book_resolve(key).as_deref(), Some(B_ID), "{key}");
        assert_eq!(
            hub.mesh_book_handle(key),
            Some(("machine-b".to_owned(), B_ID.to_owned())),
            "{key}"
        );
    }
    // Another host's `HOST/HANDLE` names nothing; a derived handle still names its row.
    assert_eq!(hub.mesh_book_handle("ssh-box/Mango"), None);
    let derived = crate::session_handle::default_handle("0198f2a4-0000-7000-8000-00000000000d");
    assert_eq!(
        hub.mesh_book_handle(&format!("ssh-box/{derived}")).map(|(host, _)| host).as_deref(),
        Some("ssh-box")
    );

    // A rename on the far machine reaches the row with its next heartbeat.
    let mut renamed = book();
    renamed.sessions[1].handle = Some("Kiwi".into());
    hub.apply_mesh_book(renamed, "person-1", Some("d-a"));
    assert_eq!(hub.mesh_book_resolve("machine-b/Kiwi").as_deref(), Some(B_ID));
    assert_eq!(hub.mesh_book_resolve("machine-b/Mango"), None);
}

/// A machine's health read through the hub goes via one session the hub lists on it (the hub
/// takes a read only when it names a session): one of that machine's, never a session of a
/// machine whose name it starts with, and none for a machine the book lists no session on.
#[test]
fn a_machine_read_goes_through_one_of_its_own_listed_sessions() {
    let hub = hub();
    let mut b = book();
    b.daemons.push(daemon("d-b2", "machine-b2", "person-1"));
    b.sessions.push(session(
        "0198f2a4-0000-7000-8000-0000000000b2",
        "other",
        "machine-b2",
        "d-b2",
        "ready",
    ));
    hub.apply_mesh_book(b, "person-1", Some("d-a"));
    assert_eq!(hub.mesh_book_session_on("machine-b").as_deref(), Some(B_ID));
    assert_eq!(
        hub.mesh_book_session_on("machine-b2").as_deref(),
        Some("0198f2a4-0000-7000-8000-0000000000b2")
    );
    assert_eq!(hub.mesh_book_session_on("machine-c"), None);
    hub.set_mesh_book(Default::default(), Vec::new());
    assert_eq!(hub.mesh_book_session_on("machine-b"), None);
}

/// A machine only the hub reaches that pushed its health on its heartbeat reads as a reading in
/// the host row (`health`, `healthAt`), is not pulled, and a pull newer than the push wins
/// (RFD 0181 T1). One that sent none, or sent long ago, keeps the pull.
#[tokio::test]
async fn a_pushed_reading_fills_the_host_row_and_spares_the_pull() {
    let hub = hub();
    let now = crate::store::now_ms();
    let mut b = book();
    let d = b.daemons.iter_mut().find(|d| d.daemon_id == "d-b").unwrap();
    d.health = Some(json!({"cpus": 8, "liveSessions": 2}));
    d.health_at = Some(now);
    // A teammate's push is no one of ours.
    let t = b.daemons.iter_mut().find(|d| d.daemon_id == "d-t").unwrap();
    t.health = Some(json!({"cpus": 1}));
    t.health_at = Some(now);
    hub.apply_mesh_book(b, "person-1", Some("d-a"));
    let rows = hub.mesh_book_hosts();
    let machine_b = rows.iter().find(|row| row["name"] == "machine-b").expect("machine-b row");
    assert_eq!(machine_b["health"], json!({"cpus": 8, "liveSessions": 2}));
    assert_eq!(machine_b["healthAt"], json!(now));
    assert!(
        !hub.mesh_health_hosts(now).pull.contains(&"machine-b".to_owned()),
        "no ask for a machine that pushed"
    );

    assert!(hub.mesh_health_hosts(now).listed.contains("machine-b"));

    // A pull newer than the push survives the next refresh and replaces it.
    hub.hub_health.lock().unwrap().answered("machine-b", Some(json!({"cpus": 16})), now + 1);
    hub.mesh_health_hosts(now).due(&mut hub.hub_health.lock().unwrap(), now);
    let machine_b = hub
        .mesh_book_hosts()
        .into_iter()
        .find(|row| row["name"] == "machine-b")
        .expect("machine-b row");
    assert_eq!(machine_b["health"], json!({"cpus": 16}));

    // A later failed pull survives cache maintenance and makes this host unreachable.
    hub.hub_health.lock().unwrap().answered("machine-b", None, now + 2);
    hub.mesh_health_hosts(now + 2).due(&mut hub.hub_health.lock().unwrap(), now + 2);
    let machine_b =
        hub.mesh_book_hosts().into_iter().find(|row| row["name"] == "machine-b").unwrap();
    assert!(crate::placement::reach::row_unreachable(&machine_b, now + 2).is_some());

    // A still newer heartbeat proves contact and supersedes the failed pull.
    let mut back = book();
    let d = back.daemons.iter_mut().find(|d| d.daemon_id == "d-b").unwrap();
    d.health = Some(json!({"cpus": 4}));
    d.health_at = Some(now + 3);
    hub.apply_mesh_book(back, "person-1", Some("d-a"));
    let machine_b =
        hub.mesh_book_hosts().into_iter().find(|row| row["name"] == "machine-b").unwrap();
    assert_eq!(machine_b["health"], json!({"cpus": 4}));
    assert!(crate::placement::reach::row_unreachable(&machine_b, now + 3).is_none());

    // A push gone stale is ignored: the pull is the fallback again.
    let hub = self::hub();
    let mut old = book();
    let d = old.daemons.iter_mut().find(|d| d.daemon_id == "d-b").unwrap();
    d.health = Some(json!({"cpus": 8}));
    d.health_at = Some(now - 10 * 60_000);
    hub.apply_mesh_book(old, "person-1", Some("d-a"));
    let machine_b = hub
        .mesh_book_hosts()
        .into_iter()
        .find(|row| row["name"] == "machine-b")
        .expect("machine-b row");
    assert!(machine_b.get("health").is_none());
    assert!(crate::placement::reach::row_unreachable(&machine_b, now).is_some());
    assert!(hub.mesh_health_hosts(now).pull.contains(&"machine-b".to_owned()));
}

/// A just-started daemon's `transfer_hub {resolve}` waits for its first book read rather than
/// calling a listed machine unlisted (session-move-gcp, 2026-11-27 00:52Z: a move 3 s after a
/// restart), and a later one answers from the read list at once.
#[cfg(feature = "hub-carrier")]
#[tokio::test]
async fn a_resolve_before_the_first_book_read_waits_for_it() {
    let hub = hub();
    let asked = {
        let hub = hub.clone();
        tokio::spawn(async move { hub.transfer_hub(&json!({"resolve": "machine-b"})).await })
    };
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(!asked.is_finished(), "an unread list is not an answer yet");
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    let found = asked.await.expect("join").expect("listed once read");
    assert_eq!(found["host"], "machine-b");
    let began = std::time::Instant::now();
    let gone = hub.transfer_hub(&json!({"resolve": "machine-z"})).await;
    assert!(gone.is_err(), "a read list that lacks it says so");
    assert!(began.elapsed() < std::time::Duration::from_secs(1), "no wait once read");
}

/// A hub row's `updatedAt` is when the chat last changed on its machine, as its heartbeat says,
/// not when this daemon first saw it: a restarted reader lists the same time, so a fleet's rows do
/// not all move to the restart's millisecond (2026-11-26: 1,675 of 1,866 rows read 22:59-23:00Z
/// with nothing changed). A hub that sends none keeps the old reading.
#[tokio::test]
async fn a_hub_rows_updated_at_is_its_machines_not_the_readers_clock() {
    let hub = hub();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "worker", "harness": "fake",
        "cwd": "/work/app", "status": "idle", "createdAt": 1, "updatedAt": 1_700_000_000_000u64,
    }))
    .expect("meta");
    hub.store.save(&meta).expect("save");
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    hub.update_live_session_index(&session);
    let changed = session.meta.lock().unwrap().updated_at;
    let rows = hub.mesh_rows().await;
    let row = rows.iter().find(|r| r.session_id == "s1").expect("listed");
    assert_eq!(row.updated_at, Some(changed));
    assert_eq!(serde_json::to_value(row).expect("json")["updatedAt"], changed);

    let at = 1_700_000_123_456u64;
    let mut said = book();
    said.sessions[1].updated_at = Some(at);
    let updated = |hub: &Arc<Hub>| {
        let all = hub.all_session_summaries();
        all.iter().find(|s| s["sessionId"] == B_ID).expect("listed")["updatedAt"].clone()
    };
    hub.apply_mesh_book(said.clone(), "person-1", Some("d-a"));
    assert_eq!(updated(&hub), at);
    let restarted = self::hub();
    restarted.apply_mesh_book(said.clone(), "person-1", Some("d-a"));
    assert_eq!(updated(&restarted), at, "a restarted reader lists the same time");

    let mut events = hub.events.subscribe();
    said.sessions[1].updated_at = Some(at + 1);
    hub.apply_mesh_book(said, "person-1", Some("d-a"));
    assert_eq!(notices(&mut events).len(), 1, "a real change is announced");
    assert_eq!(updated(&hub), at + 1);

    let before = crate::store::now_ms();
    let silent = self::hub();
    silent.apply_mesh_book(book(), "person-1", Some("d-a"));
    assert!(updated(&silent).as_u64().expect("ms") >= before, "no time said: first seen here");
}

/// A row that leaves the book and comes back as it left keeps its `updatedAt`: a hub outage past
/// a heartbeat's TTL empties the book until each machine heartbeats again, and that is no change
/// to any chat (2026-11-27: 587 of 596 rows restamped at 00:14:38Z after a 503, none changed). One
/// that comes back changed is stamped anew.
#[tokio::test]
async fn a_row_back_after_a_hub_outage_keeps_its_updated_at() {
    let hub = hub();
    let updated = |hub: &Arc<Hub>| {
        let all = hub.all_session_summaries();
        all.iter().find(|s| s["sessionId"] == B_ID).map(|s| s["updatedAt"].as_u64().expect("ms"))
    };
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    let first = updated(&hub).expect("listed");
    std::thread::sleep(std::time::Duration::from_millis(5));
    let mut outage = book();
    outage.sessions.clear();
    hub.apply_mesh_book(outage, "person-1", Some("d-a"));
    assert_eq!(updated(&hub), None, "gone while the hub lists nothing");
    hub.apply_mesh_book(book(), "person-1", Some("d-a"));
    assert_eq!(updated(&hub), Some(first), "back unchanged: no new time");

    hub.set_mesh_book(Default::default(), Vec::new());
    std::thread::sleep(std::time::Duration::from_millis(5));
    let mut changed = book();
    changed.sessions[1].state = "idle".into();
    hub.apply_mesh_book(changed, "person-1", Some("d-a"));
    assert!(updated(&hub).expect("listed") > first, "back changed: stamped anew");
}
