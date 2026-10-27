//! The request fuzzer's harness on seeded choices: it covers every schema
//! method, every answer is typed, and random sequences keep the layout
//! invariants (the libFuzzer target `mux_requests` runs the same harness).

use super::*;

/// A seeded xorshift sequence of `left` choices.
struct Seeded {
    state: u64,
    left: usize,
}

impl Seeded {
    fn new(seed: u64, left: usize) -> Self {
        Self { state: seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1, left }
    }
}

impl Choices for Seeded {
    fn below(&mut self, n: usize) -> usize {
        if self.left == 0 || n == 0 {
            return 0;
        }
        self.left -= 1;
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        (self.state % n as u64) as usize
    }

    fn exhausted(&self) -> bool {
        self.left == 0
    }
}

fn schema() -> Value {
    serde_json::from_str(SDK_SCHEMA).unwrap()
}

#[test]
fn request_fuzz_catalog_has_every_schema_method_and_only_schema_host_effects() {
    let catalog = RequestCatalog::daemon().unwrap();
    let schema = schema();
    let expected = schema["commands"].as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    assert_eq!(catalog.names().map(str::to_owned).collect::<Vec<_>>(), expected);
    for (name, why) in HOST_EFFECTS {
        assert!(expected.iter().any(|method| method == name), "{name} is not a schema method");
        assert!(!why.is_empty());
        assert!(catalog.is_host_effect(name));
    }
    // A method the schema gains is fuzzed with no change here.
    let mut grown = schema;
    grown["commands"]["fuzz-new-method"] = json!({
        "request": {"kind": "object", "fields": {
            "surface": {"type": {"kind": "ref", "name": "Id"}, "presence": "required", "nullable": false}
        }, "additional_properties": false},
        "result": {"kind": "ref", "name": "EmptyResult"},
    });
    let grown = RequestCatalog::from_sdk_schema(&grown).unwrap();
    assert!(grown.names().any(|name| name == "fuzz-new-method"));
    assert!(!grown.is_host_effect("fuzz-new-method"));
}

#[test]
fn request_fuzz_lines_carry_the_schema_parameters() {
    let catalog = RequestCatalog::daemon().unwrap();
    let method = catalog.methods.iter().find(|method| method.name == "move-tab").unwrap();
    let live = LiveIds { surfaces: vec![7], panes: vec![9], ..LiveIds::default() };
    let seen = Seen::default();
    let mut members = BTreeSet::new();
    for seed in 0..64 {
        let mut choices = Seeded::new(seed, 256);
        let line = Generator { choices: &mut choices, live: &live, seen: &seen, learned: &[] }
            .line(method, 5);
        let line: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(line["cmd"], "move-tab");
        assert_eq!(line["id"], 5);
        members.extend(line.as_object().unwrap().keys().cloned());
    }
    for member in ["surface", "pane", "index", "transaction"] {
        assert!(members.contains(member), "{member} never generated: {members:?}");
    }
}

#[test]
fn request_fuzz_every_method_reaches_the_dispatcher_and_answers_typed() {
    record_request_thread_blocking();
    let catalog = RequestCatalog::daemon().unwrap();
    let mut harness = RequestHarness::open().unwrap();
    // Something for ids to name first.
    for (seed, method) in ["new-workspace", "new-tab", "split", "new-screen"].iter().enumerate() {
        harness.step_method(&catalog, method, &mut Seeded::new(seed as u64, 64)).unwrap();
    }
    let names = catalog.names().map(str::to_owned).collect::<Vec<_>>();
    for (seed, name) in names.iter().enumerate() {
        for round in 0..2 {
            let mut choices = Seeded::new((seed * 2 + round) as u64 + 100, 256);
            if let Err(finding) = harness.step_method(&catalog, name, &mut choices) {
                panic!("{finding}");
            }
        }
    }
    let summary = harness.summary().clone();
    for name in &names {
        let counted = if catalog.is_host_effect(name) {
            summary.decoded.get(name)
        } else {
            summary.dispatched.get(name)
        };
        assert!(counted.is_some_and(|count| *count > 0), "{name} was not covered");
    }
    // The dispatcher kept answering: almost every request got its answer in time.
    let late = summary.late.values().sum::<usize>();
    assert!(
        late * 10 < summary.answers,
        "{late} late of {} answers: {:?}",
        summary.answers,
        summary.late
    );
    // Generated parameters get past validation for a good share of methods.
    assert!(summary.succeeded.len() * 8 > names.len(), "{:?}", summary.succeeded);
}

#[test]
fn request_fuzz_random_sequences_keep_the_layout_invariants() {
    record_request_thread_blocking();
    let catalog = RequestCatalog::daemon().unwrap();
    let seeds =
        std::env::var("REQUEST_FUZZ_SEEDS").ok().and_then(|seeds| seeds.parse().ok()).unwrap_or(12);
    for seed in 0..seeds {
        let mut choices = Seeded::new(seed, 4_000);
        if let Err(finding) = run(&catalog, &mut choices, 40) {
            panic!("seed {seed}: {finding}");
        }
    }
}

#[test]
fn request_fuzz_refuses_untyped_and_twice_answered_replies() {
    let mut harness = RequestHarness::open().unwrap();
    harness.pending.insert(1, "ping".into());
    let untyped = harness.answer(json!({"id": 1, "ok": false}));
    assert!(matches!(untyped, Err(Finding::UntypedAnswer { .. })), "{untyped:?}");
    harness.pending.insert(2, "ping".into());
    harness.answer(json!({"id": 2, "ok": true, "data": {"group_id": "g-1"}})).unwrap();
    assert_eq!(harness.learned, vec!["g-1".to_owned()]);
    let twice = harness.answer(json!({"id": 2, "ok": true}));
    assert!(matches!(twice, Err(Finding::AnsweredTwice { .. })), "{twice:?}");
    // Events and stream items are not answers.
    harness.answer(json!({"event": "tree-updated"})).unwrap();
    harness.answer(json!({"id": 3, "stream": 1})).unwrap();
}

/// Sends `request` (its `cmd` and parameters) as the next request.
fn send(harness: &mut RequestHarness, mut request: Value) -> Result<(), Finding> {
    let id = harness.next_id;
    harness.next_id += 1;
    request["id"] = json!(id);
    let method = request["cmd"].as_str().unwrap().to_owned();
    harness.dispatch(&method, id, &request.to_string())
}

#[test]
fn request_fuzz_closes_that_end_terminals_answer_and_keep_the_layout() {
    record_request_thread_blocking();
    let mut harness = RequestHarness::open().unwrap();
    for _ in 0..2 {
        send(&mut harness, json!({"cmd": "new-workspace"})).unwrap();
    }
    send(&mut harness, json!({"cmd": "new-screen"})).unwrap();
    let ids = harness.mux.fuzz_live_ids();
    for request in [
        json!({"cmd": "close-surface", "surface": ids.surfaces[0]}),
        json!({"cmd": "close-pane", "pane": ids.panes[1], "end_terminals": true}),
        json!({"cmd": "close-screen", "screen": ids.screens[0], "end_terminals": true}),
        json!({"cmd": "close-workspace", "workspace": ids.workspaces[0], "end_terminals": true}),
        // Stale now.
        json!({"cmd": "close-pane", "pane": ids.panes[1], "end_terminals": true}),
        json!({"cmd": "list-workspaces"}),
    ] {
        send(&mut harness, request).unwrap();
    }
    assert!(harness.pending.is_empty(), "unanswered: {:?}", harness.summary.late);
    assert_eq!(harness.summary.succeeded.get("list-workspaces"), Some(&1));
}
