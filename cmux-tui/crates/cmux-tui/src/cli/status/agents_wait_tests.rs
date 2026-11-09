//! `cmux terminal wait --any|--all`: its words, what it reads from a
//! snapshot, and when the wait holds, waits on, or can never hold.

use std::cell::Cell;
use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::super::resolve::Failure;
use super::{
    Mode, Outcome, Request, Session, Until, Wake, evaluate, observe, parse, result, watch,
};

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn terminal(index: u8) -> String {
    format!("term_0000000000000000000000000000000{index}")
}

/// A snapshot whose terminals 1..=n run agents in `states` (`None`: no
/// agent reported yet; `"exited"`: the terminal itself exited).
fn snapshot(states: &[Option<&str>], unseen: &[u8]) -> Value {
    let mut terminals = Vec::new();
    let mut agents = Vec::new();
    for (index, state) in states.iter().enumerate() {
        let id = terminal(index as u8 + 1);
        let exited = *state == Some("exited");
        terminals.push(json!({
            "id": id,
            "tab_id": format!("tab_{index}"),
            "lifecycle": if exited { "exited" } else { "running" },
        }));
        if let Some(state) = state.filter(|state| *state != "exited") {
            agents.push(json!({
                "terminal_id": id,
                "state": state,
                "source": "hook",
                "updated_at_ms": (1_000 + index as u64 * 100).to_string(),
                "extra": {"agent": "claude"},
            }));
        }
    }
    let notifications: Vec<Value> = unseen
        .iter()
        .map(|index| json!({"terminal_id": terminal(*index), "unread": true, "id": format!("n{index}")}))
        .collect();
    json!({
        "terminals": terminals,
        "tabs": [],
        "agents": agents,
        "notifications": notifications,
    })
}

fn request(mode: Mode, until: &[Until], count: u8) -> Request {
    Request {
        mode,
        targets: (1..=count).map(terminal).collect(),
        until: until.to_vec(),
        timeout: None,
    }
}

fn ids(count: u8) -> Vec<String> {
    (1..=count).map(terminal).collect()
}

#[test]
fn w5t_wait_any_and_all_parse_lists_states_and_timeouts() {
    let parsed = parse(&words("--any alpha,beta --until idle,blocked --timeout 5m")).unwrap();
    assert_eq!(parsed.mode, Mode::Any);
    assert_eq!(parsed.targets, ["alpha", "beta"]);
    assert_eq!(parsed.until, [Until::Idle, Until::Blocked]);
    assert_eq!(parsed.timeout, Some(Duration::from_secs(300)));
    let parsed = parse(&words("--all=alpha --all beta --until done --until ended")).unwrap();
    assert_eq!(parsed.mode, Mode::All);
    assert_eq!(parsed.targets, ["alpha", "beta"]);
    assert_eq!(parsed.until, [Until::Done, Until::Ended]);
    let parsed = parse(&words("--any alpha --timeout-ms 250")).unwrap();
    assert_eq!(parsed.until, [Until::Idle, Until::Blocked, Until::Done], "the default");
    assert_eq!(parsed.timeout, Some(Duration::from_millis(250)));
    assert!(parse(&words("--any alpha --all beta")).is_err(), "both modes");
    assert!(parse(&words("--any")).is_err(), "no targets");
    assert!(parse(&words("--until idle")).is_err(), "no mode");
    assert!(parse(&words("--any alpha --until ready")).is_err(), "ready is one terminal's wait");
    assert!(parse(&words("--any alpha --pattern x")).is_err());
    let many = (0..65).map(|index| format!("t{index}")).collect::<Vec<_>>().join(",");
    assert!(parse(&words(&format!("--any {many}"))).is_err(), "at most 64");
}

#[test]
fn w5t_wait_reads_the_shared_status_with_done_until_seen() {
    let snapshot = snapshot(&[Some("working"), Some("idle"), None, Some("exited")], &[2]);
    let seen = observe(&snapshot, &[ids(4), vec![terminal(9)]].concat());
    let statuses: Vec<&str> = seen.iter().map(|agent| agent.status).collect();
    assert_eq!(statuses, ["working", "done", "none", "ended", "gone"]);
}

