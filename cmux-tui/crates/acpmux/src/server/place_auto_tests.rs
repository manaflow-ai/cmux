//! The rejudge task's passes with a fake hub (chats and machines given as data) and a fake clock
//! (each pass's `now_ms`).

use super::*;
use crate::chat_place::{Cloud, Folder, Needs, Power};
use crate::placement::Candidate;
use serde_json::{Value, json};

const GB: f64 = 1024.0 * 1024.0 * 1024.0;

fn health(ram_gb: f64, cores: u64, load: f64, live: u64, os: &str) -> Value {
    json!({
        "os": os, "cpus": cores, "load": [load, load, load],
        "ram": {"freeBytes": (ram_gb * GB) as u64, "totalBytes": (ram_gb * 4.0 * GB) as u64},
        "swap": {"usedBytes": 0, "totalBytes": (8.0 * GB) as u64},
        "disk": {"freeBytes": (300.0 * GB) as u64}, "liveSessions": live,
        "pressure": {"ok": true, "over": [], "cores": cores}
    })
}

fn idle_mac() -> Value {
    health(20.0, 12, 1.0, 1, "macos")
}

fn loaded_mac() -> Value {
    let mut h = health(3.0, 12, 14.0, 6, "macos");
    h["pressure"] = json!({"ok": false, "over": ["cpu", "ram"], "cores": 12});
    h
}

fn big_box() -> Candidate {
    Candidate {
        name: "big-box".into(),
        local: false,
        health: health(100.0, 32, 2.0, 3, "linux"),
        health_at: None,
    }
}

fn input(local: Value, peers: Vec<Candidate>) -> Input {
    let power = Power::from_health(&local);
    Input {
        local: Candidate { name: "leos-mac".into(), local: true, health: local, health_at: None },
        peers,
        registry: None,
        power,
        folder: Folder::default(),
        needs: Needs::default(),
        cloud: Cloud { available: true, ..Cloud::default() },
    }
}

fn sleeping(mut i: Input) -> Input {
    i.power.sleeping = true;
    i
}

fn here(session: &str) -> Chat {
    Chat {
        session: session.into(),
        running: Running {
            place: Place::Local,
            home: Place::Local,
            pinned: false,
            turn_active: false,
            local_over_secs: 0,
        },
        there: None,
        needs: Needs::default(),
    }
}

fn away(session: &str, place: Place, there: Option<&str>) -> Chat {
    let mut c = here(session);
    c.running.place = place;
    c.there = there.map(str::to_owned);
    c
}

const T0: u64 = 1_000_000;

#[test]
fn chat_place_task_moves_a_chat_to_a_joined_machine_only_after_load_held() {
    let mut judge = Rejudger::default();
    let mut i = input(loaded_mac(), vec![big_box()]);
    let chats = [here("s1")];
    assert!(judge.step(T0, &chats, &mut i, &[], false).is_empty(), "a burst of load moves nothing");
    assert!(judge.step(T0 + 60_000, &chats, &mut i, &[], false).is_empty());
    let orders = judge.step(T0 + 121_000, &chats, &mut i, &[], false);
    assert_eq!(orders.len(), 1, "{orders:?}");
    let Order::Run { session, mv, args } = &orders[0] else { panic!("{orders:?}") };
    assert_eq!(session, "s1");
    assert_eq!(mv.to, Place::Peer("big-box".into()));
    assert_eq!(args, &["session", "move", "s1", "--host", "big-box"]);
}

#[test]
fn chat_place_task_restarts_the_hold_when_load_clears() {
    let mut judge = Rejudger::default();
    let chats = [here("s1")];
    let mut loaded = input(loaded_mac(), vec![big_box()]);
    assert!(judge.step(T0, &chats, &mut loaded, &[], false).is_empty());
    assert!(
        judge.step(T0 + 100_000, &chats, &mut input(idle_mac(), vec![]), &[], false).is_empty()
    );
    assert!(
        judge.step(T0 + 130_000, &chats, &mut loaded, &[], false).is_empty(),
        "the load cleared in between: the hold starts again"
    );
    assert_eq!(judge.step(T0 + 251_000, &chats, &mut loaded, &[], false).len(), 1);
    // No Auto chat at all forgets the hold too.
    let mut judge = Rejudger::default();
    assert!(judge.step(T0, &chats, &mut loaded, &[], false).is_empty());
    judge.idle();
    assert!(judge.step(T0 + 200_000, &chats, &mut loaded, &[], false).is_empty());
}

#[test]
fn chat_place_task_sends_sleep_moves_to_cloud_through_the_app_at_once() {
    let mut judge = Rejudger::default();
    let orders = judge.step(T0, &[here("s1")], &mut sleeping(input(idle_mac(), vec![])), &[], true);
    let [Order::App { session, mv }] = orders.as_slice() else { panic!("{orders:?}") };
    assert_eq!(session, "s1");
    assert_eq!(mv.to, Place::Cloud);
    assert!(!mv.back);
}

#[test]
fn chat_place_task_asks_once_until_the_retry_window_or_a_new_sleep() {
    let mut judge = Rejudger::default();
    let chats = [here("s1")];
    let mut i = sleeping(input(idle_mac(), vec![]));
    assert_eq!(judge.step(T0, &chats, &mut i, &[], true).len(), 1);
    // Moving: never asked again while it is.
    assert!(judge.step(T0 + 1_000, &chats, &mut i, &["s1".into()], true).is_empty());
    // Refused by the app (nothing in flight): not asked again on a plain pass...
    assert!(judge.step(T0 + 30_000, &chats, &mut i, &[], false).is_empty());
    // ...but at once on a new sleep word, and after the retry window.
    assert_eq!(judge.step(T0 + 31_000, &chats, &mut i, &[], true).len(), 1);
    assert!(judge.step(T0 + 62_000, &chats, &mut i, &[], false).is_empty());
    assert_eq!(judge.step(T0 + 31_000 + RETRY_MS, &chats, &mut i, &[], false).len(), 1);
}

