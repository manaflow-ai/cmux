//! The daemon's sandboxed Runs against fake steps: a reply, a failure, a timeout, a cancel, the
//! cleanup after each, a restart that resumes it, and one Run per idempotency key.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::*;

/// Steps whose task ends as `outcome` (or, `None`, only at a cancel) and whose removals answer
/// `removals` in turn (then `Gone`). The app's account is `account` (`team:team_1` unless a test
/// switches it; `None`: signed out), after the answers queued in `accounts`; every remove's
/// scope is kept.
struct Fake {
    outcome: Mutex<Option<Outcome>>,
    removals: Mutex<Vec<Removal>>,
    ran: Mutex<Vec<Task>>,
    removed: Mutex<Vec<(String, Option<String>)>>,
    scopes: Mutex<Vec<Option<String>>>,
    account: Mutex<Option<String>>,
    accounts: Mutex<Vec<Option<String>>>,
    removes: AtomicUsize,
    /// What [`Steps::elsewhere`] answers, and each remove's `elsewhere`.
    others: Mutex<Vec<String>>,
    elsewheres: Mutex<Vec<Vec<String>>>,
}

impl Fake {
    fn new(outcome: Option<Outcome>, removals: Vec<Removal>) -> Arc<Self> {
        Arc::new(Fake {
            outcome: Mutex::new(outcome),
            removals: Mutex::new(removals),
            ran: Mutex::new(Vec::new()),
            removed: Mutex::new(Vec::new()),
            scopes: Mutex::new(Vec::new()),
            account: Mutex::new(Some("user:u1|team:team_1".into())),
            accounts: Mutex::new(Vec::new()),
            removes: AtomicUsize::new(0),
            others: Mutex::new(Vec::new()),
            elsewheres: Mutex::new(Vec::new()),
        })
    }
}

impl Steps for Fake {
    fn scope(&self) -> Option<String> {
        let mut queued = self.accounts.lock().unwrap();
        if queued.is_empty() { self.account.lock().unwrap().clone() } else { queued.remove(0) }
    }

    fn run(&self, task: &Task, cancel: &AtomicBool) -> Outcome {
        self.ran.lock().unwrap().push(task.clone());
        if let Some(outcome) = self.outcome.lock().unwrap().clone() {
            return outcome;
        }
        let began = Instant::now();
        // The test's bound: a fake that is never cancelled still ends.
        while !cancel.load(Ordering::Acquire) && began.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(5));
        }
        Outcome::Cancelled { machine: Some("m-1".into()) }
    }

    fn elsewhere(&self, _run: &str) -> Vec<String> {
        self.others.lock().unwrap().clone()
    }

    fn remove(
        &self,
        machine_name: &str,
        machine: Option<&str>,
        scope: Option<&str>,
        elsewhere: &[String],
    ) -> Removal {
        self.elsewheres.lock().unwrap().push(elsewhere.to_vec());
        self.removes.fetch_add(1, Ordering::AcqRel);
        self.scopes.lock().unwrap().push(scope.map(str::to_owned));
        self.removed.lock().unwrap().push((machine_name.to_owned(), machine.map(str::to_owned)));
        let mut removals = self.removals.lock().unwrap();
        if removals.is_empty() { Removal::Gone } else { removals.remove(0) }
    }
}

fn quick() -> Timing {
    Timing {
        retry_first: Duration::from_millis(5),
        retry_max: Duration::from_millis(20),
        give_up: Duration::from_secs(60),
        keep_ended: Duration::from_secs(60),
        start_settle: Duration::ZERO,
    }
}

fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap()
}

/// A create of the task `say hi` sent under user u1 in `team_1`.
fn create(engine: &Arc<Engine>, key: &str) -> Value {
    create_in(engine, key, "team_1")
}

/// A create sent under user u1 in `team`.
fn create_in(engine: &Arc<Engine>, key: &str, team: &str) -> Value {
    engine.perform("runs.create", &args(body(key, team))).unwrap()
}

