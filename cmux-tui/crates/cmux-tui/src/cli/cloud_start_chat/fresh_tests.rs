//! fresh.rs: a new machine that never comes up is given up within the bound, deleted, and the chat starts on a
//! fresh one (production 2026-11-17 22:11Z and 2026-11-18 00:21Z: `connect.link 180005 ms`, then failure).

use std::time::Duration;

use serde_json::{Value, json};

use super::super::fresh::{START_BOUND, STUCK_CODE};
use super::*;

/// A new machine with a folder on it: the start answers once start-session does (no read of where it runs).
const CWD: &[&str] = &["--cwd", "/home/cmux/w"];

/// The app's answer for a start whose machine never connected (CloudStartSessionStrings `notConnected`).
fn not_connected(name: &str, id: &str) -> Ran {
    let message = format!(
        "cloudStartSession unavailable: Machine `{name}` didn't connect, so no agent started there. Check it \
         with `cmux cloud machine-status --target machine:{id}`, then run `cmux cloud start-session --target \
         machine:{id} --agent claude` again."
    );
    Ran {
        code: 1,
        stderr: json!({"code": "unavailable", "message": message}).to_string(),
        ..Ran::default()
    }
}

/// The app's answer for a start whose agent never answered identify (`agentFailed`, timed out).
fn identify_timed_out(name: &str, id: &str) -> Ran {
    let message = format!(
        "cloudStartSession unavailable: Machine `{name}` started but its agent didn't (timed out: identify (no \
         reply within 10.0 seconds)). Run `cmux cloud start-session --target machine:{id} --agent claude` again."
    );
    Ran {
        code: 1,
        stderr: json!({"code": "unavailable", "message": message}).to_string(),
        ..Ran::default()
    }
}

/// The app's list with the stuck machine in it.
fn listed_stuck(id: &str) -> Ran {
    ok(json!({"account": {"signed_in": true},
              "machines": [{"title": "dev"}, {"title": "chat-fresh", "machine_id": id, "status": "running"}]}))
}

fn kill(id: &str) -> Vec<String> {
    strings(&["cloud", "kill-machine", "--target", &format!("machine:{id}"), "--confirm", "--json"])
}

fn starts(fake: &Fake) -> usize {
    fake.ran
        .iter()
        .filter(|words| words.get(1).map(String::as_str) == Some("start-session"))
        .count()
}

/// 22:11Z and 00:21Z: the new machine's start waited the app's whole 180 s connect and failed. It is given up at
/// the bound, deleted, and the chat starts on a fresh machine; the run says so while it goes on.
#[test]
fn a_new_machine_stuck_past_the_bound_is_deleted_and_the_chat_starts_on_a_fresh_one() {
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    // The first start would take the app's 180 s connect wait.
    fake.slow.push((1, Duration::from_secs(180)));
    let began = fake.clock;
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(answer["session_id"], "sess-1");
    assert_eq!(
        fake.ran[3],
        kill("vm-stuck"),
        "the stuck machine is deleted before the fresh start"
    );
    assert_eq!(starts(&fake), 2);
    let replaced = &answer["fresh_retry"][0];
    assert_eq!(replaced["machine_id"], "vm-stuck");
    assert_eq!(replaced["deleted"], true);
    assert_eq!(replaced["why"], "bound");
    // Given up at the bound, not after the app's 180 s: list 5 s, the start to the bound, then the cleanup and
    // the fresh start (5 s each).
    let spent = fake.clock.saturating_duration_since(began);
    assert_eq!(spent, Duration::from_secs(5) + START_BOUND + Duration::from_secs(20), "{spent:?}");
    assert_eq!(fake.said.len(), 1, "the retry is said, never a silent wait");
    assert!(fake.said[0].contains("chat-fresh"), "{:?}", fake.said);
}

/// 22:11Z's second half: the machine linked, then its agent's identify timed out. The app answered at once,
/// within the bound: that start is stuck too.
#[test]
fn an_identify_timeout_on_a_new_machine_is_retried_on_a_fresh_one() {
    let mut fake = Fake::new(vec![
        signed_in(),
        identify_timed_out("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(answer["fresh_retry"][0]["why"], "app");
    assert_eq!(fake.ran[3], kill("vm-stuck"));
}

/// The fresh machine is stuck too: the run stops after one retry, both machines are deleted, and the answer
/// says so, with nothing left counting against the team's machines.
#[test]
fn a_second_stuck_machine_ends_the_run_with_both_deleted() {
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-a"),
        listed_stuck("vm-a"),
        ok(json!({"deleted": true})),
        signed_in(),
        not_connected("chat-fresh", "vm-b"),
        listed_stuck("vm-b"),
        ok(json!({"deleted": true})),
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(CWD)) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(exit, 1);
    assert_eq!(error["code"], STUCK_CODE);
    assert_eq!(fake.ran[3], kill("vm-a"));
    assert_eq!(fake.ran[7], kill("vm-b"));
    assert_eq!(fake.ran.len(), 8, "no third machine");
    let replaced: Vec<&Value> =
        error["details"]["fresh_retry"].as_array().unwrap().iter().collect();
    assert_eq!(replaced.len(), 2);
    assert!(replaced.iter().all(|row| row["deleted"] == true));
    assert!(error["message"].as_str().unwrap().contains("cmux deleted it"), "{error}");
    assert!(
        !error["message"].as_str().unwrap().contains("machine-status"),
        "no advice for a deleted machine: {error}"
    );
}

/// A machine that could not be deleted stops the retries (a fresh one would add a machine), and the answer
/// names the command that deletes it.
#[test]
fn a_stuck_machine_that_cannot_be_deleted_stops_the_retry_and_names_the_delete() {
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        Ran {
            code: 1,
            stderr: json!({"code": "unavailable", "message": "no"}).to_string(),
            ..Ran::default()
        },
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(CWD)) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(starts(&fake), 1);
    assert_eq!(error["details"]["fresh_retry"][0]["deleted"], false);
    assert!(
        error["message"]
            .as_str()
            .unwrap()
            .contains("cmux cloud kill-machine --target machine:vm-stuck --confirm"),
        "{error}"
    );
}

/// A machine the caller named (`--name`, `--target`) is never given up or deleted: the app's answer stands,
/// and the start is not bounded.
#[test]
fn a_named_machine_is_never_replaced_or_deleted() {
    let mut fake = Fake::new(vec![signed_in(), not_connected("dev", "vm-dev")]);
    fake.slow.push((1, Duration::from_secs(180)));
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--name", "dev"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "unavailable");
    assert_eq!(fake.ran.len(), 2, "no delete and no second start: {:?}", fake.ran);
    assert!(fake.said.is_empty());
}
