//! Ported from the App's CloudStartChatMachineTests and AgentPaneCloudStartTests
//! (cmux#28111), which these Rust tests replace.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::ledger::{LIMIT, Ledger};
use super::pick::{self, Candidate, Destination};
use super::{Keys, StartCopy, pin, plan, remote_name, valid_key};

const ME: &str = "user-leo";
const TEAMMATE: &str = "user-austin";

fn machine(id: &str, title: &str) -> Candidate {
    Candidate {
        id: id.into(),
        title: title.into(),
        created_by: Some(ME.into()),
        status: "running".into(),
        connected: true,
        chats: Some(0),
        ..Candidate::default()
    }
}

fn with(mut candidate: Candidate, change: impl FnOnce(&mut Candidate)) -> Candidate {
    change(&mut candidate);
    candidate
}

fn offline(candidate: Candidate, status: &str, pause: Option<&str>) -> Candidate {
    with(candidate, |machine| {
        machine.connected = false;
        machine.chats = None;
        machine.status = status.into();
        machine.pause_reason = pause.map(str::to_string);
    })
}

fn none() -> BTreeSet<String> {
    BTreeSet::new()
}

fn key() -> String {
    // Any UUID-shaped key; distinct per call.
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("0000000A-0000-4000-8000-{:012X}", NEXT.fetch_add(1, Ordering::Relaxed))
}

fn scratch() -> tempfile::TempDir {
    tempfile::tempdir().expect("tempdir")
}

fn ledger_in(dir: &Path) -> PathBuf {
    dir.join("cloud-start-chat").join("destinations.json")
}

#[test]
fn a_teammates_connected_machine_is_never_taken_and_none_of_mine_makes_a_new_one() {
    let team = [
        with(machine("vm-a", "austin-box"), |m| m.created_by = Some(TEAMMATE.into())),
        with(machine("vm-b", "Cloud Machine"), |m| m.created_by = Some(TEAMMATE.into())),
    ];
    assert_eq!(pick::pick(&team, Some(ME), &none()), None);
    assert_eq!(pick::pick(&team, None, &none()), None);
}

#[test]
fn a_busy_machine_of_mine_is_passed_over_for_a_free_one() {
    let machines =
        [with(machine("vm-busy", "work"), |m| m.chats = Some(3)), machine("vm-free", "spare")];
    assert_eq!(pick::pick(&machines, Some(ME), &none()).as_deref(), Some("vm-free"));
    let busy = [with(machine("vm-busy", "work"), |m| m.chats = Some(1))];
    assert_eq!(pick::pick(&busy, Some(ME), &none()), None);
}

#[test]
fn a_machine_marked_for_chats_is_taken_first_even_with_chats_open() {
    let machines = [
        machine("vm-free", "spare"),
        with(machine("vm-chats", "cloud-chats"), |m| m.chats = Some(4)),
    ];
    assert_eq!(pick::pick(&machines, Some(ME), &none()).as_deref(), Some("vm-chats"));
    assert!(pick::is_marked_for_chats("Cloud-Chats-2"));
    assert!(!pick::is_marked_for_chats("cloud-chats-x"));
    let theirs = [with(machine("vm-c", "cloud-chats"), |m| m.created_by = Some(TEAMMATE.into()))];
    assert_eq!(pick::pick(&theirs, Some(ME), &none()), None);
}

#[test]
fn lane_shell_vms_are_never_picked() {
    let lanes =
        [machine("vm-1", "fs-lane-3"), machine("vm-2", "lane-vm-1"), machine("vm-3", "LANE-VM-12")];
    assert_eq!(pick::pick(&lanes, Some(ME), &none()), None);
    let slugged = [with(machine("vm-4", "Leo's box"), |m| m.slug = Some("fs-lane-7".into()))];
    assert_eq!(pick::pick(&slugged, Some(ME), &none()), None);
    assert!(!pick::is_lane_pool("fs-lane-notes"));
    assert!(!pick::is_lane_pool("lane-vm-"));
}