fn body(key: &str, team: &str) -> Value {
    json!({ "task": "say hi", "agent": "claude", "timeoutMs": 30_000, "idempotencyKey": key,
            "expectedAccount": { "user_id": "u1", "team_id": team } })
}

/// Waits (at most 5 s) until `id`'s receipt says the cleanup is `cleanup`.
fn settled(engine: &Arc<Engine>, id: &str, cleanup: &str) -> Value {
    let began = Instant::now();
    loop {
        let snapshot =
            engine.perform("runs.wait", &args(json!({ "id": id, "timeoutMs": 200 }))).unwrap();
        if snapshot["receipt"]["cleanup"] == cleanup || began.elapsed() > Duration::from_secs(5) {
            return snapshot;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn a_run_answers_the_reply_and_deletes_its_machine() {
    let fake = Fake::new(
        Some(Outcome::Replied {
            reply: "\u{1b}[1mhi\u{1b}[0m there".into(),
            machine: Some("m-7".into()),
        }),
        vec![],
    );
    let engine = Engine::open(None, fake.clone(), quick());
    let created = create(&engine, "k1");
    let id = created["id"].as_str().unwrap().to_owned();
    assert_eq!(created["environment"], "sandboxed");
    assert_eq!(created["attempts"][0]["ordinal"], 1);
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["run"]["status"], "succeeded");
    assert_eq!(snapshot["receipt"]["status"], "succeeded");
    assert_eq!(snapshot["receipt"]["reply"], "hi there");
    assert_eq!(snapshot["receipt"]["exitCode"], 0);
    assert_eq!(snapshot["receipt"]["timedOut"], false);
    assert_eq!(snapshot["receipt"]["cost"], Value::Null);
    assert_eq!(snapshot["artifacts"], json!([]));
    let ran = fake.ran.lock().unwrap().clone();
    assert_eq!(ran.len(), 1);
    // The task carries the Run's account, which its start and send are bound to.
    assert_eq!(ran[0].account, "user:u1|team:team_1");
    assert_eq!(ran[0].prompt, "say hi");
    assert_eq!(ran[0].agent, "claude");
    assert_eq!(ran[0].machine_name, format!("{MACHINE_PREFIX}{id}"));
    assert_eq!(ran[0].timeout, Duration::from_millis(30_000));
    assert_eq!(
        fake.removed.lock().unwrap()[0],
        (format!("{MACHINE_PREFIX}{id}"), Some("m-7".into()))
    );
}

#[test]
fn a_timeout_is_a_failed_receipt_that_says_so_and_its_machine_still_goes() {
    let fake = Fake::new(Some(Outcome::TimedOut { machine: Some("m-t".into()) }), vec![]);
    let engine = Engine::open(None, fake.clone(), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["receipt"]["cleanup"], "destroyed");
    assert_eq!(snapshot["receipt"]["status"], "failed");
    assert_eq!(snapshot["receipt"]["timedOut"], true);
    assert_eq!(snapshot["attempts"][0]["status"], "expired");
    assert_eq!(fake.removes.load(Ordering::Acquire), 1);
}

#[test]
fn a_cancel_stops_the_task_and_deletes_the_machine() {
    let fake = Fake::new(None, vec![]);
    let engine = Engine::open(None, fake.clone(), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    // The task is running (the fake waits for the cancel).
    let began = Instant::now();
    while fake.ran.lock().unwrap().is_empty() && began.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(2));
    }
    let cancelled = engine.perform("runs.cancel", &args(json!({ "id": id }))).unwrap();
    assert_eq!(cancelled["run"]["status"], "cancelled");
    assert_eq!(cancelled["receipt"]["status"], "cancelled");
    assert!(cancelled["run"]["cancelRequestedAt"].is_string());
    settled(&engine, &id, "destroyed");
    assert_eq!(fake.removed.lock().unwrap()[0].1.as_deref(), Some("m-1"));
}

#[test]
fn a_failed_delete_is_tried_again_until_the_machine_goes() {
    let fake = Fake::new(
        Some(Outcome::Failed {
            code: "chat.turn_failed".into(),
            message: "the turn ended failed".into(),
            reply: Some("oops".into()),
            machine: None,
        }),
        vec![Removal::Later("app not running".into()), Removal::Later("again".into())],
    );
    let engine = Engine::open(None, fake.clone(), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["receipt"]["status"], "failed");
    assert_eq!(snapshot["receipt"]["reply"], "oops");
    assert!(snapshot["receipt"]["error"].as_str().unwrap().starts_with("chat.turn_failed"));
    assert_eq!(fake.removes.load(Ordering::Acquire), 3);
}

#[test]
fn gone_counts_only_after_a_cut_off_start_could_still_make_the_machine() {
    let fake = Fake::new(Some(Outcome::TimedOut { machine: None }), vec![Removal::Gone]);
    // The settle time is the task's timeout (30 s) past its create: far off.
    let engine = Engine::open(
        None,
        fake.clone(),
        Timing { start_settle: Duration::from_secs(60), ..quick() },
    );
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(
        snapshot["receipt"]["cleanup"], "pending",
        "a list without the machine is not proof yet"
    );
    assert!(fake.removes.load(Ordering::Acquire) >= 2, "it is read again before the settle time");
}

#[test]
fn a_restart_ends_a_run_that_was_going_and_resumes_its_cleanup() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("cloud-runs.json");
    let blocked = Fake::new(None, vec![]);
    let first = Engine::open(Some(store.clone()), blocked.clone(), quick());
    let id = create(&first, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let began = Instant::now();
    while blocked.ran.lock().unwrap().is_empty() && began.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(2));
    }
    let saved = std::fs::read_to_string(&store).unwrap();
    assert!(saved.contains(&id) && saved.contains("\"running\""), "{saved}");
    assert!(!saved.contains("say hi"), "the task text is never written");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(std::fs::metadata(&store).unwrap().permissions().mode() & 0o777, 0o600);
    }
    // A new daemon over the same store (the old one's thread is left blocked, as a dead daemon's is).
    let fake = Fake::new(None, vec![]);
    let second = Engine::open(Some(store), fake.clone(), quick());
    let snapshot = settled(&second, &id, "destroyed");
    assert_eq!(snapshot["run"]["status"], "failed");
    assert!(snapshot["receipt"]["error"].as_str().unwrap().contains("restarted"));
    assert_eq!(fake.removed.lock().unwrap()[0].0, format!("{MACHINE_PREFIX}{id}"));
    assert_eq!(
        fake.scopes.lock().unwrap()[0].as_deref(),
        Some("user:u1|team:team_1"),
        "the scope read at the start is the cleanup's after a restart"
    );
    assert!(fake.ran.lock().unwrap().is_empty(), "nothing runs again");
    first.perform("runs.cancel", &args(json!({ "id": id }))).unwrap();
}

