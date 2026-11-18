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

/// A unit that records how many hub calls had been made when it was stopped.
struct Recorded {
    seen: Arc<Mutex<Vec<Seen>>>,
    stops: Mutex<Vec<usize>>,
}

impl Unit for Recorded {
    fn stop(&self) -> Res<()> {
        let calls = self.seen.lock().unwrap().len();
        self.stops.lock().unwrap().push(calls);
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

const HOME: &str = "/acpmux-home";

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
        machine::Joined::of(Path::new(HOME), &credential).save(dir).unwrap();
    }
    Some(device)
}

/// One cell: `before`, then the join of account p:b (credential m-b) whose machine sign-in
/// works or not.
fn cell(before: Before, sign_in_works: bool) {
    let tag = format!("{before:?}-{sign_in_works}");
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
    let old = hold(&dir, &origin, before);
    let unit = Recorded { seen: seen.clone(), stops: Mutex::new(Vec::new()) };
    let joined = Some((PathBuf::from(HOME), credential("m-b")));
    let got = super::super::join_device(&dir, &origin, joined, &unit);
    let calls: Vec<(String, String)> =
        seen.lock().unwrap().iter().map(|s| (s.method.clone(), s.path.clone())).collect();
    let stops = unit.stops.lock().unwrap().clone();
    let account = Account::load(&dir).unwrap();
    let device = Device::load(&dir).unwrap();
    let old_id = old.as_ref().map(|d| d.id.clone());
    let served = |user: &str| account.as_ref().is_some_and(|a| a.user_id == user);
    // Never the earlier account, whatever happened.
    assert!(!served("p:a"), "{tag}: still serves p:a: {calls:?}");
    let first_new_sign_in = calls.iter().rposition(|c| c.1 == "/v1/auth/machine");
    if sign_in_works {
        assert!(got.is_ok(), "{tag}: {:?}", got.as_ref().err());
        assert!(served("p:b"), "{tag}: serves {account:?}");
        let device = device.unwrap_or_else(|| panic!("{tag}: no device"));
        match before {
            // The same join keeps its device: nothing is torn down.
            Before::SameJoin => assert_eq!(Some(device.id), old_id, "{tag}"),
            _ => {
                assert_ne!(Some(device.id), old_id, "{tag}: the earlier device serves B");
                // The unit stopped before the new identity signed in.
                assert!(
                    stops.first().is_some_and(|&at| Some(at) <= first_new_sign_in),
                    "{tag}: stops {stops:?}, calls {calls:?}"
                );
            }
        }
    } else {
        assert!(got.is_err(), "{tag}: a failed sign-in reads as set up");
        assert!(account.is_none() && device.is_none(), "{tag}: the host is not off: {account:?}");
        assert_eq!(machine::Joined::load(&dir).unwrap(), None, "{tag}");
        if !matches!(before, Before::Nothing) {
            assert!(!stops.is_empty(), "{tag}: the unit was not stopped");
        }
    }
    // A person's earlier device is signed out at the hub, after the unit stopped.
    if let (Before::PersonAnchored | Before::PersonUnanchored, Some(old_id)) = (before, &old_id) {
        let sign_out = ("POST".to_owned(), format!("/v1/devices/{old_id}/sign-out"));
        let at = calls.iter().position(|c| *c == sign_out);
        assert!(at.is_some(), "{tag}: no sign-out of the earlier device: {calls:?}");
        assert!(stops.first().is_some_and(|&s| Some(s) <= at), "{tag}: stops {stops:?}");
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
        for works in [true, false] {
            cell(before, works);
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

fn person_cell(
    token: &str,
) -> (PathBuf, Device, Res<(Device, String)>, Vec<(String, String)>, Vec<usize>) {
    let (origin, seen) = person_hub();
    let dir = dir(&format!("person-{token}"));
    let old = hold(&dir, &origin, Before::PersonAnchored).unwrap();
    let unit = Recorded { seen: seen.clone(), stops: Mutex::new(Vec::new()) };
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
    assert!(stops.first().is_some_and(|&s| s <= at) && at < registered, "{stops:?} {calls:?}");
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
    let unit = Recorded { seen: Arc::new(Mutex::new(Vec::new())), stops: Mutex::new(Vec::new()) };
    super::tear_down(&dir, super::Previous::load(&dir).unwrap(), &unit).unwrap();
    assert!(Account::load(&dir).unwrap().is_none() && Device::load(&dir).unwrap().is_none());
    let pending = super::load_pending(&dir).unwrap();
    assert_eq!(pending.iter().map(|p| p.device.id.clone()).collect::<Vec<_>>(), [old.id.clone()]);
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
    assert!(super::current_join(&dir, &joined).is_ok());
    // Joined again: the unit's record names the earlier join.
    write("m-b");
    let e = super::current_join(&dir, &joined).unwrap_err();
    assert!(e.is::<super::Fatal>() && e.to_string().contains("joined again"), "{e}");
    // Left: no credential at all.
    std::fs::remove_file(home.join(machine::CREDENTIAL_FILE)).unwrap();
    assert!(super::current_join(&dir, &joined).unwrap_err().is::<super::Fatal>());
    let _ = std::fs::remove_dir_all(&dir);
}