#[test]
fn an_idle_paused_machine_of_mine_is_free_and_a_persons_pause_is_not() {
    let idle = offline(machine("vm-idle", "spare"), "paused", Some("idle"));
    let paused = offline(machine("vm-paused", "kept"), "paused", Some("user"));
    let failed = offline(machine("vm-failed", "broken"), "failed", None);
    let all = [paused, failed, idle.clone()];
    assert_eq!(pick::pick(&all, Some(ME), &none()).as_deref(), Some("vm-idle"));
    // A connected free machine comes before one that must resume.
    let both = [idle, machine("vm-live", "live")];
    assert_eq!(pick::pick(&both, Some(ME), &none()).as_deref(), Some("vm-live"));
}

#[test]
fn a_machine_with_no_creator_counts_as_mine_only_when_an_earlier_send_ran_there() {
    let unknown = [with(machine("vm-x", "cloud-chats"), |m| m.created_by = None)];
    assert_eq!(pick::pick(&unknown, Some(ME), &none()), None);
    let used = BTreeSet::from(["vm-x".to_string()]);
    assert_eq!(pick::pick(&unknown, Some(ME), &used).as_deref(), Some("vm-x"));
}

#[test]
fn a_new_machine_for_chats_gets_a_free_name() {
    assert_eq!(pick::new_machine_name(["fs-lane-1"]), "cloud-chats");
    assert_eq!(pick::new_machine_name(["Cloud-Chats", "cloud-chats-2"]), "cloud-chats-3");
    assert_eq!(pick::new_machine_name([" cloud-chats "]), "cloud-chats-2");
}

/// #28845: the first try took vm-a; then vm-a dropped its link and the list's
/// order changed. The retry still goes to vm-a, where its tab key gets the
/// first try's tab back.
#[test]
fn a_retry_of_the_same_send_stays_on_its_first_trys_machine() {
    let mut pins = Ledger::default();
    let key = key();
    let first = [machine("vm-a", "spare-a"), machine("vm-b", "spare-b")];
    assert_eq!(
        pick::destination(&key, &mut pins, &first, Some(ME), true),
        Destination::Machine("vm-a".into())
    );
    pins.record("vm-a", &key);
    let later = [machine("vm-b", "spare-b"), offline(machine("vm-a", "spare-a"), "running", None)];
    assert_eq!(
        pick::destination(&key, &mut pins, &later, Some(ME), true),
        Destination::Machine("vm-a".into())
    );
    assert_eq!(
        pick::destination(&key.to_lowercase(), &mut pins, &later, Some(ME), false),
        Destination::Machine("vm-a".into())
    );
    assert_eq!(
        pick::destination(&self::key(), &mut pins, &later, Some(ME), true),
        Destination::Machine("vm-b".into())
    );
}

#[test]
fn a_retry_whose_machine_is_gone_picks_afresh_and_a_retry_of_a_new_machine_stays_on_it() {
    let mut pins = Ledger::default();
    let key = key();
    pins.record("vm-gone", &key);
    let now = [machine("vm-b", "spare-b")];
    assert_eq!(
        pick::destination(&key, &mut pins, &now, Some(ME), true),
        Destination::Machine("vm-b".into())
    );
    assert_eq!(pins.machine(&key), None);
    // A machine made for the first try (the list is not loaded yet) is kept for its retry.
    pins.record("vm-new", &key);
    assert_eq!(
        pick::destination(&key, &mut pins, &now, Some(ME), false),
        Destination::Machine("vm-new".into())
    );
}

#[test]
fn the_ledger_survives_a_relaunch_and_keeps_only_the_newest() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let keys: Vec<String> = (0..=LIMIT).map(|_| key()).collect();
    for (index, key) in keys.iter().enumerate() {
        Ledger::update(&path, |pins| pins.record(&format!("vm-{index}"), key)).unwrap();
    }
    let relaunched = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(relaunched.machine(&keys[0]), None);
    assert_eq!(relaunched.machine(&keys[1]).as_deref(), Some("vm-1"));
    assert_eq!(relaunched.machine(keys.last().unwrap()), Some(format!("vm-{LIMIT}")));
    assert_eq!(relaunched.machines().len(), LIMIT);
    // Only this user may read it.
    use std::os::unix::fs::PermissionsExt as _;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
}

