//! fresh.rs: a new machine that never comes up is given up within the bound, deleted, and the chat starts on a
//! fresh one (production 2026-11-17 22:11Z and 2026-11-18 00:21Z: `connect.link 180005 ms`, then failure).

use std::time::Duration;

use serde_json::{Value, json};

use super::super::fresh::{START_BOUND, STUCK_CODE};
use super::super::stuck_facts::READ_BOUND;
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
              "machines": [{"title": "dev"}, {"title": "chat-fresh", "machine_id": id, "status": "running",
                            "created_at": "2026-11-19T19:43:02Z"}]}))
}

fn refused(message: &str) -> Ran {
    Ran {
        code: 1,
        stderr: json!({"code": "unavailable", "message": message}).to_string(),
        ..Ran::default()
    }
}

/// The three reads of a stuck machine before its delete (stuck_facts.rs), each refused: they never stop it.
fn unread() -> Vec<Ran> {
    vec![refused("no status"), refused("no diagnostics"), refused("no exec")]
}

/// The stuck machine `id` listed, its facts read (refused) and its delete.
fn stuck_then_deleted(id: &str) -> Vec<Ran> {
    let mut steps = vec![listed_stuck(id)];
    steps.extend(unread());
    steps.push(ok(json!({"deleted": true})));
    steps
}

fn steps(parts: Vec<Vec<Ran>>) -> Vec<Ran> {
    parts.into_iter().flatten().collect()
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
    let mut fake = Fake::new(steps(vec![
        vec![signed_in(), not_connected("chat-fresh", "vm-stuck")],
        stuck_then_deleted("vm-stuck"),
        vec![signed_in(), started()],
    ]));
    // The first start would take the app's 180 s connect wait.
    fake.slow.push((1, Duration::from_secs(180)));
    let began = fake.clock;
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(answer["session_id"], "sess-1");
    assert_eq!(
        fake.ran[6],
        kill("vm-stuck"),
        "the stuck machine is deleted before the fresh start"
    );
    assert_eq!(starts(&fake), 2);
    let replaced = &answer["fresh_retry"][0];
    assert_eq!(replaced["machine_id"], "vm-stuck");
    assert_eq!(replaced["deleted"], true);
    assert_eq!(replaced["why"], "bound");
    // Given up at the bound, not after the app's 180 s: list 5 s, the start to the bound, then the list, the three
    // facts reads, the delete and the fresh start (5 s each).
    let spent = fake.clock.saturating_duration_since(began);
    assert_eq!(spent, Duration::from_secs(5) + START_BOUND + Duration::from_secs(35), "{spent:?}");
    assert_eq!(fake.said.len(), 1, "the retry is said, never a silent wait");
    assert!(fake.said[0].contains("chat-fresh"), "{:?}", fake.said);
}

/// 2026-11-19 19:43Z: both machines were deleted at the bound and the probe's later reads found nothing. The
/// machine's own facts are read before its delete and kept in the answer: its listed create time, the attempt's
/// stage trace, the platform's status, its diagnostics row and the guest's host journal tail.
#[test]
fn a_stuck_machine_s_facts_are_read_before_its_delete_and_kept_in_the_answer() {
    let diagnostics = json!({"machines": [
        {"id": "vm-other", "stage": "linked"},
        {"id": "vm-stuck", "stage": "dialing", "stage_detail": "parked_timeout", "registry_id": null,
         "nested": {"never": "kept"}},
    ]})
    .to_string();
    let guest = exec_out(
        "image-stamp=cloud-native-abc\nbake-instance-id=\nvm-kind=sandbox\ncmux_host=activating\nuptime_s=31\n\
         --journal--\n2026-11-19T19:43:30Z cmux-host: relay register refused: 503\n",
    );
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        ok(json!({"machineId": "vm-stuck", "status": "running", "state": "booting"})),
        ok(json!({"ok": true, "details": diagnostics})),
        guest,
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(fake.ran[3][..2], strings(&["cloud", "machine-status"]));
    assert_eq!(fake.ran[3][3], "machine:vm-stuck");
    assert_eq!(fake.ran[4][..2], strings(&["cloud", "diagnostics"]));
    assert_eq!(fake.ran[5][..2], strings(&["cloud", "exec"]));
    assert!(
        fake.ran[5][5].starts_with("timeout "),
        "the guest script is bounded there too: {:?}",
        fake.ran[5]
    );
    assert_eq!(fake.ran[6], kill("vm-stuck"), "the reads come before the delete");

    let facts = &answer["fresh_retry"][0]["facts"];
    assert_eq!(facts["machine_id"], "vm-stuck");
    assert_eq!(facts["listed"]["created_at"], "2026-11-19T19:43:02Z");
    assert_eq!(facts["create_ms"]["steps"][1]["step"], "cloud start-session", "{facts}");
    assert_eq!(facts["status"]["state"], "booting");
    assert_eq!(facts["diagnostics"]["stage_detail"], "parked_timeout");
    assert!(facts["diagnostics"].get("nested").is_none(), "scalars only: {facts}");
    assert_eq!(facts["guest"]["image_stamp"], "cloud-native-abc");
    assert_eq!(facts["guest"]["cmux_host"], "activating");
    assert!(facts["guest"].get("bake_instance_id").is_none(), "an empty fact is left out");
    assert!(
        facts["guest"]["host_log"].as_str().unwrap().contains("relay register refused: 503"),
        "{facts}"
    );
    assert!(facts.get("unread").is_none(), "{facts}");
    assert!(facts["unavailable"][0].as_str().unwrap().contains("serial-console"), "{facts}");
}

