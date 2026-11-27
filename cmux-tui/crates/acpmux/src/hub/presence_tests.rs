use super::*;

fn ana() -> Who {
    Who { id: "tailnet:ana".to_owned(), name: "Ana".to_owned() }
}

fn typing(presence: &Presence) -> Option<bool> {
    let note = presence.snapshot("c");
    note["participants"].as_array()?.first().map(|p| p["typing"] == true)
}

/// A newer `on` restarts the 8 s and the older timer ends without effect; an `off` and a close
/// end it at once. (The 8 s expiry itself: `tests/hub_integration/presence.rs`.)
#[tokio::test(start_paused = true)]
async fn a_newer_on_restarts_the_expiry_and_off_or_close_ends_it() {
    let presence = Presence::default();
    presence.typing("c", "conn", &ana(), true).unwrap();
    tokio::time::sleep(Duration::from_secs(5)).await;
    presence.typing("c", "conn", &ana(), true).unwrap();
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(typing(&presence), Some(true), "the first timer ended the newer on");
    tokio::time::sleep(Duration::from_millis(3001)).await;
    assert_eq!(typing(&presence), None);

    presence.typing("c", "conn", &ana(), true).unwrap();
    presence.typing("c", "conn", &ana(), false).unwrap();
    assert_eq!(typing(&presence), None);
    presence.typing("c", "other", &ana(), true).unwrap();
    presence.close("other");
    assert_eq!(presence.snapshot("c")["participants"], json!([]));
}

#[tokio::test(start_paused = true)]
async fn records_follow_the_aggregated_chat_and_its_owner_revision() {
    let hub = Presence::default();
    let who = ana();
    hub.view("chat", "a", &who, true).unwrap();
    let first = hub.records("chat").pop().unwrap();
    assert_eq!(first.id.0.as_ref(), who.id);
    assert_eq!(first.location.chat.as_deref(), Some("chat"));
    hub.typing("chat", "b", &who, true).unwrap();
    let typing = hub.records("chat");
    assert_eq!(typing.len(), 1);
    assert!(typing[0].epoch > first.epoch);
    assert_eq!(typing[0].doing, Doing::Typing);
    assert_eq!(typing[0].lease_ms, cmux_presence::TYPING_LEASE_MS);
    assert_eq!(
        hub.snapshot("chat")["participants"],
        json!([
            {"id":who.id, "name":who.name, "devices":2, "viewing":true, "typing":true}
        ])
    );
    hub.close("b");
    let idle = hub.records("chat").pop().unwrap();
    assert_eq!(idle.doing, Doing::Idle);
    assert!(idle.epoch > typing[0].epoch);
    hub.close("a");
    assert!(hub.records("chat").is_empty());
    hub.view("chat", "a", &who, true).unwrap();
    assert!(hub.records("chat")[0].epoch > idle.epoch);
}

#[test]
fn a_cutover_is_transient_per_reader_and_connection() {
    let presence = Presence::default();
    let alice = ana();
    let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
    presence.view_with_cutover("c", "conn-a", &alice, true, true, Some(2)).unwrap();
    presence.view_with_cutover("c", "conn-b", &bob, true, true, Some(3)).unwrap();
    assert_eq!(presence.active_cutover("c", "tailnet:ana"), Some(2));
    assert_eq!(presence.active_cutover("c", "tailnet:bob"), Some(3));
    presence.view_with_cutover("c", "conn-a", &alice, true, false, Some(4)).unwrap();
    assert_eq!(presence.active_cutover("c", "tailnet:ana"), None);
    assert_eq!(presence.active_cutover("c", "tailnet:bob"), Some(3));
    presence.leave("c", "conn-b");
    assert_eq!(presence.active_cutover("c", "tailnet:bob"), None);
}

#[tokio::test]
async fn live_list_is_empty_until_live_and_merges_a_person_across_chats() {
    let presence = Presence::default();
    presence.view("a", "c1", &ana(), true).unwrap();
    presence.view("b", "c1", &ana(), true).unwrap();
    presence
        .view("b", "c2", &Who { id: "tailnet:bo".to_owned(), name: "Bo".to_owned() }, true)
        .unwrap();
    assert!(presence.live_list().is_empty(), "off by default");
    assert!(!presence.set_live(true));
    assert!(presence.is_live());
    let list = presence.live_list();
    let ids: Vec<&str> = list.iter().map(|r| &*r.id.0).collect();
    assert_eq!(ids, ["tailnet:ana", "tailnet:bo"]);
    presence.typing("a", "c1", &ana(), true).unwrap();
    let list = presence.live_list();
    assert_eq!(list[0].location.chat.as_deref(), Some("a"), "the chat where they type");
    assert_eq!(list[0].doing, Doing::Typing);
    assert!(presence.set_live(false));
    assert!(presence.live_list().is_empty(), "off again clears the list");
}

