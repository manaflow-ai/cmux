//! Ported from the App's CloudStartChatMachineTests and AgentPaneCloudStartTests
//! (cmux#28111), which these Rust tests replace.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::ledger::{LIMIT, Ledger, Send, WORKSPACE_LIMIT};
use super::pick::{self, Candidate, Destination};
use super::{Keys, StartCopy, import, pin, plan, remote_name, valid_key, valid_workspace};

const ME: &str = "user-leo";
const TEAMMATE: &str = "user-austin";
/// The account a send began in, as the App spells it: the user and the team.
const ACCOUNT: &str = "user-leo/team-a";

fn send(key: &str) -> Send {
    Send::new(key, ACCOUNT)
}

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

/// #28407: a machine with a pause, resume or delete on its way is never
/// taken, even marked for chats and still connected.
#[test]
fn a_changing_machine_is_skipped_even_when_marked_for_chats() {
    for status in ["pausing", "starting", "deleting"] {
        for connected in [true, false] {
            let changing = with(machine("vm-changing", "cloud-chats"), |m| {
                m.status = status.into();
                m.connected = connected;
            });
            let free = machine("vm-free", "spare");
            let both = [changing.clone(), free];
            assert_eq!(
                pick::pick(&both, Some(ME), &none()).as_deref(),
                Some("vm-free"),
                "{status}"
            );
            assert_eq!(pick::pick(&[changing], Some(ME), &none()), None, "{status}");
        }
    }
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
        pick::destination(&send(&key), ACCOUNT, None, &mut pins, &first, &[], Some(ME), true),
        Destination::Machine("vm-a".into())
    );
    pins.record("vm-a", &send(&key));
    let later = [machine("vm-b", "spare-b"), offline(machine("vm-a", "spare-a"), "running", None)];
    assert_eq!(
        pick::destination(&send(&key), ACCOUNT, None, &mut pins, &later, &[], Some(ME), true),
        Destination::Machine("vm-a".into())
    );
    assert_eq!(
        pick::destination(
            &send(&key.to_lowercase()),
            ACCOUNT,
            None,
            &mut pins,
            &later,
            &[],
            Some(ME),
            false
        ),
        Destination::Machine("vm-a".into())
    );
    assert_eq!(
        pick::destination(
            &send(&self::key()),
            ACCOUNT,
            None,
            &mut pins,
            &later,
            &[],
            Some(ME),
            true
        ),
        Destination::Machine("vm-b".into())
    );
}

#[test]
fn a_retry_whose_machine_is_gone_picks_afresh_and_a_retry_of_a_new_machine_stays_on_it() {
    let mut pins = Ledger::default();
    let key = key();
    pins.record("vm-gone", &send(&key));
    let now = [machine("vm-b", "spare-b")];
    assert_eq!(
        pick::destination(&send(&key), ACCOUNT, None, &mut pins, &now, &[], Some(ME), true),
        Destination::Machine("vm-b".into())
    );
    assert_eq!(pins.machine(&send(&key)), None);
    // A machine made for the first try (the list is not loaded yet) is kept for its retry.
    pins.record("vm-new", &send(&key));
    assert_eq!(
        pick::destination(&send(&key), ACCOUNT, None, &mut pins, &now, &[], Some(ME), false),
        Destination::Machine("vm-new".into())
    );
}

