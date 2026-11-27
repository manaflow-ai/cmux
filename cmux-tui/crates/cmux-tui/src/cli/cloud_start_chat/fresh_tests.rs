//! fresh.rs: a new machine that never comes up is given up within the bound, deleted, and the chat starts on a
//! fresh one (production 2026-11-17 22:11Z and 2026-11-18 00:21Z: `connect.link 180005 ms`, then failure).

use std::time::Duration;

use serde_json::{Value, json};

use super::super::fresh::{
    COLD_BOUND, LOOK_BOUND, RELEASE_WAIT, START_BOUND, STUCK_CODE, UP_BOUND,
};
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
        // At the bound the machine is read: running, so it is a hang, not a boot.
        listed_stuck("vm-stuck"),
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
    assert_eq!(fake.ran[2], strings(&["cloud", "list-machines", "--json"]), "read at the bound");
    assert_eq!(
        fake.ran[4],
        kill("vm-stuck"),
        "the stuck machine is deleted before the fresh start"
    );
    assert_eq!(starts(&fake), 2);
    let replaced = &answer["fresh_retry"][0];
    assert_eq!(replaced["machine_id"], "vm-stuck");
    assert_eq!(replaced["deleted"], true);
    assert_eq!(replaced["why"], "bound");
    // It names where it stopped: running, its session never up (a hang, not a boot).
    assert_eq!(replaced["stage"], "running", "{replaced}");
    // Given up at the bound, not after the app's 180 s: list 5 s, the start to the bound, its read there, then the
    // cleanup and the fresh start (5 s each).
    let spent = fake.clock.saturating_duration_since(began);
    assert_eq!(spent, Duration::from_secs(10) + START_BOUND + Duration::from_secs(20), "{spent:?}");
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

/// Production 2026-11-22 (job 137057804629): the Cloud service still held the stuck machine's create at
/// `approval.pending` when the bound passed, so the app listed it only as creating. The delete is tried again until
/// the machine is listed, then deleted, and the chat starts on a fresh machine.
#[test]
fn a_stuck_machine_whose_create_is_still_on_its_way_is_deleted_once_it_lands_and_replaced() {
    let creating = ok(json!({"account": {"signed_in": true}, "machines": [{"title": "dev"}],
                             "creating": [{"name": "chat-fresh"}]}));
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        creating.clone(),
        creating,
        listed_stuck("vm-stuck"),
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(fake.ran[5], kill("vm-stuck"));
    assert_eq!(starts(&fake), 2);
    assert_eq!(answer["fresh_retry"][0]["deleted"], true);
    assert_eq!(fake.paused, Duration::from_secs(6), "two waits before the create landed");
}

/// Production 2026-11-22 (job 137099694829): a long-idle spare began pausing just after its claim, and its delete
/// answered "This machine is pausing". The delete is tried again once it can be, then the chat starts on a fresh one.
#[test]
fn a_stuck_machine_that_is_pausing_is_deleted_once_it_can_be_and_replaced() {
    let pausing = Ran {
        code: 1,
        stderr: json!({"code": "unavailable",
                       "message": "This machine is pausing. Try again once it is paused."})
        .to_string(),
        ..Ran::default()
    };
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        pausing,
        listed_stuck("vm-stuck"),
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(starts(&fake), 2);
    assert_eq!(answer["fresh_retry"][0]["deleted"], true);
    assert_eq!(answer["fresh_retry"][0]["machine_id"], "vm-stuck");
}

/// A machine still creating after [`RELEASE_WAIT`] is left as before: no fresh machine, and the answer says how to
/// delete it.
#[test]
fn a_create_that_never_lands_within_the_release_wait_stops_the_retry() {
    let creating = ok(json!({"account": {"signed_in": true}, "machines": [],
                             "creating": [{"name": "chat-fresh", "stage": "approval.pending", "token": "x"}]}));
    let mut answers = vec![signed_in(), not_connected("chat-fresh", "vm-stuck")];
    answers.extend(std::iter::repeat_n(creating, 40));
    let mut fake = Fake::new(answers);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(CWD)) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(starts(&fake), 1);
    assert_eq!(error["details"]["fresh_retry"][0]["deleted"], false);
    // How far the create got is kept; a field not on the list is not.
    assert_eq!(
        error["details"]["fresh_retry"][0]["error"]["creating"],
        json!({"stage": "approval.pending"}),
        "{error}"
    );
    assert!(fake.paused <= RELEASE_WAIT, "{:?}", fake.paused);
    assert!(error["message"].as_str().unwrap().contains("could not be deleted"), "{error}");
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