#[test]
fn the_same_key_answers_the_same_run_and_another_body_is_a_conflict() {
    let fake = Fake::new(Some(Outcome::Replied { reply: "ok".into(), machine: None }), vec![]);
    let engine = Engine::open(None, fake.clone(), quick());
    let first = create(&engine, "same");
    let again = create(&engine, "same");
    assert_eq!(first["id"], again["id"]);
    let conflict = engine
        .perform("runs.create", &args(json!({ "task": "other", "agent": "claude", "timeoutMs": 30_000, "idempotencyKey": "same",
                                               "expectedAccount": { "user_id": "u1", "team_id": "team_1" } })))
        .unwrap_err();
    assert_eq!(
        conflict,
        Failure::http(
            409,
            Some("run_idempotency_conflict".into()),
            Some("this idempotency key named another Run".into())
        )
    );
    settled(&engine, first["id"].as_str().unwrap(), "destroyed");
    assert_eq!(fake.ran.lock().unwrap().len(), 1);
}

/// Codex's BLOCK at 1bf18b3d (F1): a create made under account A whose answer was lost, retried
/// after the app switched to B, never becomes a second Run under B, which would send A's task to
/// B's machine.
#[test]
fn a_retry_after_an_account_switch_is_refused_never_rebound() {
    let fake = Fake::new(Some(Outcome::Replied { reply: "ok".into(), machine: None }), vec![]);
    let engine = Engine::open(None, fake.clone(), quick());
    let first = create(&engine, "same");
    settled(&engine, first["id"].as_str().unwrap(), "destroyed");
    *fake.account.lock().unwrap() = Some("user:u1|team:team_2".into());
    // The retry names team_2 (its first answer lost, read again after the switch): the key alone refuses it.
    let retry = engine.perform("runs.create", &args(body("same", "team_2"))).unwrap_err();
    assert!(
        matches!(&retry, Failure::Http { status: 409, code: Some(code), .. } if code == "run_account_changed"),
        "{retry:?}"
    );
    assert_eq!(fake.ran.lock().unwrap().len(), 1, "B's machine never got A's task");
    // Another key under B is B's own Run.
    let other = create_in(&engine, "other", "team_2");
    assert_ne!(other["id"], first["id"]);
}