/// A retry after the copy finished opens its chat without copying again.
#[test]
fn a_finished_copy_is_kept_per_send_and_machine_across_a_relaunch() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let key = key();
    Ledger::update(&path, |pins| {
        pins.record("vm-a", &key);
        assert_eq!(pins.copied_chat(&key, "vm-a"), None);
        pins.record_copy("/home/cmux/work/chats/k/paint", &key, "vm-a");
        // Pinning the same machine again (the retry) keeps the finished copy.
        pins.record("vm-a", &key);
    })
    .unwrap();
    Ledger::update(&path, |pins| {
        assert_eq!(
            pins.copied_chat(&key.to_lowercase(), "vm-a").as_deref(),
            Some("/home/cmux/work/chats/k/paint")
        );
        assert_eq!(pins.copied_chat(&key, "vm-b"), None);
        pins.record("vm-b", &key);
        assert_eq!(pins.copied_chat(&key, "vm-a"), None);
        assert_eq!(pins.copied_chat(&key, "vm-b"), None);
    })
    .unwrap();
}

#[test]
fn a_sends_keys_are_its_own_and_the_same_for_its_retry() {
    let key = key();
    let first = Keys::of(&key);
    assert_eq!(first, Keys::of(&key.to_lowercase()));
    assert_ne!(first, Keys::of(&self::key()));
    assert_eq!(first.create, format!("cloud-start-chat-{}", key.to_lowercase()));
    assert_eq!(first.tab, format!("cloud-start-chat-{}", key.to_lowercase()));
    assert_eq!(first.place, format!("chats/{}", key.to_lowercase()));
    assert!(first.create.len() <= 128);
    assert!(valid_key(&key));
    assert!(!valid_key("not-a-uuid"));
    assert!(!valid_key("0000000A-0000-4000-8000-00000000000G"));
}

#[test]
fn plan_pins_a_machine_that_exists_and_names_a_new_one_otherwise() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let key = key();
    let request = json!({"key": key, "user": ME, "loaded": true, "machines": [
        {"id": "vm-busy", "title": "cloud-chats-x", "created_by": ME, "status": "running", "connected": true, "chats": 2},
        {"id": "vm-other", "title": "cloud-chats", "created_by": TEAMMATE, "status": "running", "connected": true, "chats": 0},
    ]});
    let answer = plan(&path, &request.to_string());
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(answer["machine"], Value::Null);
    assert_eq!(answer["new_name"], json!("cloud-chats-2"));
    assert_eq!(answer["create_key"], json!(format!("cloud-start-chat-{}", key.to_lowercase())));
    // The App made vm-new for it and pinned it; the retry, before the list shows it, goes there.
    assert_eq!(pin(&path, &key, "vm-new")["ok"], json!(true));
    let retry = json!({"key": key.to_uppercase(), "user": ME, "loaded": false, "machines": []});
    assert_eq!(plan(&path, &retry.to_string())["machine"], json!("vm-new"));

    let free = json!({"key": self::key(), "user": ME, "loaded": true, "machines": [
        {"id": "vm-free", "title": "spare", "created_by": ME, "status": "running", "connected": true, "chats": 0},
    ]});
    assert_eq!(plan(&path, &free.to_string())["machine"], json!("vm-free"));
    assert_eq!(plan(&path, "{")["error_code"], json!("bad_request"));
    assert_eq!(
        plan(&path, &json!({"key": "nope"}).to_string())["error_code"],
        json!("bad_request")
    );
}

#[test]
fn a_copied_folder_keeps_move_to_clouds_name_under_the_sends_place() {
    // The name `CloudMoveFolder.remoteName` gives: the folder's name and 24 bits of FNV-1a.
    assert_eq!(remote_name("/Users/me/src/paint"), "paint-33f597");
    assert_eq!(remote_name("/"), format!("folder-{}", &remote_name("/")[7..]));
    let copy = copy_of("/Users/me/src/paint", "web/app");
    let place = format!("/home/cmux/work/chats/{}", copy.key.to_lowercase());
    let (folder, chat) = copy.remote("/home/cmux/work");
    assert_eq!(folder, format!("{place}/paint-33f597"));
    assert_eq!(chat, format!("{place}/paint-33f597/web/app"));
    let top = StartCopy { subpath: String::new(), ..copy.clone() };
    assert_eq!(
        top.remote("/root/work/").1,
        format!("/root/work/chats/{}/paint-33f597", copy.key.to_lowercase())
    );
}