/// A `--name` no machine has yet is made by this run, so it is as new as a fresh name's: AutoCloud 2026-11-27,
/// `start-chat --name lane-X` (tools/product_cloud_lanes.py) got the app's "didn't connect" and stopped there.
/// Now that machine is deleted and the chat starts on one made again under the same name.
#[test]
fn a_named_machine_this_run_makes_is_replaced_when_it_never_connects() {
    let listed_lane = |id: &str| {
        ok(json!({"account": {"signed_in": true},
                  "machines": [{"title": "dev"}, {"title": "lane-x", "machine_id": id, "status": "running"}]}))
    };
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("lane-x", "vm-stuck"),
        listed_lane("vm-stuck"),
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(&["--name", "lane-x"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(answer["fresh_retry"][0]["why"], "app");
    assert_eq!(fake.ran[3], kill("vm-stuck"));
    assert_eq!(starts(&fake), 2);
    let second = fake
        .ran
        .iter()
        .filter(|w| w.get(1).map(String::as_str) == Some("start-session"))
        .nth(1)
        .unwrap();
    assert!(
        second.windows(2).any(|w| w[0] == "--name" && w[1] == "lane-x"),
        "made again under its name: {second:?}"
    );
}

/// A `--name` whose machine is listed is the caller's: never bounded, deleted or replaced, even on "didn't connect".
#[test]
fn a_listed_named_machine_that_never_connects_is_kept() {
    let mut fake = Fake::new(vec![
        ok(
            json!({"account": {"signed_in": true}, "machines": [{"title": "lane-x", "machine_id": "vm-lane"}]}),
        ),
        not_connected("lane-x", "vm-lane"),
    ]);
    fake.slow.push((1, Duration::from_secs(180)));
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--name", "lane-x"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["code"], "unavailable");
    assert_eq!(fake.ran.len(), 2, "no delete and no second start: {:?}", fake.ran);
}

fn agent_refused(code: &str) -> Ran {
    Ran {
        code: 1,
        stderr: json!({"code": "unavailable", "message": format!(
            "Machine `chat-fresh` started but its agent didn't ({code}). Run `cmux cloud start-session --target machine:vm-failed --agent codex` again."
        )}).to_string(),
        ..Ran::default()
    }
}

#[test]
fn a_refused_codex_start_deletes_its_new_machine_without_retrying() {
    let mut fake = Fake::new(vec![
        signed_in(),
        agent_refused("agent_session.bad_request"),
        listed_stuck("vm-failed"),
        ok(json!({"deleted": true})),
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--agent", "codex"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(exit, 1);
    assert_eq!(error["code"], "unavailable");
    assert_eq!(error["details"]["cleanup"]["machine_id"], "vm-failed");
    assert_eq!(error["details"]["cleanup"]["deleted"], true);
    assert_eq!(fake.ran[3], kill("vm-failed"));
    assert_eq!(starts(&fake), 1, "a bad request is not a reason to create another machine");
    let message = error["message"].as_str().unwrap();
    assert!(message.contains("agent_session.bad_request") && message.contains("was deleted"));
    assert!(!message.contains("start-session --target"), "no retry on the deleted machine");
    assert!(
        error["details"]["app"]["message"].as_str().unwrap().contains("start-session --target")
    );
}

#[test]
fn a_refused_start_never_deletes_an_existing_named_or_targeted_machine() {
    for args in [&["--name", "dev"][..], &["--target", "machine:vm-existing"]] {
        let mut fake = Fake::new(vec![signed_in(), agent_refused("agent_session.bad_request")]);
        let Outcome::Failed { error, .. } = run(&mut fake, &request(args)) else {
            panic!("{:?}", fake.ran)
        };
        assert!(error["details"]["cleanup"].is_null());
        assert_eq!(fake.ran.len(), 2, "no delete: {:?}", fake.ran);
    }
}

#[test]
fn a_refused_start_deletes_the_machine_it_just_created_in_an_environment() {
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        agent_refused("agent_session.bad_request"),
        ok(json!({"deleted": true})),
    ]);
    let Outcome::Failed { error, .. } =
        run(&mut fake, &request(&["--agent", "codex", "--environment", "env_1"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(fake.ran[3], kill("vm-1"));
    assert_eq!(error["details"]["cleanup"]["machine_id"], "vm-1");
    assert_eq!(error["details"]["cleanup"]["deleted"], true);
    assert_eq!(starts(&fake), 1);
}

#[test]
fn cleanup_crossing_the_deadline_keeps_the_refusal_and_deletion_receipt() {
    let mut fake = Fake::new(vec![
        signed_in(),
        agent_refused("agent_session.bad_request"),
        listed_stuck("vm-failed"),
        ok(json!({"deleted": true})),
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &request(&["--timeout", "15"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(exit, 1);
    assert_eq!(error["code"], "unavailable");
    assert_eq!(error["details"]["cleanup"]["deleted"], true);
    assert_eq!(fake.ran[3], kill("vm-failed"));
    assert!(error["details"]["again"].is_null(), "no pending retry on a deleted machine");
}

#[test]
fn a_refused_start_reports_failed_cleanup_and_keeps_the_original_refusal() {
    let mut fake = Fake::new(vec![
        signed_in(),
        agent_refused("agent_session.harness_missing"),
        listed_stuck("vm-failed"),
        Ran { code: 1, stderr: "delete unavailable".to_owned(), ..Ran::default() },
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--agent", "codex"])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["details"]["cleanup"]["deleted"], false);
    let message = error["message"].as_str().unwrap();
    assert!(message.contains("agent_session.harness_missing"));
    assert!(message.contains("kill-machine --target machine:vm-failed --confirm"));
    assert_eq!(starts(&fake), 1);
}

#[test]
fn a_refused_start_does_not_call_an_unloaded_machine_list_cleaned_up() {
    let mut fake = Fake::new(vec![
        signed_in(),
        agent_refused("agent_session.bad_request"),
        ok(json!({"loaded": false, "machines": []})),
    ]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&[])) else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["details"]["cleanup"]["deleted"], false);
    assert_eq!(fake.ran.len(), 3, "no guessed delete");
}

#[test]
fn a_lost_start_reply_never_deletes_a_machine_that_may_have_a_running_agent() {
    let mut fake = Fake::new(vec![
        signed_in(),
        Ran { code: 1, stderr: "app connection closed".to_owned(), ..Ran::default() },
    ]);
    assert!(matches!(run(&mut fake, &request(&[])), Outcome::Failed { .. }));
    assert_eq!(fake.ran.len(), 2);
}

/// 2026-11-23 (cmux-platform#1719): a stuck machine is asked why before its delete, over the exec route, and what
/// it said rides on its `fresh_retry` row and in the run's progress; the look is bounded and the start goes on.
#[test]
fn a_stuck_machine_is_looked_at_before_its_delete() {
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    let said = "resolv: nameserver 10.0.0.2 \nhost api.example dns=fail http=000\ncmux-host: activating\n\
                2026-11-23T22:08:01 cmux-host: relay connect failed: dns error\n";
    fake.look = Some(ok(json!({"exit_code": 0, "stdout": said, "stderr": ""})));
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(fake.looked.len(), 1, "one look, at the stuck machine");
    let look = &fake.looked[0];
    assert_eq!(look[..4], strings(&["cloud", "exec", "--target", "machine:vm-stuck"]));
    let script = &look[5];
    assert!(script.starts_with("timeout -k 1 "), "bounded on the machine: {script}");
    let seconds: u64 = script.split_whitespace().nth(3).unwrap().parse().unwrap();
    assert!(seconds < LOOK_BOUND.as_secs(), "{script}");
    assert_eq!(fake.ran[3], kill("vm-stuck"), "deleted after the look");
    let guest = &answer["fresh_retry"][0]["guest"];
    assert_eq!(guest["stdout"], said);
    assert!(
        fake.said[0].contains("host api.example dns=fail http=000; cmux-host: activating"),
        "{:?}",
        fake.said
    );
}

/// A look the exec route refuses keeps its error as evidence and changes nothing else.
#[test]
fn a_refused_look_is_kept_and_the_delete_goes_on() {
    let mut fake = Fake::new(vec![
        signed_in(),
        not_connected("chat-fresh", "vm-stuck"),
        listed_stuck("vm-stuck"),
        ok(json!({"deleted": true})),
        signed_in(),
        started(),
    ]);
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    let guest = &answer["fresh_retry"][0]["guest"];
    assert_eq!(guest["error"]["message"], "no exec here", "{guest}");
    // What the service listed of it outlives the delete, when the machine itself cannot answer.
    assert_eq!(guest["listed"], json!({"status": "running"}), "{guest}");
    assert_eq!(fake.said.len(), 1, "only the retry is said: {:?}", fake.said);
}

/// The app's list with the new machine `chat-fresh` still coming up: its create on its way (no `status`), or listed
/// with `status`.
fn listed_booting(status: Option<&str>) -> Ran {
    match status {
        None => ok(json!({"account": {"signed_in": true}, "machines": [{"title": "dev"}],
                          "creating": [{"name": "chat-fresh"}]})),
        Some(status) => ok(json!({"account": {"signed_in": true},
                                  "machines": [{"title": "dev"},
                                               {"title": "chat-fresh", "machine_id": "vm-cold", "status": status}]})),
    }
}

/// Production 2026-11-26 (`app-chat-production`, run 45723457278): every stuck machine was a cold create (no spare),
/// whose create was still on its way at 90 s and whose guest daemon spawned at the 90 s mark; the start would have
/// answered at about 110 s. It is waited on while it boots, never deleted, and the chat starts on it.
#[test]
fn a_cold_machine_still_booting_at_the_bound_is_waited_on_and_starts_at_110_s() {
    let mut answers = vec![signed_in(), started()];
    // Read at the bound (create on its way), then 10 s on (provisioning); the start answers before the next read.
    answers.extend([listed_booting(None), listed_booting(Some("provisioning"))]);
    let mut fake = Fake::new(answers);
    fake.slow.push((1, Duration::from_secs(110)));
    let began = fake.clock;
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(answer["session_id"], "sess-1");
    assert_eq!(starts(&fake), 1, "no second machine: {:?}", fake.ran);
    assert!(!fake.ran.iter().any(|step| step.get(1).map(String::as_str) == Some("kill-machine")));
    assert!(answer["fresh_retry"].is_null(), "{answer}");
    assert!(fake.said.is_empty(), "{:?}", fake.said);
    // The list, then the start's own 110 s.
    let spent = fake.clock.saturating_duration_since(began);
    assert_eq!(spent, Duration::from_secs(5) + Duration::from_secs(110), "{spent:?}");
}

/// A machine that boots and then never connects (the 11-17 hang, on a cold machine) is still given up: once it runs
/// it has [`UP_BOUND`], and the whole start never goes past [`COLD_BOUND`].
#[test]
fn a_cold_machine_that_boots_and_then_hangs_is_given_up_within_the_cold_bound() {
    let mut answers = vec![signed_in(), not_connected("chat-fresh", "vm-cold")];
    answers.push(listed_booting(Some("provisioning")));
    answers.extend(std::iter::repeat_n(listed_booting(Some("running")), 2));
    answers.extend([listed_stuck("vm-cold"), ok(json!({"deleted": true})), signed_in(), started()]);
    let mut fake = Fake::new(answers);
    fake.slow.push((1, Duration::from_secs(400)));
    let began = fake.clock;
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    let replaced = &answer["fresh_retry"][0];
    assert_eq!(replaced["why"], "bound");
    assert_eq!(replaced["deleted"], true);
    assert_eq!(replaced["stage"], "running", "booted, then hung: {replaced}");
    assert_eq!(starts(&fake), 2);
    // From the start: the bound at 90 s, read (provisioning) to 95 s, 10 s on; read (running) to 110 s, then
    // UP_BOUND on; read (running) again: given up 175 s after the start, inside COLD_BOUND. Before it the run's list,
    // after it the release's list and kill, the fresh list and start (5 s each).
    let start = START_BOUND + Duration::from_secs(5 + 10 + 5) + UP_BOUND + Duration::from_secs(5);
    assert!(start <= COLD_BOUND, "{start:?}");
    let spent = fake.clock.saturating_duration_since(began);
    assert_eq!(spent, Duration::from_secs(5) + start + Duration::from_secs(20), "{spent:?}");
}

/// A machine that never stops booting is given up at [`COLD_BOUND`] from its start, not left waiting.
#[test]
fn a_machine_that_never_finishes_booting_is_given_up_at_the_cold_bound() {
    let mut answers = vec![signed_in(), not_connected("chat-fresh", "vm-cold")];
    answers.extend(std::iter::repeat_n(listed_booting(None), 6));
    answers.extend([listed_stuck("vm-cold"), ok(json!({"deleted": true})), signed_in(), started()]);
    let mut fake = Fake::new(answers);
    fake.slow.push((1, Duration::from_secs(400)));
    let began = fake.clock;
    let Outcome::Done(answer) = run(&mut fake, &request(CWD)) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["fresh_retry"][0]["why"], "bound");
    // Its create never landed: the give-up says so, not just "didn't connect".
    assert_eq!(answer["fresh_retry"][0]["stage"], "creating", "{answer}");
    assert_eq!(starts(&fake), 2);
    let reads = fake
        .ran
        .iter()
        .take_while(|step| step.get(1).map(String::as_str) != Some("kill-machine"))
        .filter(|step| step.get(1).map(String::as_str) == Some("list-machines"))
        .count();
    // The run's first list, the reads at 90, 105, ..., 165 s after the start (each 5 s, then 10 s on), the release's.
    assert_eq!(reads, 1 + 6 + 1, "{:?}", fake.ran);
    let spent = fake.clock.saturating_duration_since(began);
    assert_eq!(spent, Duration::from_secs(5) + COLD_BOUND + Duration::from_secs(20), "{spent:?}");
}

/// cmux#47002 review, 2026-11-22: the app refused before any machine was made (no Cloud connection serves
/// claude, `agent_session.harness_missing`). The run already read the list and found no machine of its fresh
/// name, so nothing is deleted, no second list is read, and the answer keeps this run's own retry: it never
/// says a machine "was deleted" that never existed.
#[test]
fn a_refusal_before_any_machine_reports_no_deletion_and_keeps_its_retry() {
    let setup = "No Cloud connection serves claude yet (agent_session.harness_missing). Add one in Settings > \
                 Cloud, then run `cmux cloud start-session --name chat-fresh --agent claude` again.";
    let refused = Ran {
        code: 1,
        stderr: json!({"code": "unavailable", "message": setup}).to_string(),
        ..Ran::default()
    };
    let mut fake = Fake::new(vec![signed_in(), refused, signed_in(), signed_in()]);
    let Outcome::Failed { error, .. } = run(&mut fake, &request(&["--prompt", "x", "--wait"]))
    else {
        panic!("{:?}", fake.ran)
    };
    let message = error["message"].as_str().unwrap();
    assert!(!message.contains("was deleted"), "{message}");
    assert!(message.contains("cmux cloud start-chat --prompt TEXT --wait --json"), "{message}");
    assert!(error["details"]["cleanup"].is_null(), "{error}");
    let lists = fake.ran.iter().filter(|step| step[1] == "list-machines").count();
    assert_eq!(lists, 2, "one list before the start, one to prove no machine: {:?}", fake.ran);
}

/// cmux#47002 review, 2026-11-22: a machine the rollback deleted is not handed to the caller to delete again.
#[test]
fn a_rolled_back_machine_is_not_named_for_the_caller_to_delete() {
    let mut fake = Fake::new(vec![
        signed_in(),
        made(),
        agent_refused("agent_session.bad_request"),
        ok(json!({"deleted": true})),
    ]);
    let Outcome::Failed { error, .. } =
        run(&mut fake, &request(&["--agent", "codex", "--environment", "env_1"]))
    else {
        panic!("{:?}", fake.ran)
    };
    assert_eq!(error["details"]["cleanup"]["deleted"], true);
    assert!(error["details"]["new_machine"].is_null(), "{error}");
    assert!(error["details"]["machine_id"].is_null(), "{error}");
}