/// The account the send was made under (`expectedAccount`, as the app read it at the send) must
/// still be the app's: a send whose app switched since starts nothing, retry or not.
#[test]
fn a_create_for_another_account_than_the_apps_starts_nothing() {
    let fake = Fake::new(Some(Outcome::Replied { reply: "ok".into(), machine: None }), vec![]);
    *fake.account.lock().unwrap() = Some("user:u2|team:t1".into());
    let engine = Engine::open(None, fake.clone(), quick());
    let body = |user: &str, team: Value| {
        args(json!({ "task": "say hi", "timeoutMs": 30_000, "idempotencyKey": user,
                     "expectedAccount": { "user_id": user, "team_id": team } }))
    };
    for (user, team) in [("u1", json!("t1")), ("u2", json!("t2")), ("u2", Value::Null)] {
        let refused = engine.perform("runs.create", &body(user, team.clone())).unwrap_err();
        assert!(
            matches!(&refused, Failure::Http { status: 409, code: Some(code), .. } if code == "run_account_changed"),
            "{user} {team}: {refused:?}"
        );
    }
    assert!(engine.perform("runs.create", &body("u2", json!("t1"))).is_ok());
    let began = Instant::now();
    while fake.ran.lock().unwrap().is_empty() && began.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(fake.ran.lock().unwrap().len(), 1);
}

#[test]
fn a_create_that_is_not_one_is_refused_and_runs_nothing() {
    let fake = Fake::new(None, vec![]);
    let engine = Engine::open(None, fake.clone(), quick());
    let cases = [
        (json!({ "idempotencyKey": "k" }), "run_task_required"),
        (json!({ "task": "  ", "idempotencyKey": "k" }), "run_task_required"),
        (json!({ "task": "hi", "agent": "bash", "idempotencyKey": "k" }), "run_agent_invalid"),
        (json!({ "task": "hi", "timeoutMs": 1000, "idempotencyKey": "k" }), "run_timeout_invalid"),
        (json!({ "task": "hi", "image": "img_1", "idempotencyKey": "k" }), "run_image_invalid"),
        (json!({ "task": "hi" }), "run_idempotency_required"),
        // Every create names the account it was sent under (Codex's review of #39022 at
        // 551a7dca, F1): none is taken as whatever account the app is on by then.
        (
            json!({ "task": "hi", "timeoutMs": 30_000, "idempotencyKey": "k" }),
            "run_account_required",
        ),
        (
            json!({ "task": "hi", "timeoutMs": 30_000, "idempotencyKey": "k", "expectedAccount": "u1" }),
            "run_account_required",
        ),
    ];
    for (body, code) in cases {
        let failure = engine.perform("runs.create", &args(body)).unwrap_err();
        assert!(
            matches!(&failure, Failure::Http { status: 400, code: Some(c), .. } if c == code),
            "{failure:?}"
        );
    }
    let missing = engine.perform("runs.wait", &args(json!({ "id": "run_nope" }))).unwrap_err();
    assert!(matches!(missing, Failure::Http { status: 404, .. }));
    assert!(fake.ran.lock().unwrap().is_empty());
}

