use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use crate::stall::{Decision, Signal, StallPolicy, Watch};
use crate::{
    Completion, Entry, Event, Host, Journal, Limits, Output, RunInput, RunState, Step, StepKind,
    Wait, run,
};

/// A host whose steps finish when the run waits: first started first
/// (`lifo` false) or last started first.
#[derive(Default)]
struct Fake {
    replies: HashMap<String, Result<Output, String>>,
    started: Vec<Step>,
    running: VecDeque<Step>,
    lifo: bool,
    /// Answer `Stopped` once this many steps finished.
    stop_after: Option<usize>,
    finished: usize,
    most_running: usize,
    refuse_starts: bool,
    events: Vec<Event>,
}

impl Fake {
    fn reply(mut self, input: &str, result: Result<Output, String>) -> Self {
        self.replies.insert(input.to_owned(), result);
        self
    }

    fn inputs(&self) -> Vec<String> {
        self.started.iter().map(|step| step.input.clone()).collect()
    }
}

fn text(text: &str) -> Result<Output, String> {
    Ok(Output::Agent { text: text.to_owned(), session: Some("session-1".into()) })
}

impl Host for Fake {
    fn start(&mut self, step: &Step) -> Result<Option<String>, String> {
        assert!(!self.refuse_starts, "a replay started {:?}", step.input);
        self.started.push(step.clone());
        self.running.push_back(step.clone());
        self.most_running = self.most_running.max(self.running.len());
        Ok(Some(format!("handle-{}", step.id)))
    }

    fn wait(&mut self) -> Wait {
        if self.stop_after.is_some_and(|after| self.finished >= after) {
            return Wait::Stopped;
        }
        let step = if self.lifo { self.running.pop_back() } else { self.running.pop_front() };
        let step = step.expect("the run waited with nothing running");
        self.finished += 1;
        let lookup = match &step.follow_up {
            Some(_) => format!("follow-up:{}", step.input),
            None => step.input.clone(),
        };
        let result = self.replies.get(&lookup).cloned().unwrap_or_else(|| match step.kind {
            StepKind::Agent => text(&format!("did {}", step.input)),
            StepKind::Machine => Ok(Output::Machine { exit: 0, log: "ok".into() }),
        });
        Wait::Done(Completion { id: step.id, result })
    }

    fn call(&mut self, name: &str, arguments: Map<String, Value>) -> Value {
        json!({"ok": true, "value": {"tool": name, "arguments": arguments}})
    }

    fn event(&mut self, event: Event) {
        self.events.push(event);
    }
}

fn input(script: &str) -> RunInput {
    RunInput { script: script.to_owned(), args: None, limits: Limits::default() }
}

fn finished(state: &RunState) -> &Value {
    match state {
        RunState::Finished(value) => value,
        other => panic!("the run did not finish: {other:?}"),
    }
}

#[test]
fn parallel_and_pipeline_return_each_result() {
    let mut host = Fake::default();
    let outcome = run(
        input(
            r"export const meta = { name: 't', description: 'd', phases: [{ title: 'A' }] }
            phase('A')
            const xs = await parallel(['a', 'b'].map(x => () => agent('say ' + x)))
            const ys = await pipeline(['p'], x => agent('one ' + x), (r, item, i) => agent(`two ${item} ${i} ${r}`))
            return { xs, ys }",
        ),
        &mut Journal::memory(),
        &mut host,
    );
    assert_eq!(
        finished(&outcome.state),
        &json!({"xs": ["did say a", "did say b"], "ys": ["did two p 0 did one p"]})
    );
    assert_eq!(
        outcome.meta,
        Some(json!({"name": "t", "description": "d", "phases": [{"title": "A"}]}))
    );
    assert_eq!(host.started[0].phase.as_deref(), Some("A"));
    assert_eq!(outcome.live, 4);
}

#[test]
fn a_failed_agent_is_null_and_a_failed_machine_rejects() {
    let mut host = Fake::default()
        .reply("b", Err("usage limit".into()))
        .reply("false", Ok(Output::Machine { exit: 1, log: "boom".into() }));
    let outcome = run(
        input(
            r"const xs = await parallel([() => agent('a'), () => agent('b'), () => { throw new Error('x') }])
            const ys = await pipeline([1, 2], n => n === 2 ? Promise.reject(new Error('no')) : n, n => n * 10)
            let m
            try { await machine('false', { on: 'ci' }) } catch (e) { m = `${e.exit}:${e.log}` }
            return { xs, ys, m }",
        ),
        &mut Journal::memory(),
        &mut host,
    );
    assert_eq!(
        finished(&outcome.state),
        &json!({"xs": ["did a", null, null], "ys": [10, null], "m": "1:boom"})
    );
    assert!(outcome.logs.iter().any(|line| line.contains("usage limit")));
}