#[test]
fn the_ledger_survives_a_relaunch_and_keeps_only_the_newest() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let keys: Vec<String> = (0..=LIMIT).map(|_| key()).collect();
    for (index, key) in keys.iter().enumerate() {
        Ledger::update(&path, |pins| pins.record(&format!("vm-{index}"), &send(key))).unwrap();
    }
    let relaunched = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(relaunched.machine(&send(&keys[0])), None);
    assert_eq!(relaunched.machine(&send(&keys[1])).as_deref(), Some("vm-1"));
    assert_eq!(relaunched.machine(&send(keys.last().unwrap())), Some(format!("vm-{LIMIT}")));
    assert_eq!(relaunched.machines_of(ACCOUNT).len(), LIMIT);
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
        pins.record("vm-a", &send(&key));
        assert_eq!(pins.copied_chat(&send(&key), "vm-a"), None);
        pins.record_copy("/home/cmux/work/chats/k/paint", &send(&key), "vm-a", "chats/k");
        // Pinning the same machine again (the retry) keeps the finished copy.
        pins.record("vm-a", &send(&key));
    })
    .unwrap();
    Ledger::update(&path, |pins| {
        assert_eq!(
            pins.copied_chat(&send(&key.to_lowercase()), "vm-a").as_deref(),
            Some("/home/cmux/work/chats/k/paint")
        );
        assert_eq!(pins.copied_chat(&send(&key), "vm-b"), None);
        pins.record("vm-b", &send(&key));
        assert_eq!(pins.copied_chat(&send(&key), "vm-a"), None);
        assert_eq!(pins.copied_chat(&send(&key), "vm-b"), None);
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
    let request = json!({"key": key, "account": ACCOUNT, "user": ME, "loaded": true, "machines": [
        {"id": "vm-busy", "title": "cloud-chats-x", "created_by": ME, "status": "running", "connected": true, "chats": 2},
        {"id": "vm-other", "title": "cloud-chats", "created_by": TEAMMATE, "status": "running", "connected": true, "chats": 0},
    ]});
    let answer = plan(&path, &request.to_string());
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(answer["machine"], Value::Null);
    assert_eq!(answer["new_name"], json!("cloud-chats-2"));
    assert_eq!(answer["create_key"], json!(format!("cloud-start-chat-{}", key.to_lowercase())));
    // The App made vm-new for it and pinned it; the retry, before the list shows it, goes there.
    assert_eq!(pin(&path, &key, ACCOUNT, "vm-new", None)["ok"], json!(true));
    let retry = json!({"key": key.to_uppercase(), "account": ACCOUNT, "user": ME, "loaded": false, "machines": []});
    assert_eq!(plan(&path, &retry.to_string())["machine"], json!("vm-new"));

    let free = json!({"key": self::key(), "account": ACCOUNT, "user": ME, "loaded": true, "machines": [
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
    let place = copy.fresh_place();
    let send = format!("chats/{}/", copy.key.to_lowercase());
    assert!(place.starts_with(&send) && place.len() == send.len() + 8, "{place}");
    assert_ne!(copy.fresh_place(), place, "each copy gets a folder of its own");
    let (folder, chat) = copy.remote("/home/cmux/work", &place);
    assert_eq!(folder, format!("/home/cmux/work/{place}/paint-33f597"));
    assert_eq!(chat, format!("/home/cmux/work/{place}/paint-33f597/web/app"));
    let top = StartCopy { subpath: String::new(), ..copy };
    assert_eq!(top.remote("/root/work/", &place).1, format!("/root/work/{place}/paint-33f597"));
}

fn copy_of(local: &str, subpath: &str) -> StartCopy {
    StartCopy {
        key: key(),
        account: ACCOUNT.into(),
        machine: "vm-a".into(),
        socket: PathBuf::from("/tmp/machine.sock"),
        local: local.into(),
        subpath: subpath.into(),
        work_roots: vec!["/home/cmux/work".into(), "/root/work".into()],
    }
}

/// One push's outcome: Ok, or the error code it fails with.
type Outcome = Result<(), &'static str>;

/// A push that fails with a code per call, recording where it pushed.
fn pushes(results: Vec<Outcome>) -> (RefCell<Vec<String>>, RefCell<Vec<Outcome>>) {
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
    // Both roots were tried with the same folder of the send's own.
    let place = seen.borrow()[1].strip_prefix("/root/work/").unwrap().to_string();
    assert_eq!(seen.borrow()[0], format!("/home/cmux/work/{place}"));
    let place = place.strip_suffix("/paint-33f597").unwrap();
    assert_eq!(answer["chat"], json!(copy.remote("/root/work", place).1));

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
            "--account",
            ACCOUNT,
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

/// #28111: a team switch keeps the person signed in. A send of team A never
/// takes, or counts as the person's, team B's machine, and switching back
/// finds team A's pin again.
#[test]
fn a_send_is_kept_under_the_account_it_began_in() {
    const TEAM_B: &str = "user-leo/team-b";
    let mut pins = Ledger::default();
    let key = key();
    pins.record("vm-a", &send(&key));
    let in_b = Send::new(&key, TEAM_B);
    let listed = [machine("vm-a", "spare-a"), machine("vm-b", "spare-b")];
    assert_eq!(pins.machine(&in_b), None);
    assert_eq!(
        pick::destination(&in_b, TEAM_B, None, &mut pins, &listed[1..], &[], Some(ME), true),
        Destination::Machine("vm-b".into())
    );
    pins.record("vm-b", &in_b);
    assert_eq!(pins.machine(&send(&key)).as_deref(), Some("vm-a"));
    assert_eq!(pins.machine(&in_b).as_deref(), Some("vm-b"));

    // A machine the server names no creator for is the person's only through
    // this account's sends.
    let creatorless = [with(machine("vm-a", "spare-a"), |m| m.created_by = None)];
    assert_eq!(
        pick::destination(
            &send(&self::key()),
            ACCOUNT,
            None,
            &mut pins,
            &creatorless,
            &[],
            Some(ME),
            true
        ),
        Destination::Machine("vm-a".into())
    );
    assert_eq!(
        pick::destination(
            &Send::new(&self::key(), TEAM_B),
            TEAM_B,
            None,
            &mut pins,
            &creatorless,
            &[],
            Some(ME),
            true
        ),
        Destination::New
    );
    assert_eq!(pins.machines_of(TEAM_B), BTreeSet::from(["vm-b".to_string()]));
    assert_eq!(pins.machines_of(&ACCOUNT.to_uppercase()), BTreeSet::from(["vm-a".to_string()]));
}

/// A pin to a machine the App made since its list was read (in its store,
/// not listed yet) is kept; one in neither is gone, and the send picks afresh.
#[test]
fn a_pin_to_a_machine_made_since_the_list_was_read_is_kept() {
    let mut pins = Ledger::default();
    let key = key();
    pins.record("vm-new", &send(&key));
    let listed = [machine("vm-free", "spare")];
    let stored = ["vm-new".to_string()];
    assert_eq!(
        pick::destination(&send(&key), ACCOUNT, None, &mut pins, &listed, &stored, Some(ME), true),
        Destination::Machine("vm-new".into())
    );
    assert_eq!(
        pick::destination(&send(&key), ACCOUNT, None, &mut pins, &listed, &[], Some(ME), true),
        Destination::Machine("vm-free".into())
    );
    assert_eq!(pins.machine(&send(&key)), None);
}

#[test]
fn plan_and_pin_need_the_account_the_send_began_in() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let key = key();
    let machines = json!([
        {"id": "vm-free", "title": "spare", "created_by": ME, "status": "running", "connected": true, "chats": 0},
    ]);
    let request = |account: Value| {
        json!({"key": key, "account": account, "user": ME, "loaded": true, "machines": machines})
            .to_string()
    };
    assert_eq!(plan(&path, &request(json!(ACCOUNT)))["machine"], json!("vm-free"));
    // The same send in another team is another send.
    let other = plan(&path, &request(json!("user-leo/team-b")));
    assert_eq!(other["machine"], json!("vm-free"));
    let retry =
        json!({"key": key, "account": ACCOUNT, "user": ME, "loaded": false, "machines": []});
    assert_eq!(plan(&path, &retry.to_string())["machine"], json!("vm-free"));
    assert_eq!(plan(&path, &request(json!("user-leo/\u{7}")))["error_code"], json!("bad_request"));
    assert_eq!(plan(&path, &request(json!("x".repeat(513))))["error_code"], json!("bad_request"));
    let missing = json!({"key": key, "user": ME, "loaded": true, "machines": machines});
    assert_eq!(plan(&path, &missing.to_string())["error_code"], json!("bad_request"));
    assert_eq!(pin(&path, &key, "user-leo/team-b", "vm-made", None)["ok"], json!(true));
    let in_b =
        Ledger::update(&path, |pins| pins.machine(&Send::new(&key, "user-leo/team-b"))).unwrap();
    assert_eq!(in_b.as_deref(), Some("vm-made"));
}

/// SW-00 (#29046): a ledger that cannot be read never reads as empty, which
/// would make a retry pick and copy afresh. The send is refused and the file's
/// bytes are kept as they were.
#[test]
fn an_unreadable_ledger_refuses_the_send_and_keeps_its_bytes() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let copy = copy_of("/Users/me/src/paint", "");
    let pushed = RefCell::new(Vec::<String>::new());
    let push = |_: &Path, _: &Path, remote: &str| {
        pushed.borrow_mut().push(remote.to_string());
        Ok(())
    };
    assert_eq!(pin(&path, &copy.key, ACCOUNT, "vm-a", None)["ok"], json!(true));
    assert_eq!(copy.run(&path, &push)["copied"], json!(true));
    let whole = std::fs::read(&path).unwrap();
    let cut = &whole[..whole.len() / 2];
    std::fs::write(&path, cut).unwrap();

    let retry =
        json!({"key": copy.key, "account": ACCOUNT, "user": ME, "loaded": true, "machines": []});
    let answer = plan(&path, &retry.to_string());
    assert_eq!(answer["error_code"], json!("ledger_failed"), "{answer}");
    assert!(!path.exists(), "the unreadable ledger is moved aside, not written over");
    let aside: Vec<_> = std::fs::read_dir(path.parent().unwrap())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|kept| kept.to_string_lossy().contains(".unreadable-"))
        .collect();
    assert_eq!(aside.len(), 1, "{aside:?}");
    assert_eq!(std::fs::read(&aside[0]).unwrap(), cut);
    // Later sends start again; a copy then goes to a new folder, never over the first one.
    let again = copy.run(&path, &push);
    assert_eq!(again["copied"], json!(true));
    assert_eq!(pushed.borrow().len(), 2);
    assert_ne!(pushed.borrow()[0], pushed.borrow()[1]);

    // A ledger that cannot be read at all refuses and is left alone.
    let busy = scratch();
    let unreadable = ledger_in(busy.path());
    std::fs::create_dir_all(&unreadable).unwrap();
    assert_eq!(plan(&unreadable, &retry.to_string())["error_code"], json!("ledger_failed"));
    assert_eq!(
        pin(&unreadable, &copy.key, ACCOUNT, "vm-a", None)["error_code"],
        json!("ledger_failed")
    );
    assert!(unreadable.is_dir());
}

/// SW-00 (#29046): a push that finished on the machine but lost its answer
/// looks like one that never ran. Its retry, after a relaunch too, copies into
/// a new folder and never writes over the first one, which the chat may use.
#[test]
fn a_copy_whose_answer_was_lost_is_never_written_over() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let copy = copy_of("/Users/me/src/paint", "app");
    let (seen, results) = pushes(vec![Err("timeout"), Ok(())]);
    let push = |_: &Path, _: &Path, remote: &str| {
        seen.borrow_mut().push(remote.to_string());
        results.borrow_mut().remove(0).map_err(|code| (code.to_string(), "lost".to_string()))
    };
    assert_eq!(copy.run(&path, &push)["error_code"], json!("timeout"));
    let retry = StartCopy { key: copy.key.to_uppercase(), ..copy.clone() }.run(&path, &push);
    assert_eq!(retry["copied"], json!(true));
    let seen = seen.borrow();
    assert_eq!(seen.len(), 2);
    assert_ne!(seen[0], seen[1], "the retry wrote over the lost copy");
    assert_eq!(retry["folder"], json!(seen[1]));
    // Once finished, it is the send's copy: no third push.
    let count = RefCell::new(0);
    let never = |_: &Path, _: &Path, _: &str| {
        *count.borrow_mut() += 1;
        Ok(())
    };
    assert_eq!(copy.run(&path, &never)["chat"], retry["chat"]);
    assert_eq!(*count.borrow(), 0);
}

/// Two copies of one send at once (the CLI can be run twice) each get a folder
/// of their own: neither writes over the other.
#[test]
fn two_copies_of_one_send_at_once_never_share_a_folder() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let copy = copy_of("/Users/me/src/paint", "");
    let seen = RefCell::new(Vec::<String>::new());
    let inner = |_: &Path, _: &Path, remote: &str| {
        seen.borrow_mut().push(remote.to_string());
        Ok(())
    };
    let outer = |_: &Path, _: &Path, remote: &str| {
        // The second copy starts while the first one's push runs.
        assert_eq!(copy.run(&path, &inner)["copied"], json!(true));
        seen.borrow_mut().push(remote.to_string());
        Ok(())
    };
    assert_eq!(copy.run(&path, &outer)["copied"], json!(true));
    let seen = seen.borrow();
    assert_eq!(seen.len(), 2);
    assert_ne!(seen[0], seen[1]);
}