#[test]
fn a_wait_holds_at_most_its_bound_and_answers_no_receipt_while_running() {
    let fake = Fake::new(None, vec![]);
    let engine = Engine::open(None, fake, quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let began = Instant::now();
    let snapshot =
        engine.perform("runs.wait", &args(json!({ "id": id, "timeoutMs": 50 }))).unwrap();
    assert!(began.elapsed() < Duration::from_secs(2));
    assert_eq!(snapshot["receipt"], Value::Null);
    assert!(matches!(snapshot["run"]["status"].as_str(), Some("queued" | "running")));
    engine.perform("runs.cancel", &args(json!({ "id": id }))).unwrap();
}

#[test]
fn run_sandbox_answers_the_final_snapshot() {
    let fake = Fake::new(Some(Outcome::Replied { reply: "done".into(), machine: None }), vec![]);
    let engine = Engine::open(None, fake, quick());
    let snapshot = engine
        .perform(
            "runs.sandbox",
            &args(json!({ "task": "hi", "timeoutMs": 30_000, "idempotencyKey": "k",
                          "expectedAccount": { "user_id": "u1", "team_id": "team_1" } })),
        )
        .unwrap();
    assert_eq!(snapshot["receipt"]["reply"], "done");
}

#[test]
fn a_reply_keeps_no_terminal_controls_and_only_its_end() {
    assert_eq!(clean_reply("\u{1b}]0;title\u{7}a\u{0}b\tc\n"), "ab\tc");
    let long = format!("start{}", "x".repeat(REPLY_MAX_CHARS + 10));
    let cleaned = clean_reply(&long);
    assert_eq!(cleaned.chars().count(), REPLY_MAX_CHARS);
    assert!(cleaned.starts_with('…') && cleaned.ends_with('x'));
}

#[test]
fn times_are_iso_8601() {
    assert_eq!(iso(Some(0)), json!("1970-01-01T00:00:00.000Z"));
    assert_eq!(iso(Some(1_762_646_400_123)), json!("2025-11-09T00:00:00.123Z"));
    assert_eq!(iso(None), Value::Null);
}

#[test]
fn another_accounts_wait_or_cancel_reads_nothing_and_never_says_gone() {
    let fake = Fake::new(None, vec![]);
    let engine = Engine::open(None, fake.clone(), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    // Signed in to another account (409) or signed out (401), from the very next call (the
    // account is read for every wait and cancel, never reused). Never 404 (Codex's BLOCK at
    // 1bf18b3d, F2): a follower takes 403 and 404 as the Run gone and forgets it, so a switch back
    // could never find it again.
    for (account, status, code) in
        [(Some("user:u1|team:team_2"), 409, "run_other_account"), (None, 401, "run_not_signed_in")]
    {
        *fake.account.lock().unwrap() = account.map(str::to_owned);
        for call in [
            engine.perform("runs.wait", &args(json!({ "id": id, "timeoutMs": 10 }))),
            engine.perform("runs.cancel", &args(json!({ "id": id }))),
        ] {
            let failure = call.unwrap_err();
            assert!(
                matches!(&failure, Failure::Http { status: s, code: Some(c), .. } if *s == status && c == code),
                "{account:?}: {failure:?}"
            );
        }
    }
    // A Run that does not exist is still 404.
    let missing = engine.perform("runs.wait", &args(json!({ "id": "run_none", "timeoutMs": 10 })));
    assert!(
        matches!(&missing.unwrap_err(), Failure::Http { status: 404, .. }),
        "no such Run is 404"
    );
    // Back on the Run's own account: it is there, and the other account's cancel did nothing.
    *fake.account.lock().unwrap() = Some("user:u1|team:team_1".into());
    let snapshot =
        engine.perform("runs.wait", &args(json!({ "id": id, "timeoutMs": 10 }))).unwrap();
    assert!(snapshot["run"]["cancelRequestedAt"].is_null());
    engine.perform("runs.cancel", &args(json!({ "id": id }))).unwrap();
}

#[test]
fn a_create_with_no_signed_in_app_is_refused() {
    let fake = Fake::new(None, vec![]);
    *fake.account.lock().unwrap() = None;
    let engine = Engine::open(None, fake.clone(), quick());
    let body = json!({ "task": "hi", "timeoutMs": 30_000, "idempotencyKey": "k" });
    let failure = engine.perform("runs.create", &args(body)).unwrap_err();
    assert!(
        matches!(&failure, Failure::Http { status: 401, code: Some(code), .. } if code == "run_not_signed_in"),
        "{failure:?}"
    );
    assert!(fake.ran.lock().unwrap().is_empty());
}

#[test]
fn a_run_whose_account_changed_before_its_launch_never_runs() {
    let fake = Fake::new(Some(Outcome::Replied { reply: "x".into(), machine: None }), vec![]);
    // The create reads team_1; by the launch the app is on team_2.
    *fake.accounts.lock().unwrap() =
        vec![Some("user:u1|team:team_1".into()), Some("user:u1|team:team_2".into())];
    let engine = Engine::open(None, fake.clone(), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    // The launch takes the queued team_2 read; only then does a wait read the app (team_1).
    let began = Instant::now();
    while !fake.accounts.lock().unwrap().is_empty() && began.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(2));
    }
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["receipt"]["status"], "failed");
    assert!(snapshot["receipt"]["error"].as_str().unwrap().starts_with("run.account_changed"));
    assert_eq!(snapshot["receipt"]["cleanup"], "destroyed", "nothing started, nothing to delete");
    assert!(fake.ran.lock().unwrap().is_empty(), "the task never reached the other account");
    assert_eq!(fake.removes.load(Ordering::Acquire), 0);
}