#[test]
fn a_schema_reply_is_validated_and_asked_again_once() {
    let schema = r"{ type: 'object', properties: { n: { type: 'integer' } }, required: ['n'] }";
    let mut host = Fake::default()
        .reply("count", text("I think it is three"))
        .reply("follow-up:count", text("Here:\n```json\n{\"n\": 3}\n```"))
        .reply("twice", text("{\"n\": \"three\"}"))
        .reply("follow-up:twice", text("still not"));
    let outcome = run(
        input(&format!(
            r"const one = await agent('count', {{ schema: {schema} }})
            const two = await agent('twice', {{ schema: {schema} }})
            let bad
            try {{ await agent('x', {{ schema: {{ type: 'string' }} }}) }} catch (e) {{ bad = e.message }}
            return {{ one, two, bad }}"
        )),
        &mut Journal::memory(),
        &mut host,
    );
    let value = finished(&outcome.state);
    assert_eq!(value["one"], json!({"n": 3}));
    assert_eq!(value["two"], Value::Null);
    assert!(value["bad"].as_str().unwrap().contains("type"), "{value}");
    let follow_up = host.started.iter().find(|step| step.follow_up.is_some()).unwrap();
    assert_eq!(follow_up.resume.as_deref(), Some("session-1"));
    assert!(follow_up.follow_up.as_deref().unwrap().contains("schema"));
}

const ORDERED: &str = r"const order = []
    await parallel(['a', 'b', 'c'].map(x => () => agent(x).then(v => { order.push(x); return v })))
    const next = await agent('after ' + order.join(''))
    return order.join('') + '|' + next";

#[test]
fn a_rerun_replays_the_journal_in_its_finishing_order() {
    let mut journal = Journal::memory();
    let mut host = Fake { lifo: true, ..Fake::default() };
    let first = run(input(ORDERED), &mut journal, &mut host);
    assert_eq!(finished(&first.state), &json!("cba|did after cba"));
    let mut replay = Fake { refuse_starts: true, ..Fake::default() };
    let second = run(input(ORDERED), &mut journal, &mut replay);
    assert_eq!(second.state, first.state);
    assert_eq!((second.cached, second.live), (4, 0));
    assert!(replay.events.iter().any(|event| matches!(event, Event::Cached(_))));
}

#[test]
fn an_edited_script_runs_from_its_first_changed_step() {
    let mut journal = Journal::memory();
    let script = |two: &str| {
        format!("return [await agent('one'), await agent('{two}'), await agent('three')].join(',')")
    };
    run(input(&script("two")), &mut journal, &mut Fake::default());
    let mut host = Fake::default();
    let outcome = run(input(&script("TWO")), &mut journal, &mut host);
    assert_eq!(finished(&outcome.state), &json!("did one,did TWO,did three"));
    assert_eq!(host.inputs(), ["TWO", "three"]);
}

#[test]
fn a_paused_run_resumes_and_reattaches_its_running_step() {
    let mut journal = Journal::memory();
    let script = "const a = await agent('a'); const b = await agent('b', { label: 'B' }); return a + '+' + b";
    let mut host = Fake { stop_after: Some(1), ..Fake::default() };
    let paused = run(input(script), &mut journal, &mut host);
    assert_eq!(paused.state, RunState::Paused);
    assert!(journal.entries().iter().any(|entry| matches!(entry, Entry::Started { n: 1, .. })));
    let mut host = Fake::default();
    let resumed = run(input(script), &mut journal, &mut host);
    assert_eq!(finished(&resumed.state), &json!("did a+did b"));
    assert_eq!(host.inputs(), ["b"]);
    assert_eq!(host.started[0].resume.as_deref(), Some("handle-1"));
    assert_eq!(host.started[0].label.as_deref(), Some("B"));
}

#[test]
fn the_clock_and_randomness_are_unavailable() {
    let outcome = run(
        input(
            r"const blocked = []
            for (const [name, f] of [['now', () => Date.now()], ['new', () => new Date()], ['random', () => Math.random()]]) {
              try { f() } catch (e) { blocked.push(name) }
            }
            return { blocked, fixed: new Date(0).getTime() }",
        ),
        &mut Journal::memory(),
        &mut Fake::default(),
    );
    assert_eq!(finished(&outcome.state), &json!({"blocked": ["now", "new", "random"], "fixed": 0}));
}

#[test]
fn steps_beyond_the_concurrency_limit_wait_their_turn() {
    let mut host = Fake::default();
    let mut run_input =
        input("return (await parallel([1,2,3,4,5].map(n => () => agent('n' + n)))).length");
    run_input.limits.concurrency = 2;
    let outcome = run(run_input, &mut Journal::memory(), &mut host);
    assert_eq!(finished(&outcome.state), &json!(5));
    assert_eq!(host.most_running, 2);
}

