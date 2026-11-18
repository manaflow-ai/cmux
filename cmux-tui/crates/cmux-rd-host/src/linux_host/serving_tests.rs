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
        assert!(got.is_ok(), "{tag}: {got:?}");
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