#[test]
fn a_runs_reply_outlives_a_restart_but_an_incognito_ones_never_reaches_the_file() {
    // Codex's review of #39022 at 551a7dca (F2): a Run that ended answers its reply and error after
    // the daemon starts again (its machine is deleted, so nothing else has them); an incognito
    // send's never touch the file. At 946e940e (F1): an incognito send never starts a Run here at
    // all (it would be an ordinary chat in the app); classic Cloud runs it.
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("cloud-runs.json");
    let failed = || {
        Some(Outcome::Failed {
            code: "chat.turn_failed".into(),
            message: "the-error-text".into(),
            reply: Some("the-reply-text".into()),
            machine: Some("m-1".into()),
        })
    };
    let engine = Engine::open(Some(store.clone()), Fake::new(failed(), vec![]), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    settled(&engine, &id, "destroyed");
    let mut incognito = body("private", "team_1");
    incognito["incognito"] = json!(true);
    let refused = engine.perform("runs.create", &args(incognito)).unwrap_err();
    assert!(
        matches!(&refused, Failure::Http { status: 409, code: Some(code), .. } if code == "run_incognito_unavailable"),
        "{refused:?}"
    );
    // The store holds the ordinary Run's answer once, and nothing of the incognito send.
    let saved = std::fs::read_to_string(&store).unwrap();
    assert_eq!(saved.matches("the-reply-text").count(), 1, "{saved}");
    assert_eq!(saved.matches("the-error-text").count(), 1, "{saved}");
    assert!(!saved.contains("private"), "{saved}");
    // A new daemon over the same store.
    let reopened = Engine::open(Some(store), Fake::new(None, vec![]), quick());
    let snapshot = settled(&reopened, &id, "destroyed");
    assert_eq!(snapshot["run"]["status"], "failed");
    assert_eq!(snapshot["receipt"]["reply"], "the-reply-text");
    assert!(snapshot["receipt"]["error"].as_str().unwrap().contains("the-error-text"));
}

/// Codex's review of #39022 at 8c2c83b0 (F1, after 551a7dca's F3): when the app switched account
/// during a Run's start, the machine may be the other account's. The cleanup ends only once a
/// list of that account has shown none of it too, never on the Run's own account's list alone.
#[test]
fn a_start_that_saw_another_account_cleans_up_there_too() {
    let other = "user:u1|team:team_2".to_owned();
    let fake = Fake::new(
        Some(Outcome::Failed {
            code: "cloud.account_changed".into(),
            message: "the app is on another account".into(),
            reply: None,
            machine: None,
        }),
        vec![Removal::Gone, Removal::Gone, Removal::Cleared(other.clone())],
    );
    *fake.others.lock().unwrap() = vec![other.clone(), "user:u1|team:team_1".into()];
    let engine = Engine::open(None, fake.clone(), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["receipt"]["cleanup"], "destroyed");
    let seen = fake.elsewheres.lock().unwrap().clone();
    // The own account's Gone twice did not end it; team_2's list clearing did, then Gone again.
    assert_eq!(seen.len(), 4, "{seen:?}");
    assert_eq!(seen[0], vec![other.clone()], "the Run's own account is never its elsewhere");
    assert_eq!(seen[2], vec![other]);
    assert!(seen[3].is_empty());
}

#[test]
fn a_start_that_saw_another_account_is_never_destroyed_on_its_own_list_alone() {
    let fake = Fake::new(Some(Outcome::TimedOut { machine: None }), vec![]);
    *fake.others.lock().unwrap() = vec!["user:u2|personal".into()];
    let engine = Engine::open(None, fake.clone(), quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let began = Instant::now();
    while fake.removes.load(Ordering::Acquire) < 4 && began.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(2));
    }
    let snapshot =
        engine.perform("runs.wait", &args(json!({ "id": id, "timeoutMs": 10 }))).unwrap();
    assert_eq!(snapshot["receipt"]["cleanup"], "pending");
    assert!(fake.removes.load(Ordering::Acquire) >= 4);
}