/// Router review at 83b8b35: the sends the App kept in its user defaults
/// before cmux-tui did carry over on upgrade. A send in flight keeps its
/// machine and its finished copy, and a creatorless machine stays the
/// account's own; a send kept under no account is left out.
#[test]
fn the_sends_the_app_kept_before_carry_over_once() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let (pinned, copied, newer) = (key(), key(), key());
    // As the App's `JSONEncoder` wrote `CloudStartChat.Destinations`, oldest first.
    let kept = json!([
        {"key": format!("{}@{ACCOUNT}", key()), "machineID": "vm-overwritten"},
        {"key": format!("{pinned}@{ACCOUNT}"), "machineID": "vm-pinned"},
        {"key": format!("{copied}@user-leo/team-b"), "machineID": "vm-b", "place": "chats/x/1", "copiedChat": "/w/chats/x/1/paint"},
        {"key": newer, "machineID": "vm-no-account"},
        {"key": format!("{newer}@{ACCOUNT}"), "machineID": "vm-old-try"},
    ]);
    assert_eq!(pin(&path, &newer, ACCOUNT, "vm-newer", None)["ok"], json!(true));
    let answer = import(&path, &kept.to_string());
    assert_eq!(answer["imported"], json!(3), "{answer}");
    let ledger = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(ledger.machine(&send(&pinned)).as_deref(), Some("vm-pinned"));
    // This ledger's own entry for a send wins over the App's older one.
    assert_eq!(ledger.machine(&send(&newer)).as_deref(), Some("vm-newer"));
    let in_b = Send::new(&copied, "user-leo/team-b");
    assert_eq!(ledger.copied_chat(&in_b, "vm-b").as_deref(), Some("/w/chats/x/1/paint"));
    assert!(ledger.machines_of(ACCOUNT).contains("vm-pinned"));
    assert!(!ledger.machines_of(ACCOUNT).contains("vm-no-account"));
    assert!(!ledger.machines_of(ACCOUNT).contains("vm-b"));
    // The retry of the pinned send goes back to its machine; the copied one does not copy again.
    let retry =
        json!({"key": pinned, "account": ACCOUNT, "user": ME, "loaded": false, "machines": []});
    assert_eq!(plan(&path, &retry.to_string())["machine"], json!("vm-pinned"));
    let copy = StartCopy {
        key: copied,
        account: "user-leo/team-b".into(),
        machine: "vm-b".into(),
        ..copy_of("/a", "")
    };
    let never =
        |_: &Path, _: &Path, _: &str| -> Result<(), (String, String)> { panic!("copied again") };
    assert_eq!(copy.run(&path, &never)["copied"], json!(false));
    // Taking the same list in again changes nothing; one that is not a list is refused.
    assert_eq!(import(&path, &kept.to_string())["imported"], json!(0));
    assert_eq!(import(&path, "{")["error_code"], json!("bad_request"));
}