#[test]
fn w5t_wait_any_holds_on_the_first_listed_match_and_idle_takes_done() {
    let wait = request(Mode::Any, &[Until::Idle], 3);
    let seen =
        observe(&snapshot(&[Some("working"), Some("working"), Some("working")], &[]), &ids(3));
    assert_eq!(evaluate(&wait, &seen), Outcome::Pending);
    let seen = observe(&snapshot(&[Some("working"), Some("idle"), Some("idle")], &[3]), &ids(3));
    assert_eq!(evaluate(&wait, &seen), Outcome::Holds { terminal: 1 });
    let value = result(&wait, &seen, 1, Duration::from_millis(1_500));
    assert_eq!(value["terminal"], terminal(2));
    assert_eq!(value["status"], "idle");
    assert_eq!(value["matched"], json!([terminal(2), terminal(3)]));
    assert_eq!(value["agents"][2]["status"], "done");
    assert_eq!(value["waited_ms"], "1500");
    assert_eq!(value["mode"], "any");
    assert_eq!(value["until"], json!(["idle"]));
}

#[test]
fn w5t_wait_all_holds_only_when_every_agent_matches_and_names_the_latest() {
    let wait = request(Mode::All, &[Until::Idle, Until::Blocked], 3);
    let seen = observe(&snapshot(&[Some("idle"), Some("working"), Some("blocked")], &[]), &ids(3));
    assert_eq!(evaluate(&wait, &seen), Outcome::Pending);
    let seen = observe(&snapshot(&[Some("idle"), Some("idle"), Some("blocked")], &[]), &ids(3));
    // Terminal 3 changed last (updated_at_ms 1200).
    assert_eq!(evaluate(&wait, &seen), Outcome::Holds { terminal: 2 });
}

#[test]
fn w5t_wait_fails_when_ended_agents_make_it_impossible() {
    let any = request(Mode::Any, &[Until::Blocked], 2);
    let seen = observe(&snapshot(&[Some("done"), Some("working")], &[]), &ids(2));
    assert_eq!(seen[0].status, "ended", "an agent record's done is an ended session");
    assert_eq!(evaluate(&any, &seen), Outcome::Pending, "one agent still runs");
    let seen = observe(&snapshot(&[Some("done"), Some("exited")], &[]), &ids(2));
    assert_eq!(evaluate(&any, &seen), Outcome::Impossible { ended: vec![0, 1] });
    let all = request(Mode::All, &[Until::Idle], 2);
    let seen = observe(&snapshot(&[Some("idle"), Some("exited")], &[]), &ids(2));
    assert_eq!(evaluate(&all, &seen), Outcome::Impossible { ended: vec![1] });
    let until_ended = request(Mode::All, &[Until::Idle, Until::Ended], 2);
    assert_eq!(evaluate(&until_ended, &seen), Outcome::Holds { terminal: 0 });
}

/// A session that answers from a script and moves a fake clock: a wake
/// may let time pass, and a snapshot may fail.
struct Scripted<'a> {
    snapshots: VecDeque<Result<Value, Failure>>,
    wakes: VecDeque<(Duration, Wake)>,
    elapsed: &'a Cell<Duration>,
}

impl Session for Scripted<'_> {
    fn snapshot(&mut self, _deadline: Option<Instant>) -> Result<Value, Failure> {
        let Some(snapshot) = self.snapshots.pop_front() else {
            panic!("no scripted snapshot left")
        };
        snapshot
    }

    fn wake(&mut self, _within: Option<Duration>) -> Wake {
        let (passes, wake) = self.wakes.pop_front().expect("a scripted wake");
        self.elapsed.set(self.elapsed.get() + passes);
        wake
    }
}