#[test]
fn the_apps_list_answer_names_the_account_whatever_ffi_it_links() {
    // The machine-list rules of the pinned FFI answer `account: {signed_in}` alone; the app's own
    // `account` (`CloudHandlers.listAccount`) replaces it, so a signed-in person's list has a scope.
    let pinned = json!({ "loaded": true, "count": 0, "machines": [], "creating": [],
                         "account": { "signed_in": true } });
    assert_eq!(account_scope(&pinned), None, "an answer with no person is no one's");
    let mut app = pinned;
    app["account"] = json!({ "signed_in": true, "user_id": "u1", "team_id": "team_1" });
    assert_eq!(account_scope(&app).as_deref(), Some("user:u1|team:team_1"));
    app["account"]["team_id"] = Value::Null;
    assert_eq!(account_scope(&app).as_deref(), Some("user:u1|personal"));
}

/// The audit of #39022 before 16d6160c's push (P1): the give-up clock ran from the Run's end, so a
/// Mac closed (or Cloud turned off) for longer than the give-up time abandoned the cleanup at its
/// first pass after, with no delete ever tried, and the machine billed on. Time the app could not
/// be asked never counts now; time it answers still does.
#[test]
fn a_cleanup_the_app_could_not_hear_is_never_given_up() {
    let replied = || Outcome::Replied { reply: "hi".into(), machine: Some("m-1".into()) };
    let quiet = Timing { give_up: Duration::from_millis(40), ..quick() };
    let unheard = (0..15).map(|_| Removal::Unheard("cmux is not running".into())).collect();
    let fake = Fake::new(Some(replied()), unheard);
    let engine = Engine::open(None, fake.clone(), quiet);
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["receipt"]["cleanup"], "destroyed", "{snapshot}");
    assert_eq!(
        fake.removes.load(Ordering::Acquire),
        16,
        "it was asked again once the app answered"
    );

    // A machine the app keeps listing is still given up after the give-up time it answered.
    let listed = (0..1_000).map(|_| Removal::Later("still listed".into())).collect();
    let fake = Fake::new(Some(replied()), listed);
    let engine = Engine::open(None, fake.clone(), quiet);
    create(&engine, "k2");
    std::thread::sleep(Duration::from_millis(1_000));
    let asked = fake.removes.load(Ordering::Acquire);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(fake.removes.load(Ordering::Acquire), asked, "the cleanup stopped: given up");
    assert!(asked < 1_000, "given up after the time the app answered, not at the list's end");
}