/// Leo, 2026-10-30: "we'll want a vm for every single workspace". A Mac
/// workspace's first send to Cloud makes a machine that is its own from then
/// on; no other workspace, and no send from no workspace, shares it.
#[test]
fn each_workspace_gets_its_own_machine_and_keeps_it() {
    let mut pins = Ledger::default();
    let shared = [machine("vm-free", "spare"), machine("vm-chats", "cloud-chats")];
    let first = key();
    let to = |pins: &mut Ledger,
              key: &str,
              workspace: Option<&str>,
              listed: &[Candidate],
              loaded: bool| {
        pick::destination(&send(key), ACCOUNT, workspace, pins, listed, &[], Some(ME), loaded)
    };
    assert_eq!(to(&mut pins, &first, Some("ws-a"), &shared, true), Destination::New);
    // The App made vm-a for it and pinned it (`pin --workspace`).
    pins.record("vm-a", &send(&first));
    pins.bind("ws-a", ACCOUNT, "vm-a");
    let listed = [
        machine("vm-free", "spare"),
        with(machine("vm-a", "cloud-chats-2"), |m| m.chats = Some(2)),
    ];
    // Its next send, busy with chats or not, goes back to it.
    assert_eq!(
        to(&mut pins, &key(), Some("ws-a"), &listed, true),
        Destination::Machine("vm-a".into())
    );
    // Paused (by a person or the idle timer), it resumes there.
    let paused = [offline(machine("vm-a", "cloud-chats-2"), "paused", Some("user"))];
    assert_eq!(
        to(&mut pins, &key(), Some("ws-a"), &paused, true),
        Destination::Machine("vm-a".into())
    );
    // Another workspace never shares it, nor the free one.
    assert_eq!(to(&mut pins, &key(), Some("ws-b"), &listed, true), Destination::New);
    // Before the App's list is loaded, the workspace's machine is kept.
    assert_eq!(
        to(&mut pins, &key(), Some("ws-a"), &[], false),
        Destination::Machine("vm-a".into())
    );
    // A send from no workspace keeps the shared pick, but never takes a workspace's own machine,
    // even one marked for chats.
    assert_eq!(to(&mut pins, &key(), None, &listed, true), Destination::Machine("vm-free".into()));
    assert_eq!(to(&mut pins, &key(), None, &listed[1..], true), Destination::New);
    // In another team the workspace has no machine yet.
    assert_eq!(
        pick::destination(
            &Send::new(&key(), "user-leo/team-b"),
            "user-leo/team-b",
            Some("ws-a"),
            &mut pins,
            &listed,
            &[],
            Some(ME),
            true
        ),
        Destination::New
    );
    assert_eq!(pins.workspace_machine("ws-a", ACCOUNT).as_deref(), Some("vm-a"));
}