fn copy_of(local: &str, subpath: &str) -> StartCopy {
    StartCopy {
        key: key(),
        machine: "vm-a".into(),
        socket: PathBuf::from("/tmp/machine.sock"),
        local: local.into(),
        subpath: subpath.into(),
        work_roots: vec!["/home/cmux/work".into(), "/root/work".into()],
    }
}

/// A push that fails with a code per call, recording where it pushed.
fn pushes(
    results: Vec<Result<(), &'static str>>,
) -> (RefCell<Vec<String>>, RefCell<Vec<Result<(), &'static str>>>) {
    (RefCell::new(Vec::new()), RefCell::new(results))
}

#[test]
fn a_copy_tries_the_next_work_root_only_when_the_first_is_not_the_machines_home() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let copy = copy_of("/Users/me/src/paint", "");
    let (seen, results) = pushes(vec![Err("fs.permission_denied"), Ok(())]);
    let push = |_: &Path, _: &Path, remote: &str| {
        seen.borrow_mut().push(remote.to_string());
        results.borrow_mut().remove(0).map_err(|code| (code.to_string(), "refused".to_string()))
    };
    let answer = copy.run(&path, &push);
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(answer["copied"], json!(true));
    assert_eq!(seen.borrow().len(), 2);
    assert!(seen.borrow()[1].starts_with("/root/work/chats/"));
    assert_eq!(answer["chat"], json!(copy.remote("/root/work").1));

    // Another failure stops at once, with its code (the App's outdated-machine retry reads it).
    let other = copy_of("/Users/me/src/paint", "");
    let (seen, results) = pushes(vec![Err("machine_outdated")]);
    let push = |_: &Path, _: &Path, remote: &str| {
        seen.borrow_mut().push(remote.to_string());
        results.borrow_mut().remove(0).map_err(|code| (code.to_string(), "old".to_string()))
    };
    let answer = other.run(&path, &push);
    assert_eq!(answer["ok"], json!(false));
    assert_eq!(answer["error_code"], json!("machine_outdated"));
    assert_eq!(seen.borrow().len(), 1);
}

/// A second push would overwrite what the chat changed on the machine since.
#[test]
fn a_retry_after_a_finished_copy_never_copies_again() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let copy = copy_of("/Users/me/src/paint", "sub");
    let count = RefCell::new(0);
    let push = |_: &Path, _: &Path, _: &str| {
        *count.borrow_mut() += 1;
        Ok(())
    };
    let first = copy.run(&path, &push);
    let retry = StartCopy { key: copy.key.to_lowercase(), ..copy.clone() }.run(&path, &push);
    assert_eq!(*count.borrow(), 1);
    assert_eq!(retry["copied"], json!(false));
    assert_eq!(retry["chat"], first["chat"]);
    // On another machine (the first is gone) it copies again.
    let elsewhere = StartCopy { machine: "vm-b".into(), ..copy }.run(&path, &push);
    assert_eq!(elsewhere["copied"], json!(true));
    assert_eq!(*count.borrow(), 2);
}

#[test]
fn copy_refuses_paths_that_could_escape() {
    let send = key();
    let flags = |extra: &[&str]| {
        let mut args: Vec<String> = [
            "--key",
            send.as_str(),
            "--machine",
            "vm-a",
            "--socket",
            "/s",
            "--work-root",
            "/home/cmux/work",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        args.extend(extra.iter().map(|s| s.to_string()));
        super::Flags::parse(&args).unwrap()
    };
    assert!(StartCopy::of(&flags(&["--local", "/Users/me/src/paint"])).is_some());
    assert!(StartCopy::of(&flags(&["--local", "relative"])).is_none());
    assert!(StartCopy::of(&flags(&["--local", "/"])).is_none());
    assert!(StartCopy::of(&flags(&["--local", "/a", "--subpath", "../etc"])).is_none());
    assert!(StartCopy::of(&flags(&["--local", "/a", "--work-root", "relative"])).is_none());
}