#[test]
fn the_agent_limit_and_cmux_calls() {
    let mut run_input = input(
        r"await agent('a'); await agent('b')
        let refused
        try { await agent('c') } catch (e) { refused = e.message }
        const listed = await cmux.pane_list({ all: true })
        return { refused, listed, args }",
    );
    run_input.limits.max_agents = 2;
    run_input.args = Some(json!({"n": 1}));
    let outcome = run(run_input, &mut Journal::memory(), &mut Fake::default());
    let value = finished(&outcome.state);
    assert!(value["refused"].as_str().unwrap().contains("at most 2"));
    assert_eq!(value["listed"], json!({"tool": "pane_list", "arguments": {"all": true}}));
    assert_eq!(value["args"], json!({"n": 1}));
}

#[test]
fn a_runaway_or_stuck_script_fails() {
    let mut runaway = input("while (true) {}");
    runaway.limits.compute = Duration::from_millis(200);
    let outcome = run(runaway, &mut Journal::memory(), &mut Fake::default());
    assert!(
        matches!(&outcome.state, RunState::Failed(e) if e["code"] == "script.timeout"),
        "{outcome:?}"
    );
    let stuck =
        run(input("await new Promise(() => {})"), &mut Journal::memory(), &mut Fake::default());
    assert!(
        matches!(&stuck.state, RunState::Failed(e) if e["code"] == "script.unfinished"),
        "{stuck:?}"
    );
    let threw = run(input("throw new Error('nope')"), &mut Journal::memory(), &mut Fake::default());
    assert!(matches!(&threw.state, RunState::Failed(e) if e["message"] == "nope"), "{threw:?}");
}

#[test]
fn a_file_journal_survives_reopening_and_a_torn_line() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("journal.jsonl");
    let mut journal = Journal::open(&path).unwrap();
    run(input(ORDERED), &mut journal, &mut Fake::default());
    let count = journal.entries().len();
    drop(journal);
    let mut bytes = std::fs::read(&path).unwrap();
    bytes.extend_from_slice(b"{\"t\":\"done\",\"n\":9");
    std::fs::write(&path, bytes).unwrap();
    let mut reopened = Journal::open(&path).unwrap();
    assert_eq!(reopened.entries().len(), count);
    let replay =
        run(input(ORDERED), &mut reopened, &mut Fake { refuse_starts: true, ..Fake::default() });
    assert_eq!(finished(&replay.state), &json!("abc|did after abc"));
}

#[test]
fn step_keys_ignore_display_options_and_key_order() {
    let key = |options: Value| crate::driver::step_key(StepKind::Agent, "p", &options);
    assert_eq!(
        key(json!({"a": 1, "b": 2})),
        key(json!({"b": 2, "a": 1, "label": "x", "phase": "y"}))
    );
    assert_ne!(key(json!({"a": 1})), key(json!({"a": 2})));
}

#[test]
fn meta_rewrite_keeps_the_rest_of_the_script() {
    let script = "export const meta = { name: 'x' }\nreturn meta.name";
    assert_eq!(
        crate::engine::rewrite_meta(script),
        "const meta = globalThis.__cmuxMeta = { name: 'x' }\nreturn meta.name"
    );
    assert_eq!(crate::engine::rewrite_meta("return 1"), "return 1");
}

#[test]
fn stall_ladder_nudges_then_restarts_then_fails() {
    let at = Instant::now();
    let minutes = |n| at + Duration::from_secs(60 * n);
    let mut watch = Watch::new(StallPolicy::default(), at);
    assert_eq!(watch.tick(minutes(5)), Decision::Wait);
    assert_eq!(watch.observe(Signal::Activity, minutes(5)), Decision::Wait);
    assert_eq!(watch.tick(minutes(14)), Decision::Wait);
    assert!(matches!(watch.tick(minutes(15)), Decision::Nudge { .. }));
    assert!(matches!(watch.tick(minutes(25)), Decision::Restart { .. }));
    watch.restarted(minutes(25));
    assert!(matches!(watch.tick(minutes(35)), Decision::Nudge { .. }));
    assert!(matches!(watch.tick(minutes(45)), Decision::Fail { .. }));
}

#[test]
fn a_limit_skips_the_nudge_and_a_permission_counts_as_quiet() {
    let at = Instant::now();
    let mut watch = Watch::new(StallPolicy::default(), at);
    assert!(matches!(watch.observe(Signal::LimitHit("5h".into()), at), Decision::Restart { .. }));
    assert!(matches!(watch.observe(Signal::RouteError("502".into()), at), Decision::Fail { .. }));
    let mut waiting = Watch::new(StallPolicy::default(), at);
    waiting.observe(Signal::PermissionWaiting, at);
    match waiting.tick(at + Duration::from_secs(600)) {
        Decision::Nudge { reason } => assert!(reason.contains("permission")),
        other => panic!("{other:?}"),
    }
}