#[test]
fn a_workspaces_gone_teammates_or_failed_machine_is_replaced_by_a_new_one() {
    for gone in [
        vec![machine("vm-other", "spare")],
        vec![with(machine("vm-a", "cloud-chats-2"), |m| m.created_by = Some(TEAMMATE.into()))],
        vec![offline(machine("vm-a", "cloud-chats-2"), "failed", None)],
        // A stale link still reads as connected; the server's status says it is gone.
        vec![with(machine("vm-a", "cloud-chats-2"), |m| m.status = "failed".into())],
        vec![with(machine("vm-a", "cloud-chats-2"), |m| m.status = "deleting".into())],
    ] {
        let mut pins = Ledger::default();
        pins.bind("ws-a", ACCOUNT, "vm-a");
        assert_eq!(
            pick::destination(
                &send(&key()),
                ACCOUNT,
                Some("ws-a"),
                &mut pins,
                &gone,
                &[],
                Some(ME),
                true
            ),
            Destination::New,
            "{gone:?}"
        );
        assert_eq!(pins.workspace_machine("ws-a", ACCOUNT), None, "{gone:?}");
    }
    // Signed out, a workspace's machine is not taken either.
    let mut pins = Ledger::default();
    pins.bind("ws-a", ACCOUNT, "vm-a");
    assert_eq!(
        pick::destination(
            &send(&key()),
            ACCOUNT,
            Some("ws-a"),
            &mut pins,
            &[machine("vm-a", "x")],
            &[],
            None,
            true
        ),
        Destination::New
    );
    // One the App made since its list was read is kept.
    let mut pins = Ledger::default();
    pins.bind("ws-a", ACCOUNT, "vm-new");
    assert_eq!(
        pick::destination(
            &send(&key()),
            ACCOUNT,
            Some("ws-a"),
            &mut pins,
            &[],
            &["vm-new".into()],
            Some(ME),
            true
        ),
        Destination::Machine("vm-new".into())
    );
}

