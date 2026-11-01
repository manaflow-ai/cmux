//! Ported from the App's CloudStartChatMachineTests and AgentPaneCloudStartTests
//! (cmux#28111), which these Rust tests replace.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::ledger::{LIMIT, Ledger, Send, WORKSPACE_LIMIT};
use super::pick::{self, Candidate, Destination};
use super::{
    Ensure, Flags, Keys, Lease, StartCopy, ensure_answer, github_repo, import, origin_url,
    percent_segment, pin, plan, remote_name, too_broad, valid_environment, valid_key, valid_repo,
    valid_workspace,
};

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
        ..Candidate::default()
    }
}

fn with(mut candidate: Candidate, change: impl FnOnce(&mut Candidate)) -> Candidate {
    change(&mut candidate);
    candidate
}

fn offline(candidate: Candidate, status: &str) -> Candidate {
    with(candidate, |machine| {
        machine.connected = false;
        machine.status = status.into();
    })
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

/// Leo, 2026-10-31: "1 workspace per vm for now". No machine the App lists is
/// ever reused for a send from no workspace or a workspace with none yet:
/// not a teammate's, not this person's free one or one named for chats, not
/// one paused by the idle timer, not a lane VM.
#[test]
fn a_free_machine_of_mine_is_not_reused_for_a_new_workspace() {
    let listed = [
        machine("vm-free", "spare"),
        machine("vm-chats", "cloud-chats"),
        offline(machine("vm-idle", "spare-2"), "paused"),
        machine("vm-lane", "fs-lane-3"),
        machine("vm-probe", "sr2-tunnel-probe"),
        with(machine("vm-nobody", "spare-3"), |m| m.created_by = None),
        with(machine("vm-team", "austin-box"), |m| m.created_by = Some(TEAMMATE.into())),
    ];
    let used = BTreeSet::from(["vm-free".to_string()]);
    let mut pins = Ledger::default();
    pins.record("vm-free", &send(&key()));
    assert_eq!(pins.machines_of(ACCOUNT), used);
    for workspace in [None, Some("ws-new")] {
        assert_eq!(
            pick::destination(
                &send(&key()),
                ACCOUNT,
                workspace,
                &mut pins,
                &listed,
                &[],
                Some(ME),
                true
            ),
            Destination::New,
            "{workspace:?}"
        );
    }
    assert_eq!(pins.workspace_machine("ws-new", ACCOUNT), None);
}

#[test]
fn fleet_vms_are_marked_by_tag_or_name() {
    // Leo's first Cloud send (2026-10-31) opened on sr2-tunnel-probe, a probe VM fleet tooling made
    // under his account (#29959). Such a machine is never a workspace's (see the dropped test below).
    for name in [
        "sr2-tunnel-probe",
        "fs-peer-1",
        "fs-lane-3",
        "fs-firstsend-exercise",
        "SR2-x",
        "lane-vm-2",
    ] {
        assert!(pick::is_fleet(&machine("vm-fleet", name)), "{name}");
    }
    let slugged = with(machine("vm-4", "Leo's box"), |m| m.slug = Some("fs-lane-7".into()));
    assert!(pick::is_fleet(&slugged));
    for tag in ["fleet", "Infra"] {
        let tagged =
            with(machine("vm-tagged", "kind-aqua-sandpiper"), |m| m.tags = vec![tag.into()]);
        assert!(pick::is_fleet(&tagged), "{tag}");
    }
    // Names that merely contain the words are not fleet ones.
    for name in ["my-fs-notes", "leo-cloud", "cloud-chats", "fsharp-box"] {
        assert!(!pick::is_fleet(&machine("vm-x", name)), "{name}");
    }
    assert!(!pick::is_lane_pool("fs-lane-notes"));
    assert!(!pick::is_lane_pool("lane-vm-"));
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
        Destination::New
    );
    // The App made vm-a for it and pinned it.
    pins.record("vm-a", &send(&key));
    let later = [machine("vm-b", "spare-b"), offline(machine("vm-a", "spare-a"), "running")];
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
        Destination::New
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
        Destination::New
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

    // A free machine of the person's is not reused: each send from no workspace gets its own.
    let free = json!({"key": self::key(), "account": ACCOUNT, "user": ME, "loaded": true, "machines": [
        {"id": "vm-free", "title": "spare", "created_by": ME, "status": "running", "connected": true, "chats": 0},
    ]});
    let answer = plan(&path, &free.to_string());
    assert_eq!(answer["machine"], Value::Null, "{answer}");
    assert_eq!(answer["new_name"], json!("cloud-chats"));
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
        Flags::parse(&args).unwrap()
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
        Destination::New
    );
    pins.record("vm-b", &in_b);
    assert_eq!(pins.machine(&send(&key)).as_deref(), Some("vm-a"));
    assert_eq!(pins.machine(&in_b).as_deref(), Some("vm-b"));

    // A machine the server names no creator for is the person's only through
    // this account's sends: a workspace keeps it in this account, not in another.
    let creatorless = [with(machine("vm-a", "spare-a"), |m| m.created_by = None)];
    pins.bind("ws-a", ACCOUNT, "vm-a");
    assert_eq!(
        pick::destination(
            &send(&self::key()),
            ACCOUNT,
            Some("ws-a"),
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
    assert_eq!(pins.workspace_machine("ws-a", TEAM_B), None);
    assert_eq!(pins.machines_of(&ACCOUNT.to_uppercase()), BTreeSet::from(["vm-a".to_string()]));
}

/// A pin to a machine the App made since its list was read (in its store,
/// not listed yet) is kept; one in neither is gone, and the send gets a new one.
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
        Destination::New
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
    assert_eq!(plan(&path, &request(json!(ACCOUNT)))["machine"], Value::Null);
    assert_eq!(pin(&path, &key, ACCOUNT, "vm-free", None)["ok"], json!(true));
    // The same send in another team is another send: its pin is not this one's.
    let other = plan(&path, &request(json!("user-leo/team-b")));
    assert_eq!(other["machine"], Value::Null, "{other}");
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

/// A copy that did not finish (cut off, or its answer lost: SW-00, #29046)
/// is resumed by its retry, after a relaunch too: the retry pushes into the
/// same folder, where the push's saved record skips what already landed. No
/// chat opened there yet (a chat opens only once its copy finished), so
/// nothing a chat changed is written over.
#[test]
fn a_retry_of_a_copy_that_did_not_finish_resumes_its_folder() {
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
    assert_eq!(seen[0], seen[1], "the retry started over in a new folder");
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

/// A retry finds its unfinished copy's folder held by a copy still running
/// (another process): it takes a folder of its own; once that copy is gone
/// (its process ended), the next retry resumes the folder.
#[test]
fn a_retry_resumes_its_folder_only_when_no_live_copy_holds_it() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let copy = copy_of("/Users/me/src/paint", "");
    let seen = RefCell::new(Vec::<String>::new());
    let fails = |_: &Path, _: &Path, remote: &str| {
        seen.borrow_mut().push(remote.to_string());
        Err(("fs.failure".to_string(), "cut off".to_string()))
    };
    assert_eq!(copy.run(&path, &fails)["error_code"], json!("fs.failure"));
    let place =
        Ledger::update(&path, |pins| pins.copy_place(&send(&copy.key), "vm-a")).unwrap().unwrap();
    // A live copy holds it (its lease, as another process would).
    let held = Lease::take(&path, &send(&copy.key), "vm-a", &place).unwrap();
    assert!(Lease::take(&path, &send(&copy.key), "vm-a", &place).is_none());
    assert_eq!(copy.run(&path, &fails)["error_code"], json!("fs.failure"));
    drop(held);
    let ok = |_: &Path, _: &Path, remote: &str| {
        seen.borrow_mut().push(remote.to_string());
        Ok(())
    };
    let done = copy.run(&path, &ok);
    assert_eq!(done["copied"], json!(true), "{done}");
    let seen = seen.borrow();
    assert_eq!(seen.len(), 3);
    assert_ne!(seen[1], seen[0], "a live copy's folder was shared");
    // The second try's folder was left by a copy now gone, so the third
    // resumes that one (the newest unfinished copy).
    assert_eq!(seen[2], seen[1]);
}

/// The disk's root, the system's top folders and the home folder itself are
/// never copied; a project below one is.
#[test]
fn a_copy_of_the_root_a_system_folder_or_home_is_refused() {
    let home = Path::new("/Users/me");
    for broad in [
        "/",
        "/System",
        "/Library",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin",
        "/private",
        "/etc",
        "/var",
        "/Volumes",
        "/Volumes/",
        "/Users/me",
        "/Users/me/",
    ] {
        assert!(too_broad(broad, Some(home)), "{broad}");
    }
    for project in ["/Users/me/src/paint", "/Volumes/ssd/paint", "/usr/local/src/app", "/opt/proj"]
    {
        assert!(!too_broad(project, Some(home)), "{project}");
    }
    let dir = scratch();
    let path = ledger_in(dir.path());
    let never = |_: &Path, _: &Path, _: &str| -> Result<(), (String, String)> { panic!("copied") };
    let answer = copy_of("/System", "").run(&path, &never);
    assert_eq!(answer["error_code"], json!("folder_too_broad"), "{answer}");
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

/// Leo, 2026-10-31: "austin/lawrence said indeed we wanted 1 workspace per vm
/// for now / i guess they're relatively smol vms". A Mac workspace's first
/// send makes a new machine and keeps it from then on, busy, paused or not
/// yet listed; two workspaces get two machines.
#[test]
fn each_workspace_gets_a_new_machine_and_keeps_it() {
    let mut pins = Ledger::default();
    let to = |pins: &mut Ledger, workspace: Option<&str>, listed: &[Candidate], loaded: bool| {
        pick::destination(&send(&key()), ACCOUNT, workspace, pins, listed, &[], Some(ME), loaded)
    };
    assert_eq!(to(&mut pins, Some("ws-a"), &[], true), Destination::New);
    // The App made vm-a and pinned it to the workspace (`pin --workspace`).
    assert!(pick::claim(&mut pins, "ws-a", ACCOUNT, "vm-a"));
    let listed = [machine("vm-a", "cloud-chats"), machine("vm-free", "spare")];
    // A second workspace gets a new machine too, never ws-a's or the free one.
    assert_eq!(to(&mut pins, Some("ws-b"), &listed, true), Destination::New);
    assert!(pick::claim(&mut pins, "ws-b", ACCOUNT, "vm-b"));
    let listed = [listed[0].clone(), listed[1].clone(), machine("vm-b", "cloud-chats-2")];
    assert_eq!(to(&mut pins, Some("ws-a"), &listed, true), Destination::Machine("vm-a".into()));
    assert_eq!(to(&mut pins, Some("ws-b"), &listed, true), Destination::Machine("vm-b".into()));
    // Paused (by a person or the idle timer), it resumes there.
    let paused = [offline(machine("vm-a", "cloud-chats"), "paused")];
    assert_eq!(to(&mut pins, Some("ws-a"), &paused, true), Destination::Machine("vm-a".into()));
    // Before the App's list is loaded, the workspace's machine is kept.
    assert_eq!(to(&mut pins, Some("ws-a"), &[], false), Destination::Machine("vm-a".into()));
    // A send from no workspace takes neither.
    assert_eq!(to(&mut pins, None, &listed, true), Destination::New);
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
    assert_eq!(pins.workspace_machine("ws-b", ACCOUNT).as_deref(), Some("vm-b"));
}

/// A machine one workspace has is never given to another: not by a plan, and
/// not by a pin (a send of workspace B pinned to A's machine runs there, but
/// the machine stays A's alone).
#[test]
fn a_machine_bound_to_one_workspace_is_not_taken_by_another() {
    let mut pins = Ledger::default();
    assert!(pick::claim(&mut pins, "ws-a", ACCOUNT, "vm-a"));
    let listed = [machine("vm-a", "cloud-chats")];
    assert_eq!(
        pick::destination(
            &send(&key()),
            ACCOUNT,
            Some("ws-b"),
            &mut pins,
            &listed,
            &[],
            Some(ME),
            true
        ),
        Destination::New
    );
    assert!(!pick::claim(&mut pins, "ws-b", ACCOUNT, "vm-a"));
    assert_eq!(pins.workspace_machine("ws-b", ACCOUNT), None);
    // The same workspace may claim it again; another account's workspace of that id is apart.
    assert!(pick::claim(&mut pins, "ws-a", ACCOUNT, "vm-a"));
    assert!(pick::claim(&mut pins, "ws-b", "user-leo/team-b", "vm-a"));

    let dir = scratch();
    let path = ledger_in(dir.path());
    let first = key();
    assert_eq!(pin(&path, &first, ACCOUNT, "vm-a", Some("ws-a"))["ok"], json!(true));
    // A retry of ws-a's send from ws-b stays on vm-a, but ws-b does not get it.
    let retry = json!({"key": first, "account": ACCOUNT, "workspace": "ws-b", "user": ME, "loaded": false, "machines": []});
    assert_eq!(plan(&path, &retry.to_string())["machine"], json!("vm-a"));
    assert_eq!(pin(&path, &key(), ACCOUNT, "vm-a", Some("ws-b"))["ok"], json!(true));
    let kept = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(kept.workspace_machine("ws-a", ACCOUNT).as_deref(), Some("vm-a"));
    assert_eq!(kept.workspace_machine("ws-b", ACCOUNT), None);
}

#[test]
fn a_workspaces_gone_teammates_or_failed_machine_is_dropped_for_a_new_one() {
    for gone in [
        vec![machine("vm-other", "spare")],
        vec![with(machine("vm-a", "cloud-chats-2"), |m| m.created_by = Some(TEAMMATE.into()))],
        vec![offline(machine("vm-a", "cloud-chats-2"), "failed")],
        // A stale link still reads as connected; the server's status says it is gone.
        vec![with(machine("vm-a", "cloud-chats-2"), |m| m.status = "failed".into())],
        vec![with(machine("vm-a", "cloud-chats-2"), |m| m.status = "deleting".into())],
        // A fleet VM under the person's own account (Leo's sr2-tunnel-probe) is no workspace's.
        vec![machine("vm-a", "sr2-tunnel-probe")],
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
    // With its machine gone, the workspace gets a new one, never another of the person's.
    let mut pins = Ledger::default();
    pins.bind("ws-a", ACCOUNT, "vm-a");
    let other = [offline(machine("vm-a", "cloud-chats-2"), "failed"), machine("vm-free", "spare")];
    assert_eq!(
        pick::destination(
            &send(&key()),
            ACCOUNT,
            Some("ws-a"),
            &mut pins,
            &other,
            &[],
            Some(ME),
            true
        ),
        Destination::New
    );
    // #28407's shown status: a workspace's machine that is pausing or resuming,
    // its link down meanwhile, stays the workspace's own.
    for status in ["pausing", "starting"] {
        let mut pins = Ledger::default();
        pins.bind("ws-a", ACCOUNT, "vm-a");
        let changing = [offline(machine("vm-a", "cloud-chats-2"), status)];
        assert_eq!(
            pick::destination(
                &send(&key()),
                ACCOUNT,
                Some("ws-a"),
                &mut pins,
                &changing,
                &[],
                Some(ME),
                true
            ),
            Destination::Machine("vm-a".into()),
            "{status}"
        );
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
    let busy = json!([
        {"id": "vm-busy", "title": "spare", "created_by": ME, "status": "running", "connected": true, "chats": 1},
    ]);
    let answer = plan(&path, &request(&first, "ws-a", &busy));
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(answer["machine"], Value::Null, "{answer}");
    assert_eq!(pin(&path, &first, ACCOUNT, "vm-a", Some("ws-a"))["ok"], json!(true));

    let listed = json!([
        {"id": "vm-free", "title": "spare", "created_by": ME, "status": "running", "connected": true, "chats": 0},
        {"id": "vm-a", "title": "cloud-chats", "created_by": ME, "status": "running", "connected": true, "chats": 1},
    ]);
    assert_eq!(plan(&path, &request(&key(), "ws-a", &listed))["machine"], json!("vm-a"));
    // Another workspace gets a machine of its own, not vm-a or the free one.
    let second = key();
    assert_eq!(plan(&path, &request(&second, "ws-b", &listed))["machine"], Value::Null);
    assert_eq!(pin(&path, &second, ACCOUNT, "vm-b", Some("ws-b"))["ok"], json!(true));
    let relaunched = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(relaunched.workspace_machine("ws-a", ACCOUNT).as_deref(), Some("vm-a"));
    assert_eq!(relaunched.workspace_machine("ws-b", ACCOUNT).as_deref(), Some("vm-b"));
    // Router review at 6b62dda: two first sends of one workspace that both planned a new
    // machine race to pin; the first pin wins and the later machine keeps only its send.
    let racing = key();
    assert_eq!(pin(&path, &racing, ACCOUNT, "vm-race", Some("ws-a"))["ok"], json!(true));
    let raced = Ledger::update(&path, |pins| pins.clone()).unwrap();
    assert_eq!(raced.workspace_machine("ws-a", ACCOUNT).as_deref(), Some("vm-a"));
    assert_eq!(raced.machine(&send(&racing)).as_deref(), Some("vm-race"));
    // vm-a fails: ws-a's next send gets a new machine, vm-c, which becomes its own. A retry
    // of the first send then stays on vm-a (still listed) but never takes ws-a back.
    let failed = json!([
        {"id": "vm-a", "title": "cloud-chats", "created_by": ME, "status": "failed", "connected": false},
    ]);
    let third = key();
    assert_eq!(plan(&path, &request(&third, "ws-a", &failed))["machine"], Value::Null);
    assert_eq!(pin(&path, &third, ACCOUNT, "vm-c", Some("ws-a"))["ok"], json!(true));
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

const ENV: &str = "env_0123456789abcdef01234567";

#[test]
fn the_folders_github_remote_is_the_repo() {
    for url in [
        "https://github.com/manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai/cmux",
        "https://github.com/manaflow-ai/cmux/",
        "git@github.com:manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux.git",
        "https://user@GitHub.com/manaflow-ai/cmux",
        "HTTPS://github.com/manaflow-ai/cmux.git",
        "github.com:manaflow-ai/cmux",
    ] {
        assert_eq!(github_repo(url).as_deref(), Some("manaflow-ai/cmux"), "{url}");
    }
    for url in [
        "https://gitlab.com/manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai",
        "https://github.com/a/b/c",
        "https://github.com/../x",
        "/srv/git/cmux.git",
        "https://github.com.evil.example/a/b",
        "git@gitlab.com:a/b.git",
        "",
    ] {
        assert_eq!(github_repo(url), None, "{url}");
    }
    assert!(valid_repo("a.b/c_d-e"));
    assert!(!valid_repo(&format!("o/{}", "n".repeat(140))));
    assert!(valid_environment(ENV));
    for bad in ["env_0123", "env_0123456789ABCDEF01234567", "abc_0123456789abcdef01234567"] {
        assert!(!valid_environment(bad), "{bad}");
    }
}

#[test]
fn plan_answers_the_folders_repo_and_echoes_the_environment() {
    let dir = scratch();
    let path = ledger_in(dir.path());
    let folder = dir.path().join("project");
    let sub = folder.join("web");
    std::fs::create_dir_all(folder.join(".git")).unwrap();
    std::fs::create_dir_all(&sub).unwrap();
    std::fs::write(folder.join(".git/config"), "[core]\n\tbare = false\n").unwrap();
    let request = |environment: Value| {
        json!({"key": key(), "account": ACCOUNT, "user": ME, "loaded": true, "machines": [],
               "local": folder.to_str().unwrap(), "environment": environment})
        .to_string()
    };
    // No origin: no repo, and the send still plans.
    let answer = plan(&path, &request(Value::Null));
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert_eq!(answer["repo"], Value::Null);
    assert_eq!(answer["environment"], Value::Null);
    std::fs::write(
        folder.join(".git/config"),
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:manaflow-ai/cmux.git\n",
    )
    .unwrap();
    let answer = plan(&path, &request(json!(ENV)));
    assert_eq!(answer["repo"], json!("manaflow-ai/cmux"), "{answer}");
    assert_eq!(answer["environment"], json!(ENV));
    assert_eq!(plan(&path, &request(json!("env_nope")))["error_code"], json!("bad_request"));
    // A subfolder of the repository, and a worktree whose `.git` file points at it, answer its repo.
    let in_sub =
        json!({"key": key(), "account": ACCOUNT, "local": sub.to_str().unwrap()}).to_string();
    assert_eq!(plan(&path, &in_sub)["repo"], json!("manaflow-ai/cmux"));
    let worktree = dir.path().join("wt");
    std::fs::create_dir_all(folder.join(".git/worktrees/wt")).unwrap();
    std::fs::create_dir_all(&worktree).unwrap();
    std::fs::write(folder.join(".git/worktrees/wt/commondir"), "../..\n").unwrap();
    std::fs::write(
        worktree.join(".git"),
        format!("gitdir: {}\n", folder.join(".git/worktrees/wt").display()),
    )
    .unwrap();
    let in_worktree =
        json!({"key": key(), "account": ACCOUNT, "local": worktree.to_str().unwrap()}).to_string();
    assert_eq!(plan(&path, &in_worktree)["repo"], json!("manaflow-ai/cmux"));
    // A folder that is not there, an empty one and a relative one answer no repo.
    for local in ["/nonexistent/cmux-test", "", "project"] {
        let request = json!({"key": key(), "account": ACCOUNT, "local": local}).to_string();
        assert_eq!(plan(&path, &request)["repo"], Value::Null, "{local:?}");
    }
    let config = "[remote \"upstream\"]\n url = a\n[Remote \"origin\"]\n URL = \"b\"\n[branch \"main\"]\n url = c\n";
    assert_eq!(origin_url(config), Some("b".into()));
    assert_eq!(origin_url("[remote \"upstream\"]\n url = a\n"), None);
}

fn flags(args: &[&str]) -> Flags {
    Flags::parse(&args.iter().map(|arg| arg.to_string()).collect::<Vec<_>>()).expect("flags")
}

#[test]
fn ensure_asks_for_the_workspaces_machine_under_the_plans_create_key() {
    let key = key();
    let ensure = Ensure::of(&flags(&[
        "--workspace",
        "ws-1",
        "--key",
        &key,
        "--repo",
        "manaflow-ai/cmux",
        "--environment",
        ENV,
    ]))
    .expect("ensure");
    assert_eq!(
        ensure.body(),
        json!({"clientKey": Keys::of(&key).create, "repo": "manaflow-ai/cmux", "environment": ENV})
    );
    let with_ref = Ensure::of(&flags(&[
        "--workspace",
        "ws-1",
        "--key",
        &key,
        "--repo",
        "a/b",
        "--ref",
        "main",
    ]))
    .unwrap();
    assert_eq!(
        with_ref.body(),
        json!({"clientKey": Keys::of(&key).create, "repo": "a/b", "ref": "main"})
    );
    for bad in [
        vec!["--key", key.as_str(), "--repo", "a/b"],
        vec!["--workspace", "ws-1", "--repo", "a/b"],
        vec!["--workspace", "ws-1", "--key", key.as_str()],
        vec!["--workspace", "ws-1", "--key", key.as_str(), "--repo", "not-a-repo"],
        vec![
            "--workspace",
            "ws-1",
            "--key",
            key.as_str(),
            "--repo",
            "a/b",
            "--environment",
            "env_x",
        ],
        vec!["--workspace", "ws-1", "--key", key.as_str(), "--repo", "a/b", "--ref", ""],
    ] {
        assert!(Ensure::of(&flags(&bad)).is_none(), "{bad:?}");
    }
    assert_eq!(percent_segment("ws 1/ä"), "ws%201%2F%C3%A4");
}

#[test]
fn ensures_line_names_the_machine_or_the_platforms_code() {
    use crate::cli::PlatformCallError as E;
    let made = ensure_answer(Ok(json!({
        "workspace": "ws-1", "machine": {"id": "vm-1", "provider": "freestyle"}, "team": "team_p",
        "snapshot": "snap_x", "environment": {"id": "denv_1", "status": "ready"}, "created": true, "boundAt": 1,
    })));
    assert_eq!(
        made,
        json!({"ok": true, "machine": "vm-1", "team": "team_p", "created": true, "snapshot": "snap_x",
               "environment": {"id": "denv_1", "status": "ready"}})
    );
    let bound = ensure_answer(Ok(json!({"machine": {"id": "vm-1"}, "created": false})));
    assert_eq!(
        (bound["created"].clone(), bound["environment"].clone()),
        (json!(false), Value::Null)
    );
    assert_eq!(ensure_answer(Ok(json!({"created": true})))["error_code"], json!("bad_answer"));
    let not_found =
        ensure_answer(Err(E::Status { status: 404, code: "cloud_environment.not_found" }));
    assert_eq!(not_found["error_code"], json!("cloud_environment.not_found"));
    assert_eq!(
        ensure_answer(Err(E::Status { status: 404, code: "" }))["error_code"],
        json!("unavailable")
    );
    assert_eq!(
        ensure_answer(Err(E::Status { status: 404, code: "not_found" }))["error_code"],
        json!("unavailable")
    );
    assert_eq!(
        ensure_answer(Err(E::Status { status: 500, code: "" }))["error_code"],
        json!("refused")
    );
    assert_eq!(ensure_answer(Err(E::Unreachable("x".into())))["error_code"], json!("unreachable"));
}