#[tokio::test]
async fn live_list_drops_people_who_left() {
    let presence = Presence::default();
    presence.set_live(true);
    presence.view("a", "c1", &ana(), true).unwrap();
    assert_eq!(presence.live_list().len(), 1);
    presence.close("c1");
    assert!(presence.live_list().is_empty());
}

/// A sink that keeps what it heard.
fn heard() -> (Sink, Arc<Mutex<Vec<Value>>>) {
    let notes = Arc::new(Mutex::new(Vec::new()));
    let keep = notes.clone();
    (Arc::new(move |note| keep.lock_or_recover().push(note)), notes)
}

fn chat(id: &str) -> Room {
    Room::Chat(id.to_owned())
}

/// A change reaches the room's subscribers only, as one delta from the snapshot's epoch; a
/// subscriber to another room, or to none, hears nothing of it.
#[test]
fn a_change_fans_out_to_that_rooms_subscribers_only() {
    let presence = Presence::default();
    let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
    presence.view("c", "conn-a", &ana(), true).unwrap();
    let (watcher, watched) = heard();
    let (other, elsewhere) = heard();
    assert_eq!(presence.rooms("w", watcher, vec![chat("c")]).unwrap(), 1);
    assert_eq!(
        presence.rooms("o", other, vec![chat("d"), Room::Workspace("ws".into())]).unwrap(),
        2
    );

    let snapshot = watched.lock_or_recover()[0].clone();
    assert_eq!(snapshot["room"], json!({"chat": "c"}));
    assert_eq!(snapshot["snapshot"], true);
    let base = snapshot["presence"][0]["epoch"].as_u64().unwrap();
    assert_eq!(snapshot["presence"][0]["id"], "tailnet:ana");

    presence.view("c", "conn-b", &bob, true).unwrap();
    presence.view("c", "conn-a", &ana(), false).unwrap();
    let notes = watched.lock_or_recover().clone();
    assert_eq!(notes.len(), 3, "one note a change: {notes:?}");
    assert_eq!(notes[1]["presence"][0]["id"], "tailnet:bob", "bob joined: {}", notes[1]);
    assert_eq!(notes[1]["deltas"][0]["id"], "tailnet:ana");
    assert_eq!(notes[1]["deltas"][0]["base"], base, "the delta builds on the snapshot");
    assert_eq!(notes[2]["left"], json!(["tailnet:ana"]));
    assert_eq!(notes[2]["deltas"][0]["base"], notes[1]["deltas"][0]["epoch"]);

    let others = elsewhere.lock_or_recover().clone();
    assert_eq!(others.len(), 2, "only its own rooms' snapshots: {others:?}");
    assert!(others.iter().all(|n| n["snapshot"] == true));
}

/// An empty set unsubscribes, a smaller one drops only the rooms it left out, a detach drops
/// that chat's room, and a close drops the rest.
#[test]
fn unsubscribe_stops_the_deltas() {
    let presence = Presence::default();
    let (sink, notes) = heard();
    presence.rooms("w", sink.clone(), vec![chat("c"), chat("d")]).unwrap();
    assert_eq!(notes.lock_or_recover().len(), 2);
    presence.rooms("w", sink.clone(), vec![chat("d")]).unwrap();
    assert_eq!(notes.lock_or_recover().len(), 2, "a room it already watched snapshots once");
    assert!(!presence.watches("w", &chat("c")));
    presence.view("c", "conn", &ana(), true).unwrap();
    assert_eq!(notes.lock_or_recover().len(), 2, "c is no longer watched");
    presence.view("d", "conn", &ana(), true).unwrap();
    assert_eq!(notes.lock_or_recover().len(), 3);

    assert_eq!(presence.rooms("w", sink.clone(), Vec::new()).unwrap(), 0);
    presence.view("d", "conn", &ana(), false).unwrap();
    assert_eq!(notes.lock_or_recover().len(), 3, "an empty set unsubscribes");
    assert!(presence.inner.state.lock_or_recover().rooms.is_empty(), "no empty room is kept");

    presence.rooms("w", sink.clone(), vec![chat("c"), chat("d")]).unwrap();
    presence.leave("c", "w");
    assert!(!presence.watches("w", &chat("c")), "a detach drops its chat room");
    assert!(presence.watches("w", &chat("d")));
    presence.close("w");
    assert!(!presence.watches("w", &chat("d")));
    let state = presence.inner.state.lock_or_recover();
    assert!(state.rooms.is_empty() && state.watching.is_empty());
}

#[test]
fn a_set_past_the_bound_is_refused_and_keeps_the_old_one() {
    let presence = Presence::default();
    let (sink, _) = heard();
    presence.rooms("w", sink.clone(), vec![chat("c")]).unwrap();
    let many = (0..=MAX_ROOMS).map(|i| Room::Workspace(format!("ws{i}"))).collect();
    let refused = presence.rooms("w", sink, many).unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], ROOMS_FULL);
    assert!(presence.watches("w", &chat("c")));
}