/// #39022 review at 946e940e, F2: a create of the Run's machine still on its way (a start waiting
/// on the person's Start) was read again as "later" and given up after three days of it, so a Start
/// after that made a machine nothing deleted. That time never counts now: the cleanup waits for the
/// create, then deletes what it made.
#[test]
fn a_cleanup_never_gives_up_while_its_machine_can_still_be_made() {
    let replied = || Outcome::Replied { reply: "hi".into(), machine: None };
    let quiet = Timing { give_up: Duration::from_millis(150), ..quick() };
    let mut passes: Vec<Removal> =
        (0..15).map(|_| Removal::Creating("sandbox-r is still being created".into())).collect();
    passes.push(Removal::Later("machine m-1 is being deleted".into()));
    let fake = Fake::new(Some(replied()), passes);
    let engine = Engine::open(None, fake.clone(), quiet);
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["receipt"]["cleanup"], "destroyed", "{snapshot}");
    assert_eq!(fake.removes.load(Ordering::Acquire), 17, "read again until the create ended");
}

/// #39022 review at 1c13439a, F2: a task's length is counted in characters as the composer counts
/// them (grapheme clusters): 9000 decomposed accented letters are 9000 characters, not 18000.
#[test]
fn a_tasks_length_is_counted_in_characters_the_composer_counts() {
    let engine = Engine::open(None, Fake::new(None, vec![]), quick());
    let mut ok = body("k-accents", "team_1");
    ok["task"] = json!("e\u{301}".repeat(9_000));
    assert!(engine.perform("runs.create", &args(ok)).is_ok());
    let mut long = body("k-long", "team_1");
    long["task"] = json!("e\u{301}".repeat(16_001));
    let refused = engine.perform("runs.create", &args(long)).unwrap_err();
    assert!(
        matches!(&refused, Failure::Http { status: 400, code: Some(code), .. } if code == "run_task_required"),
        "{refused:?}"
    );
}

/// The same audit (P2): a store this build cannot read was written over with an empty list, and
/// every Run's pending cleanup was forgotten. It is kept aside now.
#[test]
fn a_store_that_cannot_be_read_is_kept_aside_never_written_over() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("cloud-runs.json");
    std::fs::write(&store, b"{\"version\": 999, \"runs\": [\"from a later build\"]}").unwrap();
    let _engine = Engine::open(Some(store), Fake::new(None, vec![]), quick());
    let kept: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().contains("unreadable"))
        .collect();
    assert_eq!(kept.len(), 1, "the unreadable store is kept");
    let bytes = std::fs::read(kept[0].path()).unwrap();
    assert!(String::from_utf8_lossy(&bytes).contains("from a later build"));
}