/// A read that is refused, or that runs past its bound, is named under `unread` and never stops the delete or the
/// fresh start; a slow read costs its bound, not its own time.
#[test]
fn a_failing_or_slow_read_still_deletes_and_starts_on_a_fresh_machine() {
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        refused("Cloud is signed out"),
        ok(json!({"never": "seen"})),
        Ran { code: 127, stderr: "spawn failed".into(), ..Ran::default() },
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    // The diagnostics read would hang for a minute.
    fake.slow.push((4, Duration::from_secs(60)));
    let began = fake.clock;
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(fake.ran[6], kill("vm-stuck"));
    assert_eq!(starts(&fake), 2, "the fresh start ran");
    assert_eq!(answer["machine_id"], "vm-1");
    let row = &answer["fresh_retry"][0];
    assert_eq!(row["deleted"], true);
    let unread: Vec<&str> =
        row["facts"]["unread"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    assert_eq!(unread.len(), 3, "{unread:?}");
    assert!(
        unread[0].starts_with("machine-status: exit 1") && unread[0].contains("signed out"),
        "{unread:?}"
    );
    assert_eq!(unread[1], format!("diagnostics: no answer within {} s", READ_BOUND.as_secs()));
    assert!(unread[2].starts_with("guest log: exit 127"), "{unread:?}");
    assert_eq!(row["facts"]["machine_id"], "vm-stuck", "what was read is still kept");
    // 9 steps of 5 s, the slow one cut at its 5 s bound.
    let spent = fake.clock.saturating_duration_since(began);
    assert_eq!(spent, Duration::from_secs(45), "{spent:?}");
}

/// cmux#46584: the first start's machine was stuck and deleted, its fresh start was refused at the machine cap,
/// and `--make-room` started once more. The machine given up on stays in the final answer.
#[test]
fn a_make_room_rerun_keeps_the_machines_the_first_start_gave_up_on() {
    let free = json!({"machine": "vm-b", "name": "web", "reason": "failed_create"});
    let sent = exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n");
    let mut fake = Fake::new(steps(vec![
        vec![three_machines(), not_connected("chat-fresh", "vm-stuck")],
        stuck_then_deleted("vm-stuck"),
        vec![three_machines(), held_refusal(free)],
        vec![ok(json!({"deleted": true})), three_machines(), started(), sent],
    ]));
    let Outcome::Done(answer) = run(&mut fake, &request(&["--prompt", "hi", "--make-room"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["session_id"], "sess-1");
    assert_eq!(fake.ran[6], kill("vm-stuck"));
    assert_eq!(fake.ran[9], kill("vm-b"), "make-room freed the offered machine");
    let replaced =
        answer["fresh_retry"].as_array().expect("fresh_retry survives the make-room rerun");
    assert_eq!(replaced.len(), 1, "{replaced:?}");
    assert_eq!(replaced[0]["machine_id"], "vm-stuck");
    assert_eq!(replaced[0]["deleted"], true);
}

/// 22:11Z's second half: the machine linked, then its agent's identify timed out. The app answered at once,
/// within the bound: that start is stuck too.
#[test]
fn an_identify_timeout_on_a_new_machine_is_retried_on_a_fresh_one() {
    let mut fake = Fake::new(steps(vec![
        vec![signed_in(), identify_timed_out("chat-fresh", "vm-stuck")],
        stuck_then_deleted("vm-stuck"),
        vec![signed_in(), started()],
    ]));
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(answer["fresh_retry"][0]["why"], "app");
    assert_eq!(fake.ran[6], kill("vm-stuck"));
}

/// The fresh machine is stuck too: the run stops after one retry, both machines are deleted, and the answer
/// says so, with nothing left counting against the team's machines.
#[test]
fn a_second_stuck_machine_ends_the_run_with_both_deleted() {
    let mut fake = Fake::new(steps(vec![
        vec![signed_in(), not_connected("chat-fresh", "vm-a")],
        stuck_then_deleted("vm-a"),
        vec![signed_in(), not_connected("chat-fresh", "vm-b")],
        stuck_then_deleted("vm-b"),
    ]));
    let Outcome::Failed { error, exit } = run(&mut fake, &request(CWD)) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(exit, 1);
    assert_eq!(error["code"], STUCK_CODE);
    assert_eq!(fake.ran[6], kill("vm-a"));
    assert_eq!(fake.ran[13], kill("vm-b"));
    assert_eq!(fake.ran.len(), 14, "no third machine");
    let replaced: Vec<&Value> =
        error["details"]["fresh_retry"].as_array().unwrap().iter().collect();
    assert_eq!(replaced.len(), 2);
    assert!(replaced.iter().all(|row| row["deleted"] == true));
    assert_eq!(replaced[1]["facts"]["machine_id"], "vm-b", "each machine keeps its own facts");
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
    let mut fake = Fake::new(steps(vec![
        vec![signed_in(), not_connected("chat-fresh", "vm-stuck"), listed_stuck("vm-stuck")],
        unread(),
        vec![refused("no")],
    ]));
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