/// A follow reaches the follower's rooms as one `Following` delta, `_acpmux/presence` does
/// not change, and `null` clears it the same way.
#[test]
fn a_follow_rides_the_room_deltas_and_null_clears_it() {
    let presence = Presence::default();
    let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
    presence.view("c", "conn-a", &ana(), true).unwrap();
    presence.view("d", "conn-b", &bob, true).unwrap();
    let (sink, notes) = heard();
    presence.rooms("w", sink, vec![chat("c")]).unwrap();
    let mut changes = presence.subscribe();
    let before = presence.snapshot("c");

    presence.follow("conn-a", "tailnet:ana", Some("tailnet:bob")).unwrap();
    assert_eq!(presence.following("conn-a", "tailnet:ana").as_deref(), Some("tailnet:bob"));
    let follow = notes.lock_or_recover()[1].clone();
    assert_eq!(follow["deltas"][0]["id"], "tailnet:ana", "{follow}");
    assert_eq!(follow["deltas"][0]["changes"], json!([{"following": "tailnet:bob"}]), "{follow}");
    assert_eq!(
        presence.records("c")[0].following.as_ref().map(|id| id.0.as_ref()),
        Some("tailnet:bob")
    );
    assert_eq!(presence.snapshot("c"), before, "_acpmux/presence is unchanged");
    assert!(changes.try_recv().is_err(), "a follow alone broadcasts no _acpmux/presence");

    // A chat the follower moves to carries it on its record.
    presence.view("e", "conn-a", &ana(), true).unwrap();
    assert!(presence.records("e")[0].following.is_some());

    presence.follow("conn-a", "tailnet:ana", None).unwrap();
    let cleared = notes.lock_or_recover()[2].clone();
    assert_eq!(cleared["deltas"][0]["changes"], json!([{"following": null}]), "{cleared}");
    assert!(presence.records("c")[0].following.is_none());
    assert_eq!(notes.lock_or_recover().len(), 3, "one note a follow change");
}

/// Following yourself and following someone who shows no chat here are refused, and
/// change nothing.
#[test]
fn a_follow_of_yourself_or_of_nobody_live_is_refused() {
    let presence = Presence::default();
    presence.view("c", "conn-a", &ana(), true).unwrap();
    let own = presence.follow("conn-a", "tailnet:ana", Some("tailnet:ana")).unwrap_err();
    assert_eq!(own.data.as_ref().unwrap()["reason"], FOLLOW_SELF);
    let gone = presence.follow("conn-a", "tailnet:ana", Some("tailnet:zed")).unwrap_err();
    assert_eq!(gone.data.as_ref().unwrap()["reason"], FOLLOW_NOT_LIVE);
    assert_eq!(presence.following("conn-a", "tailnet:ana"), None);
    assert!(presence.records("c")[0].following.is_none());
}

/// Closing the follower's connection ends its follow as a delta, so the same person on
/// another connection no longer shows it.
#[test]
fn closing_the_followers_connection_ends_the_follow() {
    let presence = Presence::default();
    let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
    presence.view("c", "conn-a", &ana(), true).unwrap();
    presence.view("c", "conn-a2", &ana(), true).unwrap();
    presence.view("d", "conn-b", &bob, true).unwrap();
    presence.follow("conn-a", "tailnet:ana", Some("tailnet:bob")).unwrap();
    let (sink, notes) = heard();
    presence.rooms("w", sink, vec![chat("c")]).unwrap();
    presence.close("conn-a");
    assert_eq!(presence.following("conn-a", "tailnet:ana"), None);
    assert!(presence.records("c")[0].following.is_none());
    let heard = notes.lock_or_recover().clone();
    assert!(
        heard.iter().any(|n| n["deltas"][0]["changes"] == json!([{"following": null}])),
        "{heard:?}"
    );
    assert!(presence.inner.state.lock_or_recover().follows.is_empty());
}

/// The cost of one update is the room's subscribers, never the number of other rooms: the
/// same change visits one subscriber beside 10 unrelated rooms and beside 10,000.
#[test]
fn cost_per_update_does_not_grow_with_unrelated_rooms() {
    let mut visited = Vec::new();
    for unrelated in [10, 10_000] {
        let presence = Presence::default();
        for i in 0..unrelated {
            let (sink, _) = heard();
            let conn = format!("u{i}");
            presence.view(&format!("other{i}"), &conn, &ana(), true).unwrap();
            presence
                .rooms(
                    &conn,
                    sink,
                    vec![chat(&format!("other{i}")), Room::Workspace(format!("ws{i}"))],
                )
                .unwrap();
        }
        let (sink, notes) = heard();
        presence.rooms("w", sink, vec![chat("c")]).unwrap();
        let before = presence.inner.state.lock_or_recover().fanned;
        presence.view("c", "conn", &ana(), true).unwrap();
        presence.view("c", "conn", &ana(), false).unwrap();
        visited.push(presence.inner.state.lock_or_recover().fanned - before);
        assert_eq!(notes.lock_or_recover().len(), 3, "snapshot and two changes");
    }
    assert_eq!(visited, vec![2, 2], "subscribers visited for two changes");
}