#[test]
fn w5t_a_timeout_names_where_each_agent_stood_when_the_last_read_fails() {
    // The deadline passes during the event read, and the read after it gets
    // no answer in time (a busy session): the timeout still lists the
    // agents as the wait last saw them.
    let start = Instant::now();
    let elapsed = Cell::new(Duration::ZERO);
    let now = || start + elapsed.get();
    let mut session = Scripted {
        snapshots: VecDeque::from([
            Ok(snapshot(&[Some("working"), Some("working")], &[])),
            Err(Failure::Transport("the session did not answer in time".into())),
        ]),
        wakes: VecDeque::from([(Duration::from_secs(2), Wake::ReadFailed("timed out".into()))]),
        elapsed: &elapsed,
    };
    let mut request = request(Mode::Any, &[Until::Blocked], 2);
    request.timeout = Some(Duration::from_secs(1));
    let deadline = start.checked_add(Duration::from_secs(1));
    let Err(Failure::Local { error, exit }) = watch(&mut session, &request, deadline, &now) else {
        panic!("the wait must end with a local wait.timeout error");
    };
    assert_eq!(exit, 124);
    assert_eq!(error["code"], "wait.timeout");
    let agents = error["details"]["agents"].as_array().expect("agents");
    assert_eq!(agents.len(), 2, "{error}");
    assert_eq!(agents[0]["terminal"], terminal(1));
    assert_eq!(agents[0]["status"], "working");
}

#[test]
fn w5t_a_wait_wakes_on_an_event_and_reads_again() {
    let start = Instant::now();
    let elapsed = Cell::new(Duration::ZERO);
    let now = || start + elapsed.get();
    let mut session = Scripted {
        snapshots: VecDeque::from([
            Ok(snapshot(&[Some("working"), Some("working")], &[])),
            Ok(snapshot(&[Some("working"), Some("blocked")], &[])),
        ]),
        wakes: VecDeque::from([(Duration::from_millis(300), Wake::Event)]),
        elapsed: &elapsed,
    };
    let request = request(Mode::Any, &[Until::Blocked], 2);
    let Ok((seen, named)) = watch(&mut session, &request, None, &now) else {
        panic!("the wait must hold on the second read");
    };
    assert_eq!(seen[named].terminal, terminal(2));
    assert_eq!(seen[named].status, "blocked");
}

/// One claude (or `harness`) agent on terminal 1, idle by `source`, and the
/// harness session id its hooks left on the terminal, if any.
fn one_agent(harness: &str, source: &str, session_id: Option<&str>) -> Value {
    let mut record = json!({"id": terminal(1), "tab_id": "tab_0", "lifecycle": "running"});
    if let Some(session_id) = session_id {
        record["extra"] = json!({"agent_session_id": session_id, "agent": harness});
    }
    json!({
        "terminals": [record],
        "tabs": [],
        "agents": [{"terminal_id": terminal(1), "state": "idle", "source": source,
                    "updated_at_ms": "1000", "extra": {"agent": harness}}],
        "notifications": [],
    })
}

/// Real-build check: the screen said a just-started Claude Code was idle
/// about 9 s before its SessionStart hook, and a prompt sent then was lost.
/// For a harness whose hooks report a session start, a screen idle counts
/// only once a hook of that agent came (its session id is on the terminal).
#[test]
fn w5t_a_screen_idle_counts_only_after_the_agent_reported_its_session() {
    let idle = request(Mode::Any, &[Until::Idle], 1);
    let seen = observe(&one_agent("claude", "plugin", None), &[terminal(1)]);
    assert_eq!(seen[0].status, "starting");
    assert_eq!(evaluate(&idle, &seen), Outcome::Pending);

    let seen = observe(&one_agent("claude", "plugin", Some("s-1")), &[terminal(1)]);
    assert_eq!(seen[0].status, "idle");
    assert_eq!(evaluate(&idle, &seen), Outcome::Holds { terminal: 0 });

    let seen = observe(&one_agent("claude", "hook", None), &[terminal(1)]);
    assert_eq!(seen[0].status, "idle");

    // amp has no cmux hooks: the screen is all there is.
    let seen = observe(&one_agent("amp", "plugin", None), &[terminal(1)]);
    assert_eq!(seen[0].status, "idle");
}
