//! The daemon's sandboxed Runs against fake steps: a reply, a failure, a timeout, a cancel, the
//! cleanup after each, a restart that resumes it, and one Run per idempotency key.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::*;

/// Steps whose task ends as `outcome` (or, `None`, only at a cancel) and whose removals answer
/// `removals` in turn (then `Gone`). Its scope is `team:team_1`, and every remove's is kept.
struct Fake {
    outcome: Mutex<Option<Outcome>>,
    removals: Mutex<Vec<Removal>>,
    ran: Mutex<Vec<Task>>,
    removed: Mutex<Vec<(String, Option<String>)>>,
    scopes: Mutex<Vec<Option<String>>>,
    removes: AtomicUsize,
}

impl Fake {
    fn new(outcome: Option<Outcome>, removals: Vec<Removal>) -> Arc<Self> {
        Arc::new(Fake {
            outcome: Mutex::new(outcome),
            removals: Mutex::new(removals),
            ran: Mutex::new(Vec::new()),
            removed: Mutex::new(Vec::new()),
            scopes: Mutex::new(Vec::new()),
            removes: AtomicUsize::new(0),
        })
    }
}

impl Steps for Fake {
    fn scope(&self) -> Option<String> {
        Some("team:team_1".into())
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

    fn remove(&self, machine_name: &str, machine: Option<&str>, scope: Option<&str>) -> Removal {
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

fn create(engine: &Arc<Engine>, key: &str) -> Value {
    engine
        .perform(
            "runs.create",
            Some("team_1"),
            &args(json!({ "task": "say hi", "agent": "claude", "timeoutMs": 30_000, "idempotencyKey": key })),
        )
        .unwrap()
}

/// Waits (at most 5 s) until `id`'s receipt says the cleanup is `cleanup`, as `team_1`.
fn settled(engine: &Arc<Engine>, id: &str, cleanup: &str) -> Value {
    settled_as(engine, "team_1", id, cleanup)
}

fn settled_as(engine: &Arc<Engine>, owner: &str, id: &str, cleanup: &str) -> Value {
    let began = Instant::now();
    loop {
        let snapshot = engine
            .perform("runs.wait", Some(owner), &args(json!({ "id": id, "timeoutMs": 200 })))
            .unwrap();
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
    let cancelled =
        engine.perform("runs.cancel", Some("team_1"), &args(json!({ "id": id }))).unwrap();
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
        Some("team:team_1"),
        "the scope read at the start is the cleanup's after a restart"
    );
    assert!(fake.ran.lock().unwrap().is_empty(), "nothing runs again");
    first.perform("runs.cancel", Some("team_1"), &args(json!({ "id": id }))).unwrap();
}

#[test]
fn the_same_key_answers_the_same_run_and_another_body_is_a_conflict() {
    let fake = Fake::new(Some(Outcome::Replied { reply: "ok".into(), machine: None }), vec![]);
    let engine = Engine::open(None, fake.clone(), quick());
    let first = create(&engine, "same");
    let again = create(&engine, "same");
    assert_eq!(first["id"], again["id"]);
    let conflict = engine
        .perform("runs.create", Some("team_1"), &args(json!({ "task": "other", "agent": "claude", "timeoutMs": 30_000, "idempotencyKey": "same" })))
        .unwrap_err();
    assert_eq!(
        conflict,
        Failure::http(
            409,
            Some("run_idempotency_conflict".into()),
            Some("this idempotency key named another Run".into())
        )
    );
    // Another team's same key is another Run.
    let other = engine
        .perform("runs.create", Some("team_2"), &args(json!({ "task": "say hi", "agent": "claude", "timeoutMs": 30_000, "idempotencyKey": "same" })))
        .unwrap();
    assert_ne!(other["id"], first["id"]);
    settled(&engine, first["id"].as_str().unwrap(), "destroyed");
    settled_as(&engine, "team_2", other["id"].as_str().unwrap(), "destroyed");
    assert_eq!(fake.ran.lock().unwrap().len(), 2);
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
    ];
    for (body, code) in cases {
        let failure = engine.perform("runs.create", None, &args(body)).unwrap_err();
        assert!(
            matches!(&failure, Failure::Http { status: 400, code: Some(c), .. } if c == code),
            "{failure:?}"
        );
    }
    let missing =
        engine.perform("runs.wait", None, &args(json!({ "id": "run_nope" }))).unwrap_err();
    assert!(matches!(missing, Failure::Http { status: 404, .. }));
    assert!(fake.ran.lock().unwrap().is_empty());
}

#[test]
fn a_wait_holds_at_most_its_bound_and_answers_no_receipt_while_running() {
    let fake = Fake::new(None, vec![]);
    let engine = Engine::open(None, fake, quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let began = Instant::now();
    let snapshot = engine
        .perform("runs.wait", Some("team_1"), &args(json!({ "id": id, "timeoutMs": 50 })))
        .unwrap();
    assert!(began.elapsed() < Duration::from_secs(2));
    assert_eq!(snapshot["receipt"], Value::Null);
    assert!(matches!(snapshot["run"]["status"].as_str(), Some("queued" | "running")));
    engine.perform("runs.cancel", Some("team_1"), &args(json!({ "id": id }))).unwrap();
}

#[test]
fn run_sandbox_answers_the_final_snapshot() {
    let fake = Fake::new(Some(Outcome::Replied { reply: "done".into(), machine: None }), vec![]);
    let engine = Engine::open(None, fake, quick());
    let snapshot = engine
        .perform(
            "runs.sandbox",
            None,
            &args(json!({ "task": "hi", "timeoutMs": 30_000, "idempotencyKey": "k" })),
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
fn another_owners_wait_or_cancel_finds_no_run() {
    let fake = Fake::new(None, vec![]);
    let engine = Engine::open(None, fake, quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let not_found =
        || Failure::http(404, Some("run_not_found".into()), Some("no such Run on this Mac".into()));
    for owner in [Some("team_2"), None] {
        let wait = engine.perform("runs.wait", owner, &args(json!({ "id": id, "timeoutMs": 10 })));
        assert_eq!(wait.unwrap_err(), not_found(), "{owner:?}");
        let cancel = engine.perform("runs.cancel", owner, &args(json!({ "id": id })));
        assert_eq!(cancel.unwrap_err(), not_found(), "{owner:?}");
    }
    let snapshot = engine
        .perform("runs.wait", Some("team_1"), &args(json!({ "id": id, "timeoutMs": 10 })))
        .unwrap();
    assert!(snapshot["run"]["cancelRequestedAt"].is_null(), "the other owner's cancel did nothing");
    engine.perform("runs.cancel", Some("team_1"), &args(json!({ "id": id }))).unwrap();
}

#[test]
fn the_store_never_holds_a_runs_reply_or_error() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("cloud-runs.json");
    let fake = Fake::new(
        Some(Outcome::Failed {
            code: "chat.turn_failed".into(),
            message: "private-error-text".into(),
            reply: Some("private-reply-text".into()),
            machine: Some("m-1".into()),
        }),
        vec![],
    );
    let engine = Engine::open(Some(store.clone()), fake, quick());
    let id = create(&engine, "k").get("id").and_then(Value::as_str).unwrap().to_owned();
    let snapshot = settled(&engine, &id, "destroyed");
    assert_eq!(snapshot["receipt"]["reply"], "private-reply-text", "the live Run still answers it");
    let saved = std::fs::read_to_string(&store).unwrap();
    assert!(saved.contains(&id), "{saved}");
    assert!(
        !saved.contains("private-reply-text") && !saved.contains("private-error-text"),
        "{saved}"
    );
}
