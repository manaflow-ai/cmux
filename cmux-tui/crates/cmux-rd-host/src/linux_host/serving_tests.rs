//! The identity invariant (serving.rs) as a table: every previous sign-in this desktop can hold,
//! times a join's sign-in that works or fails, and who the host serves afterwards.

use super::super::machine;
use super::super::stack_login::tests::{stub, Seen};
use super::Unit;
use crate::Res;
use cmux_hub_host::hub::now_ms;
use cmux_hub_host::identity::{self, Account, Device};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// A unit that records how many hub calls had been made when it was stopped, and whose stop
/// fails (a `systemctl` that failed, a process that would not die) when `fails`.
struct Recorded {
    seen: Arc<Mutex<Vec<Seen>>>,
    stops: Mutex<Vec<usize>>,
    fails: bool,
}

impl Recorded {
    fn new(seen: Arc<Mutex<Vec<Seen>>>, fails: bool) -> Self {
        Self { seen, stops: Mutex::new(Vec::new()), fails }
    }
}

impl Unit for Recorded {
    fn stop(&self) -> Res<()> {
        let calls = self.seen.lock().unwrap().len();
        self.stops.lock().unwrap().push(calls);
        if self.fails {
            return Err("the screen host is still running (pid 4242)".into());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
enum Before {
    Nothing,
    PersonAnchored,
    PersonUnanchored,
    /// This same join (acpmux home, machine id, generation), signed in as the joiner.
    SameJoin,
    /// An earlier join of the same acpmux home, to another account: joined again since.
    OtherJoin,
}

fn credential(machine_id: &str) -> machine::MachineCredential {
    let record = format!(
        r#"{{"credential":"cmm_{machine_id}","name":"lane-vm","machine_id":"{machine_id}","credential_generation":1}}"#
    );
    serde_json::from_str(&record).unwrap()
}

fn dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-rd-serving-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    identity::private_dir(&dir).unwrap();
    dir
}

/// The acpmux home of the joins in `dir`'s cells; it holds the current join's credential, m-b.
fn home(dir: &Path) -> PathBuf {
    let home = dir.join("acpmux-home");
    if !home.join(machine::CREDENTIAL_FILE).exists() {
        identity::private_dir(&home).unwrap();
        let record = br#"{"credential":"cmm_m-b","name":"lane-vm","machine_id":"m-b","credential_generation":1}"#;
        identity::write_private(&home.join(machine::CREDENTIAL_FILE), record).unwrap();
    }
    home
}

/// Writes `before`'s records; the device it leaves, if any.
fn hold(dir: &Path, origin: &str, before: Before) -> Option<Device> {
    let account = |user: &str, anchored_until| Account {
        hub: origin.to_owned(),
        user_id: user.to_owned(),
        anchored_until,
    };
    let (account, joined) = match before {
        Before::Nothing => return None,
        Before::PersonAnchored => (account("p:a", now_ms() + 30 * 24 * 3_600_000), None),
        Before::PersonUnanchored => (account("p:a", 0), None),
        Before::SameJoin => (account("p:b", 0), Some(credential("m-b"))),
        Before::OtherJoin => (account("p:a", 0), Some(credential("m-a"))),
    };
    let device = Device::generate("lane-vm").unwrap();
    device.save(dir).unwrap();
    account.save(dir).unwrap();
    if let Some(credential) = joined {
        machine::Joined::of(&home(dir), &credential).save(dir).unwrap();
    }
    Some(device)
}

/// One cell: `before`, then the join of account p:b (credential m-b) whose machine sign-in
/// works or not, with a unit whose stop works or not. Afterwards no host serves the earlier
/// identity: the records say otherwise, and a host process that started as it stops itself
/// at its next check ([`super::Serving::changed`]).
fn cell(before: Before, sign_in_works: bool, stop_works: bool) {
    let tag = format!("{before:?}-signin-{sign_in_works}-stop-{stop_works}");
    let (origin, seen) = stub(move |_, request| match request.path.as_str() {
        "/v1/auth/machine" if !sign_in_works => {
            (503, serde_json::json!({ "error": { "code": "unavailable", "message": "down" } }))
        }
        "/v1/auth/machine" => (
            200,
            serde_json::json!({ "session": "m", "userId": "p:b", "expiresAt": now_ms() + 3_600_000 }),
        ),
        "/v1/auth/device" => {
            (200, serde_json::json!({ "session": "a", "expiresAt": now_ms() + 3_600_000 }))
        }
        _ => (200, serde_json::json!({ "ok": true })),
    });
    let dir = dir(&tag);
    let home = home(&dir);
    let old = hold(&dir, &origin, before);
    // What a host process started before this join serves as.
    let was = super::Serving::now(&dir).ok();
    let unit = Recorded::new(seen.clone(), !stop_works);
    let got = super::super::join_device(&dir, &origin, Some((home, credential("m-b"))), &unit);
    let calls: Vec<(String, String)> =
        seen.lock().unwrap().iter().map(|s| (s.method.clone(), s.path.clone())).collect();
    let stops = unit.stops.lock().unwrap().clone();
    let account = Account::load(&dir).unwrap();
    let device = Device::load(&dir).unwrap();
    let old_id = old.as_ref().map(|d| d.id.clone());
    let served = |user: &str| account.as_ref().is_some_and(|a| a.user_id == user);
    let earlier_stops_itself = was.as_ref().is_none_or(|was| was.changed(&dir).is_some());
    let kept = matches!(before, Before::SameJoin) && sign_in_works;
    // Never the earlier account, whatever happened: not in a process started as it, and not in
    // one started from the records. They still name it only when nothing could be deleted (the
    // hub did not sign it out and its host may still run), and then no host starts from them.
    if served("p:a") {
        assert!(!stop_works, "{tag}: the records still name p:a: {calls:?}");
        let joined = machine::Joined::load(&dir).unwrap();
        let joined = joined.unwrap_or_else(|| panic!("{tag}: a person's p:a kept"));
        assert!(
            super::current_join(&dir, &origin, &joined).is_err(),
            "{tag}: a host starts as p:a"
        );
    }
    // SameJoin's identity is the current join's: a host that serves on after a failed teardown
    // (the hub down, the stop failed) still serves the current join. Any other stops itself.
    if !matches!(before, Before::SameJoin) {
        assert!(earlier_stops_itself, "{tag}: a host started as the earlier identity serves on");
    }
    // The hub signs a person's earlier device out before the unit is stopped: its sessions end
    // there even when its process never hears.
    if let (Before::PersonAnchored | Before::PersonUnanchored, Some(old_id)) = (before, &old_id) {
        let sign_out = ("POST".to_owned(), format!("/v1/devices/{old_id}/sign-out"));
        let at = calls.iter().position(|c| *c == sign_out);
        assert!(at.is_some(), "{tag}: no sign-out of the earlier device: {calls:?}");
        assert!(stops.first().is_some_and(|&s| Some(s) > at), "{tag}: stops {stops:?}");
    }
    if kept {
        // The same join keeps its device: nothing is torn down.
        assert!(got.is_ok(), "{tag}: {:?}", got.as_ref().err());
        assert_eq!(device.map(|d| d.id), old_id, "{tag}");
        assert!(stops.is_empty(), "{tag}: the same identity stops nothing");
    } else if !stop_works {
        // A host that may still run: the join does not go on, and says so.
        assert!(got.is_err(), "{tag}: an unverified stop reads as set up");
        let signed_in_after_stop = calls.iter().skip(stops[0]).any(|c| c.1 == "/v1/auth/machine");
        assert!(!signed_in_after_stop, "{tag}: signed in over a host that may run: {calls:?}");
    } else if sign_in_works {
        assert!(got.is_ok(), "{tag}: {:?}", got.as_ref().err());
        assert!(served("p:b"), "{tag}: serves {account:?}");
        let device = device.unwrap_or_else(|| panic!("{tag}: no device"));
        assert_ne!(Some(device.id), old_id, "{tag}: the earlier device serves B");
        // The unit stopped before the new identity signed in.
        let first_new_sign_in = calls.iter().rposition(|c| c.1 == "/v1/auth/machine");
        assert!(
            stops.first().is_some_and(|&at| Some(at) <= first_new_sign_in),
            "{tag}: stops {stops:?}, calls {calls:?}"
        );
    } else {
        assert!(got.is_err(), "{tag}: a failed sign-in reads as set up");
        assert!(account.is_none() && device.is_none(), "{tag}: the host is not off: {account:?}");
        assert_eq!(machine::Joined::load(&dir).unwrap(), None, "{tag}");
        assert!(!stops.is_empty(), "{tag}: the unit was not stopped");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_host_serves_only_the_current_join() {
    for before in [
        Before::Nothing,
        Before::PersonAnchored,
        Before::PersonUnanchored,
        Before::SameJoin,
        Before::OtherJoin,
    ] {
        for sign_in_works in [true, false] {
            for stop_works in [true, false] {
                cell(before, sign_in_works, stop_works);
            }
        }
    }
}

/// A hub whose Stack sign-in names `p:a` for token "tok-a" and `p:c` for "tok-c", and refuses
/// "tok-bad".
fn person_hub() -> (String, Arc<Mutex<Vec<Seen>>>) {
    stub(|_, request| match request.path.as_str() {
        "/v1/auth/stack" => {
            let token = serde_json::from_str::<serde_json::Value>(&request.body).unwrap()["token"]
                .as_str()
                .unwrap_or("")
                .to_owned();
            match token.as_str() {
                "tok-a" => (200, serde_json::json!({ "session": "s", "userId": "p:a" })),
                "tok-c" => (200, serde_json::json!({ "session": "s", "userId": "p:c" })),
                _ => (
                    401,
                    serde_json::json!({ "error": { "code": "unauthorized", "message": "no" } }),
                ),
            }
        }
        "/v1/auth/device/anchor" => (200, serde_json::json!({ "anchoredUntil": now_ms() + 1_000 })),
        "/v1/auth/device" => {
            (200, serde_json::json!({ "session": "a", "expiresAt": now_ms() + 3_600_000 }))
        }
        _ => (200, serde_json::json!({ "ok": true })),
    })
}

/// What a person cell leaves: its directory, the earlier device, the sign-in, the hub's calls and
/// the unit's stops.
type PersonCell = (PathBuf, Device, Res<(Device, String)>, Vec<(String, String)>, Vec<usize>);

fn person_cell(token: &str) -> PersonCell {
    let (origin, seen) = person_hub();
    let dir = dir(&format!("person-{token}"));
    let old = hold(&dir, &origin, Before::PersonAnchored).unwrap();
    let unit = Recorded::new(seen.clone(), false);
    let got = super::person(&dir, &origin, token, None, &|| "encoder".to_owned(), &unit);
    let calls = seen.lock().unwrap().iter().map(|s| (s.method.clone(), s.path.clone())).collect();
    let stops = unit.stops.lock().unwrap().clone();
    (dir, old, got, calls, stops)
}

#[test]
fn the_same_person_keeps_this_desktop() {
    let (dir, old, got, _, stops) = person_cell("tok-a");
    assert_eq!(got.unwrap().0.id, old.id);
    assert_eq!(Account::load(&dir).unwrap().unwrap().user_id, "p:a");
    assert!(stops.is_empty(), "the same identity stops nothing");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn another_person_takes_this_desktop_only_after_the_first_is_torn_down() {
    let (dir, old, got, calls, stops) = person_cell("tok-c");
    let device = got.unwrap().0;
    assert_ne!(device.id, old.id);
    assert_eq!(Account::load(&dir).unwrap().unwrap().user_id, "p:c");
    let sign_out = ("POST".to_owned(), format!("/v1/devices/{}/sign-out", old.id));
    let at = calls.iter().position(|c| *c == sign_out).expect("the earlier device signed out");
    let registered = calls.iter().position(|c| c.1 == "/v1/devices").expect("registered");
    // Signed out at the hub, then the unit stopped, then the new device registered.
    assert!(stops.first().is_some_and(|&s| at < s && s <= registered), "{stops:?} {calls:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_refused_person_sign_in_leaves_the_host_off() {
    let (dir, _, got, _, stops) = person_cell("tok-bad");
    assert!(got.is_err());
    assert_eq!(Account::load(&dir).unwrap(), None);
    assert!(Device::load(&dir).unwrap().is_none());
    assert!(!stops.is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unanswered_sign_out_is_asked_again_and_the_host_is_off_meanwhile() {
    let dir = dir("pending");
    // The earlier person's hub does not answer.
    let old = hold(&dir, "http://127.0.0.1:1", Before::PersonAnchored).unwrap();
    let unit = Recorded::new(Arc::new(Mutex::new(Vec::new())), false);
    super::tear_down(&dir, super::Previous::load(&dir).unwrap(), &unit).unwrap();
    assert!(Account::load(&dir).unwrap().is_none() && Device::load(&dir).unwrap().is_none());
    let pending = super::load_pending(&dir).unwrap();
    assert_eq!(pending.iter().map(|p| p.device.id.as_str()).collect::<Vec<_>>(), [old.id.as_str()]);
    // Still unanswered: kept. Once a hub answers, dropped.
    super::retry_pending(&dir);
    assert_eq!(super::load_pending(&dir).unwrap().len(), 1);
    let (origin, seen) = person_hub();
    let mut moved = pending;
    moved[0].hub = origin;
    super::save_pending(&dir, &moved).unwrap();
    super::retry_pending(&dir);
    assert!(super::load_pending(&dir).unwrap().is_empty());
    let sign_out = format!("/v1/devices/{}/sign-out", old.id);
    assert!(seen.lock().unwrap().iter().any(|s| s.path == sign_out));
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review of #45369: a hub that fails (a 5xx) has not signed the device out, so its pending
/// sign-out is kept; only a hub that signs it out or does not know it (404) drops it.
#[test]
fn a_pending_sign_out_is_kept_until_the_hub_confirms_it() {
    let dir = dir("pending-5xx");
    let old = hold(&dir, "http://127.0.0.1:1", Before::PersonAnchored).unwrap();
    let unit = Recorded::new(Arc::new(Mutex::new(Vec::new())), false);
    super::tear_down(&dir, super::Previous::load(&dir).unwrap(), &unit).unwrap();
    let answering = |status: u16| {
        stub(move |_, _| (status, serde_json::json!({ "error": { "code": "x", "message": "x" } })))
    };
    let point = |origin: String| {
        let mut moved = super::load_pending(&dir).unwrap();
        moved[0].hub = origin;
        super::save_pending(&dir, &moved).unwrap();
    };
    for status in [500, 502, 503, 429] {
        let (origin, seen) = answering(status);
        point(origin);
        super::retry_pending(&dir);
        assert!(!seen.lock().unwrap().is_empty(), "{status}: not asked");
        let left = super::load_pending(&dir).unwrap();
        assert_eq!(left.len(), 1, "{status}: a failing hub dropped the pending sign-out");
        assert_eq!(left[0].device.id, old.id);
    }
    let (origin, _) = answering(404);
    point(origin);
    super::retry_pending(&dir);
    assert!(super::load_pending(&dir).unwrap().is_empty(), "a hub that does not know it");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review of #45369: a pending sign-out keeps its device key on disk, so its file is private
/// and its entries do not outlive the bound; one past it is dropped without asking the hub.
#[test]
fn a_pending_sign_out_is_private_and_dropped_once_it_is_old() {
    use std::os::unix::fs::PermissionsExt;
    let dir = dir("pending-age");
    let old = hold(&dir, "http://127.0.0.1:1", Before::PersonAnchored).unwrap();
    let unit = Recorded::new(Arc::new(Mutex::new(Vec::new())), false);
    super::tear_down(&dir, super::Previous::load(&dir).unwrap(), &unit).unwrap();
    let file = dir.join(super::PENDING_FILE);
    assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    let pending = super::load_pending(&dir).unwrap();
    assert_eq!(pending.len(), 1);
    let since = pending[0].since_ms;
    assert!(since > 0, "no time recorded");
    // Still within the bound, at its last moment: kept (the hub still does not answer).
    super::retry_pending_at(&dir, since + super::PENDING_MAX_AGE_MS);
    assert_eq!(super::load_pending(&dir).unwrap().len(), 1);
    // Past it: dropped, unasked, and the file with it.
    let (origin, seen) = person_hub();
    let mut moved = super::load_pending(&dir).unwrap();
    moved[0].hub = origin;
    super::save_pending(&dir, &moved).unwrap();
    super::retry_pending_at(&dir, since + super::PENDING_MAX_AGE_MS + 1);
    assert!(super::load_pending(&dir).unwrap().is_empty());
    assert!(!file.exists());
    let sign_out = format!("/v1/devices/{}/sign-out", old.id);
    assert!(!seen.lock().unwrap().iter().any(|s| s.path == sign_out), "an aged entry was sent");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_host_started_for_an_earlier_join_serves_nothing() {
    let dir = dir("earlier-join");
    let home = dir.join("acpmux-home");
    identity::private_dir(&home).unwrap();
    let write = |machine_id: &str| {
        let record = format!(
            r#"{{"credential":"cmm_{machine_id}","machine_id":"{machine_id}","credential_generation":1}}"#
        );
        identity::write_private(&home.join(machine::CREDENTIAL_FILE), record.as_bytes()).unwrap();
    };
    write("m-a");
    let joined = machine::Joined::of(&home, &machine::load(&home).unwrap().unwrap());
    assert!(super::current_join(&dir, "http://127.0.0.1:1", &joined).is_ok());
    // Joined again: the unit's record names the earlier join.
    write("m-b");
    let e = super::current_join(&dir, "http://127.0.0.1:1", &joined).unwrap_err();
    assert!(e.is::<super::Fatal>() && e.to_string().contains("joined again"), "{e}");
    // Left: no credential at all.
    std::fs::remove_file(home.join(machine::CREDENTIAL_FILE)).unwrap();
    assert!(super::current_join(&dir, "http://127.0.0.1:1", &joined)
        .unwrap_err()
        .is::<super::Fatal>());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review F1 of #45369, third round: the teardown's stop fails (the host process may still
/// run), but the hub signs its device out and its records go, so the host stops itself at its
/// next check.
#[test]
fn a_host_whose_stop_failed_stops_itself_at_its_next_check() {
    let dir = dir("watch");
    let (origin, seen) = person_hub();
    let old = hold(&dir, &origin, Before::PersonAnchored).unwrap();
    let serving = super::Serving::now(&dir).unwrap();
    let every = std::time::Duration::from_millis(50);
    // Still what it started as: it serves on, through the whole wait.
    assert_eq!(super::wait_serving(&serving, &dir, every * 4, every), None);
    let unit = Recorded::new(seen.clone(), true);
    let e = super::tear_down(&dir, super::Previous::load(&dir).unwrap(), &unit).unwrap_err();
    assert!(e.to_string().contains("may still be running"), "{e}");
    let sign_out = format!("/v1/devices/{}/sign-out", old.id);
    assert!(seen.lock().unwrap().iter().any(|s| s.path == sign_out), "not signed out at the hub");
    assert!(Account::load(&dir).unwrap().is_none() && Device::load(&dir).unwrap().is_none());
    // At its next check, not at the end of its wait.
    let started = std::time::Instant::now();
    let why = super::wait_serving(&serving, &dir, std::time::Duration::from_secs(30), every)
        .expect("the host did not stop itself");
    assert!(started.elapsed() < every * 4, "{:?}", started.elapsed());
    assert!(why.contains("sign-in is gone"), "{why}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A person's `enable` and a join's never interleave: the second writer waits for the first.
#[test]
fn a_second_writer_waits_for_the_first() {
    let dir = dir("lock");
    let first = super::lock(&dir).unwrap();
    let (took, taken) = std::sync::mpsc::channel();
    let other = dir.clone();
    let waiter = std::thread::spawn(move || {
        let _second = super::lock(&other).unwrap();
        took.send(()).unwrap();
    });
    assert!(taken.recv_timeout(std::time::Duration::from_millis(200)).is_err(), "not held");
    drop(first);
    taken.recv_timeout(std::time::Duration::from_secs(2)).expect("never taken after release");
    waiter.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A join whose sign-in failed leaves no sign-in, but the machine stays the join's: a person's
/// `enable` is refused there, from any shell (no `ACPMUX_HOME` needed), until the join leaves.
#[test]
fn after_a_failed_join_a_person_is_still_refused() {
    let dir = dir("joining");
    let home = home(&dir);
    let (origin, seen) = stub(|_, request| match request.path.as_str() {
        "/v1/auth/machine" => {
            (503, serde_json::json!({ "error": { "code": "unavailable", "message": "down" } }))
        }
        _ => (200, serde_json::json!({ "ok": true })),
    });
    let unit = Recorded::new(seen, false);
    assert!(super::join(&dir, &origin, &home, credential("m-b"), &unit).is_err());
    assert!(Account::load(&dir).unwrap().is_none() && Device::load(&dir).unwrap().is_none());
    assert_eq!(machine::Joined::load(&dir).unwrap(), None);
    if std::env::var_os("ACPMUX_HOME").is_none() {
        assert!(super::join_owner(&dir).unwrap().is_some(), "a person may enable over the join");
        let refused = super::person(&dir, &origin, "tok-a", None, &|| "encoder".to_owned(), &unit);
        let Err(e) = refused else { panic!("a person signed in over the join") };
        assert!(e.to_string().contains("acpmux machine leave"), "{e}");
    }
    // Left: the join's credential is gone, and a person may enable again.
    std::fs::remove_file(home.join(machine::CREDENTIAL_FILE)).unwrap();
    if std::env::var_os("ACPMUX_HOME").is_none() {
        assert_eq!(super::join_owner(&dir).unwrap(), None);
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// What a desktop a join signed in before joins were marked (#45369) has after `run`'s start.
struct Unmarked {
    dir: PathBuf,
    home: PathBuf,
    old: Device,
    got: Res<machine::MachineCredential>,
}

/// A desktop the join m-b signed in as `recorded` before joins were marked; the hub now signs
/// m-b in as p:b, or is down.
fn unmarked(recorded: &str, hub_up: bool) -> Unmarked {
    let (origin, _) = stub(move |_, request| match request.path.as_str() {
        "/v1/auth/machine" if !hub_up => {
            (503, serde_json::json!({ "error": { "code": "unavailable", "message": "down" } }))
        }
        "/v1/auth/machine" => (
            200,
            serde_json::json!({ "session": "m", "userId": "p:b", "expiresAt": now_ms() + 3_600_000 }),
        ),
        _ => (200, serde_json::json!({ "ok": true })),
    });
    let dir = dir(&format!("unmarked-{recorded}-{hub_up}"));
    let home = dir.join("acpmux-home");
    identity::private_dir(&home).unwrap();
    let record = br#"{"credential":"cmm_m-b","name":"lane-vm","machine_id":"m-b","credential_generation":1}"#;
    identity::write_private(&home.join(machine::CREDENTIAL_FILE), record).unwrap();
    let old = Device::generate("lane-vm").unwrap();
    old.save(&dir).unwrap();
    Account { hub: origin.clone(), user_id: recorded.to_owned(), anchored_until: 0 }
        .save(&dir)
        .unwrap();
    let joined = machine::Joined { acpmux_home: home.clone(), ..Default::default() };
    joined.save(&dir).unwrap();
    let got = super::current_join(&dir, &origin, &joined);
    Unmarked { dir, home, old, got }
}

#[test]
fn a_join_signed_in_before_its_mark_keeps_serving_its_account_and_is_marked() {
    let c = unmarked("p:b", true);
    let credential = c.got.unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(Device::load(&c.dir).unwrap().unwrap().id, c.old.id);
    assert_eq!(Account::load(&c.dir).unwrap().unwrap().user_id, "p:b");
    let marked = machine::Joined::of(&c.home, &credential);
    assert_eq!(machine::Joined::load(&c.dir).unwrap(), Some(marked));
    let _ = std::fs::remove_dir_all(&c.dir);
}

#[test]
fn a_join_signed_in_before_its_mark_as_another_account_serves_the_current_join() {
    let c = unmarked("p:a", true);
    let credential = c.got.unwrap_or_else(|e| panic!("{e}"));
    assert_ne!(Device::load(&c.dir).unwrap().unwrap().id, c.old.id);
    assert_eq!(Account::load(&c.dir).unwrap().unwrap().user_id, "p:b");
    let marked = machine::Joined::of(&c.home, &credential);
    assert_eq!(machine::Joined::load(&c.dir).unwrap(), Some(marked));
    let _ = std::fs::remove_dir_all(&c.dir);
}

#[test]
fn a_join_signed_in_before_its_mark_serves_nothing_while_the_hub_is_down() {
    let c = unmarked("p:b", false);
    assert!(c.got.is_err());
    assert_eq!(Account::load(&c.dir).unwrap(), None);
    assert!(Device::load(&c.dir).unwrap().is_none());
    assert_eq!(machine::Joined::load(&c.dir).unwrap(), None);
    let _ = std::fs::remove_dir_all(&c.dir);
}