#[test]
fn chat_place_task_brings_chats_back_through_the_app_or_the_peer_move() {
    let mut judge = Rejudger::default();
    let chats = [
        away("cloudy", Place::Cloud, None),
        away("peered", Place::Peer("big-box".into()), Some("there-1")),
        away("lost", Place::Peer("big-box".into()), None),
    ];
    let orders = judge.step(T0, &chats, &mut input(idle_mac(), vec![big_box()]), &[], false);
    assert_eq!(orders.len(), 2, "a peer chat with no id there cannot be asked back: {orders:?}");
    let Order::App { session, mv } = &orders[0] else { panic!("{orders:?}") };
    assert_eq!((session.as_str(), &mv.to, mv.back), ("cloudy", &Place::Local, true));
    let Order::Run { session, mv, args } = &orders[1] else { panic!("{orders:?}") };
    assert_eq!(session, "peered");
    assert!(mv.back);
    assert_eq!(args, &["session", "move", "there-1", "--from", "big-box", "--host", "local"]);
    // Not while its turn runs, nor to a Mac still busy.
    let mut busy = away("peered", Place::Peer("big-box".into()), Some("there-1"));
    busy.running.turn_active = true;
    assert!(
        Rejudger::default()
            .step(T0, &[busy], &mut input(idle_mac(), vec![]), &[], false)
            .is_empty()
    );
    assert!(
        Rejudger::default()
            .step(
                T0,
                &[away("cloudy", Place::Cloud, None)],
                &mut input(loaded_mac(), vec![]),
                &[],
                false
            )
            .is_empty()
    );
}

#[test]
fn chat_place_task_reads_where_a_chat_is_from_its_row() {
    let row = |moved_to: Option<Value>, tag: Option<&str>| AutoChat {
        session: "s1".into(),
        turn_active: true,
        moved_to,
        moved_tag: tag.map(str::to_owned),
        needs_tag: None,
        cwd: PathBuf::from("/nowhere"),
    };
    let no_turn = |_: &str, _: &str| false;
    let c = Chat::of(&row(None, None), Needs::default(), no_turn);
    assert_eq!(
        (c.running.place, c.running.pinned, c.running.turn_active),
        (Place::Local, false, true)
    );
    // A stale tag on a chat that is here again does not move it.
    assert_eq!(
        Chat::of(&row(None, Some("cloud")), Needs::default(), no_turn).running.place,
        Place::Local
    );
    let moved = || Some(json!({"host": "big-box.ts.net", "sessionId": "there-1"}));
    let c = Chat::of(&row(moved(), Some("peer:big-box")), Needs::default(), |peer, id| {
        peer == "big-box" && id == "there-1"
    });
    assert_eq!(c.running.place, Place::Peer("big-box".into()));
    assert_eq!(c.there.as_deref(), Some("there-1"));
    assert!(c.running.turn_active, "the turn there, from the peer's row");
    assert!(!Chat::of(&row(moved(), Some("cloud")), Needs::default(), no_turn).running.turn_active);
    // Moved with no tag: the person moved it, and Auto leaves it.
    let c = Chat::of(&row(moved(), None), Needs::default(), no_turn);
    assert!(c.running.pinned);
    assert!(
        Rejudger::default().step(T0, &[c], &mut input(idle_mac(), vec![]), &[], false).is_empty()
    );
}

#[test]
fn chat_place_task_weighs_each_chat_with_its_own_needs() {
    // An over-loaded Mac with only Cloud to go to: a plain chat moves, a macOS chat stays.
    let mut judge = Rejudger::default();
    let mut mac_work = here("xcode");
    mac_work.needs = Needs { macos: true, ..Needs::default() };
    let chats = [here("plain"), mac_work];
    let mut i = input(loaded_mac(), vec![]);
    assert!(judge.step(T0, &chats, &mut i, &[], false).is_empty());
    let orders = judge.step(T0 + 121_000, &chats, &mut i, &[], false);
    let [Order::App { session, mv }] = orders.as_slice() else { panic!("{orders:?}") };
    assert_eq!((session.as_str(), &mv.to), ("plain", &Place::Cloud));
}

#[test]
fn chat_place_task_reads_needs_from_the_tag_or_the_folder() {
    assert_eq!(tag_needs("macos, gpu"), Needs { macos: true, gpu: true, long_build: false });
    assert_eq!(tag_needs("build,mars"), Needs { long_build: true, ..Needs::default() });
    assert_eq!(tag_needs(""), Needs::default());
    let root = std::env::temp_dir().join(format!("place-auto-needs-{}", std::process::id()));
    let folder = |name: &str| {
        let dir = root.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    };
    let xcode = folder("xcode");
    std::fs::create_dir_all(xcode.join("App.xcodeproj")).unwrap();
    assert!(folder_needs(&xcode).macos);
    let apple = folder("apple-package");
    std::fs::write(apple.join("Package.swift"), "let p = Package(platforms: [.macOS(.v14)])")
        .unwrap();
    assert!(folder_needs(&apple).macos);
    let linux = folder("linux-package");
    std::fs::write(linux.join("Package.swift"), "let p = Package(name: \"tool\")").unwrap();
    assert!(!folder_needs(&linux).macos);
    assert!(!folder_needs(&root.join("missing")).macos);
    std::fs::remove_dir_all(&root).unwrap();
}