#[test]
fn a_retry_stays_on_its_first_trys_machine_even_after_its_workspace_moved_on() {
    let mut pins = Ledger::default();
    let first = key();
    pins.record("vm-a", &send(&first));
    pins.bind("ws-a", ACCOUNT, "vm-b");
    let listed = [machine("vm-a", "a"), machine("vm-b", "b")];
    assert_eq!(
        pick::destination(
            &send(&first),
            ACCOUNT,
            Some("ws-a"),
            &mut pins,
            &listed,
            &[],
            Some(ME),
            true
        ),
        Destination::Machine("vm-a".into())
    );
}

#[test]
fn plan_and_pin_keep_each_workspaces_machine_across_a_relaunch() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let first = key();
    let request = |key: &str, workspace: &str, machines: &Value| {
        json!({"key": key, "account": ACCOUNT, "workspace": workspace, "user": ME, "loaded": true, "machines": machines})
            .to_string()
    };
    let shared = json!([
        {"id": "vm-free", "title": "spare", "created_by": ME, "status": "running", "connected": true, "chats": 0},
    ]);
    let answer = plan(&path, &request(&first, "ws-a", &shared));
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(answer["machine"], Value::Null, "{answer}");
    assert_eq!(pin(&path, &first, ACCOUNT, "vm-a", Some("ws-a"))["ok"], json!(true));

    let listed = json!([
        {"id": "vm-free", "title": "spare", "created_by": ME, "status": "running", "connected": true, "chats": 0},
        {"id": "vm-a", "title": "cloud-chats", "created_by": ME, "status": "running", "connected": true, "chats": 1},
    ]);
    assert_eq!(plan(&path, &request(&key(), "ws-a", &listed))["machine"], json!("vm-a"));
    assert_eq!(plan(&path, &request(&key(), "ws-b", &listed))["machine"], Value::Null);
    // A retry of the first send stays on vm-a, but never takes ws-a back from the machine
    // that replaced it.
    assert_eq!(pin(&path, &key(), ACCOUNT, "vm-c", Some("ws-a"))["ok"], json!(true));
    assert_eq!(plan(&path, &request(&first, "ws-a", &listed))["machine"], json!("vm-a"));
    let kept = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(kept.workspace_machine("ws-a", ACCOUNT).as_deref(), Some("vm-c"));

    // A ledger written before workspaces (the sends' list alone) still reads.
    let older = scratch();
    let older_path = ledger_in(older.path());
    std::fs::create_dir_all(older_path.parent().unwrap()).unwrap();
    let pinned = key();
    std::fs::write(
        &older_path,
        json!([{"key": pinned.to_lowercase(), "account": ACCOUNT, "machine_id": "vm-old"}])
            .to_string(),
    )
    .unwrap();
    let retry = json!({"key": pinned, "account": ACCOUNT, "workspace": "ws-a", "user": ME, "loaded": false, "machines": []});
    assert_eq!(plan(&older_path, &retry.to_string())["machine"], json!("vm-old"));
    let relaunched = Ledger::update(&older_path, |pins| pins.clone()).unwrap();
    assert_eq!(relaunched.workspace_machine("ws-a", ACCOUNT).as_deref(), Some("vm-old"));

    for bad in ["", &"w".repeat(129), "ws\u{0}a"] {
        assert!(!valid_workspace(bad));
        assert_eq!(
            plan(&path, &request(&key(), bad, &json!([])))["error_code"],
            json!("bad_request")
        );
    }
}

#[test]
fn the_ledger_keeps_the_newest_workspaces_apart_from_the_sends() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    Ledger::update(&path, |pins| {
        pins.bind("ws-first", ACCOUNT, "vm-first");
        for index in 0..=LIMIT {
            pins.record(&format!("vm-{index}"), &send(&key()));
        }
    })
    .unwrap();
    // Many sends later, the workspace still has its machine.
    let kept = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(kept.workspace_machine("ws-first", ACCOUNT).as_deref(), Some("vm-first"));
    Ledger::update(&path, |pins| {
        for index in 0..WORKSPACE_LIMIT {
            pins.bind(&format!("ws-{index}"), ACCOUNT, &format!("vm-ws-{index}"));
        }
    })
    .unwrap();
    let kept = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(kept.workspace_machine("ws-first", ACCOUNT), None);
    assert_eq!(kept.workspace_machine("ws-0", ACCOUNT).as_deref(), Some("vm-ws-0"));
}
