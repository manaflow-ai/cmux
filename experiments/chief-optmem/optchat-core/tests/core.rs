use std::cell::RefCell;
use std::collections::HashMap;

use optchat_core::*;

/// A host in memory: messages and node texts.
#[derive(Default)]
struct Mem {
    messages: RefCell<Vec<(Kind, String)>>,
    nodes: RefCell<HashMap<NodeId, String>>,
}

impl Mem {
    /// The host stores (and fsyncs) a message before it tells the core.
    fn push(&self, kind: Kind, text: impl Into<String>) {
        self.messages.borrow_mut().push((kind, text.into()));
    }
}

impl Store for Mem {
    fn message(&self, i: u64) -> (Kind, String) {
        self.messages.borrow()[i as usize].clone()
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.nodes.borrow().get(&id).cloned()
    }
}

/// A deterministic stand-in for the compactor model: summaries of realistic size.
fn fake_summary(node: NodeId) -> String {
    let base = format!("sum {}: ", node.name());
    let len = if node.l == 0 {
        240
    } else {
        300 + (node.l as usize * 20).min(180)
    };
    let mut s = base;
    while s.len() < len {
        s.push_str("item; ");
    }
    s.truncate(len);
    s
}

/// A small xorshift, so the test needs no dependency.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn message(rng: &mut Rng) -> (Kind, String) {
    let kind = [Kind::User, Kind::Talk, Kind::Tool, Kind::Echo][rng.below(4) as usize];
    let len = match rng.below(10) {
        0..=4 => 20 + rng.below(300),   // short: a free level-0 node
        5..=8 => 600 + rng.below(3000), // needs a summary
        _ => 10_000 + rng.below(20_000),
    } as usize;
    (kind, "x".repeat(len))
}

/// Runs every job the pump hands out until nothing is left, checking the
/// compactor never sees a placeholder line (rule 3).
fn drain(memory: &mut Memory, store: &Mem) {
    loop {
        let work = memory.pump(store);
        if work.is_empty() {
            return;
        }
        for w in work {
            match w {
                Work::Free { node, text } => {
                    store.nodes.borrow_mut().insert(node, text);
                }
                Work::Model { node } => {
                    let request = compact_request(
                        memory,
                        store,
                        node,
                        CompactPrompt::default().text("Chief"),
                    );
                    assert!(
                        !request.context.contains(PLACEHOLDER),
                        "compactor saw an unbuilt line for {}",
                        node.name()
                    );
                    let text = fake_summary(node);
                    store.nodes.borrow_mut().insert(node, text.clone());
                    memory.complete(node, &text);
                }
            }
        }
    }
}

fn assert_tiles(memory: &Memory) {
    let mut next = 0;
    for part in memory.view() {
        assert_eq!(part.start(), next, "view parts must tile [0, T)");
        assert_eq!(part.start() % part.n(), 0, "parts are aligned");
        next = part.end();
    }
    assert_eq!(next, memory.len());
}

/// Every part of `before` is still in `after` or inside a part of it: the view never splits.
fn assert_never_split(before: &[NodeId], after: &[NodeId]) {
    for old in before {
        let covering = after
            .iter()
            .find(|p| p.start() <= old.start() && old.end() <= p.end())
            .expect("covered");
        assert!(
            covering.l >= old.l,
            "{} was split into {}",
            old.name(),
            covering.name()
        );
    }
}

#[test]
fn long_chat_keeps_every_view_rule_and_a_stable_prefix() {
    let budget = 40_000;
    let mut rng = Rng(0x9e3779b97f4a7c15);
    let store = Mem::default();
    let mut memory = Memory::new(budget);
    let mut previous: Option<String> = None;
    let mut shared_total = 0usize;
    let mut size_total = 0usize;
    for step in 0..6_000u64 {
        let before = memory.view().to_vec();
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        assert_eq!(memory.append(), step);
        drain(&mut memory, &store);
        assert!(memory.settled(), "the fake compactor keeps up");
        assert_tiles(&memory);
        assert_never_split(&before, memory.view());
        assert!(
            memory.view_size() <= budget,
            "over budget at {step}: {}",
            memory.view_size()
        );
        let rendered = render_view(&memory, &store).text;
        if let Some(prev) = &previous {
            if step > 3_000 {
                shared_total += prev
                    .bytes()
                    .zip(rendered.bytes())
                    .take_while(|(a, b)| a == b)
                    .count();
                size_total += rendered.len();
            }
        }
        previous = Some(rendered);
    }
    let shared = shared_total as f64 / size_total as f64;
    assert!(
        shared > 0.5,
        "consecutive views should share most of their prefix, shared {shared:.2}"
    );
}

#[test]
fn free_nodes_keep_short_messages_verbatim() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    store.push(Kind::User, "keep CSV and add JSON");
    memory.append();
    let work = memory.pump(&store);
    assert_eq!(
        work,
        vec![Work::Free {
            node: NodeId::new(0, 0),
            text: "user: keep CSV and add JSON".into()
        }]
    );
    for w in work {
        if let Work::Free { node, text } = w {
            store.nodes.borrow_mut().insert(node, text);
        }
    }
    store.push(Kind::Talk, "done");
    memory.append();
    let work = memory.pump(&store);
    // message 1 is free, then the pair (0,1) merges free into node (1,0).
    assert_eq!(
        work,
        vec![
            Work::Free {
                node: NodeId::new(0, 1),
                text: "talk: done".into()
            },
            Work::Free {
                node: NodeId::new(1, 0),
                text: "user: keep CSV and add JSON\ntalk: done".into()
            },
        ]
    );
}

#[test]
fn level_zero_nodes_start_in_order_and_jobs_are_capped() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for _ in 0..20 {
        store.push(Kind::Echo, "y".repeat(5_000));
        memory.append();
    }
    let work = memory.pump(&store);
    // Only message 0 can start: every later level-0 node waits for the lines before it.
    assert_eq!(
        work,
        vec![Work::Model {
            node: NodeId::new(0, 0)
        }]
    );
    let text = fake_summary(NodeId::new(0, 0));
    store
        .nodes
        .borrow_mut()
        .insert(NodeId::new(0, 0), text.clone());
    memory.complete(NodeId::new(0, 0), &text);
    assert_eq!(
        memory.pump(&store),
        vec![Work::Model {
            node: NodeId::new(0, 1)
        }]
    );
    assert!(memory.busy().count() <= JOBS);
}

#[test]
fn zoom_opens_lines_and_messages() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for text in ["a\nb", "c", "d", "e"] {
        store.push(Kind::User, text);
        memory.append();
    }
    drain(&mut memory, &store);
    assert_eq!(zoom(&memory, &store, 0, 1).unwrap(), "0+0|user: a\nb");
    assert_eq!(
        zoom(&memory, &store, 0, 2).unwrap(),
        "0+1|user: a b\n1+1|user: c"
    );
    assert_eq!(
        zoom(&memory, &store, 0, 4).unwrap(),
        "0+2|user: a b user: c\n2+2|user: d user: e"
    );
    assert_eq!(
        zoom(&memory, &store, 1, 2).unwrap_err().to_string(),
        "No line 1+2."
    );
    assert_eq!(
        zoom(&memory, &store, 0, 8).unwrap_err().to_string(),
        "No line 0+8."
    );
    assert_eq!(
        zoom(&memory, &store, 0, 3).unwrap_err().to_string(),
        "No line 0+3."
    );
}

#[test]
fn reloading_folds_the_same_view() {
    let mut rng = Rng(42);
    let store = Mem::default();
    let mut memory = Memory::new(20_000);
    for _ in 0..2_000 {
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        memory.append();
        drain(&mut memory, &store);
    }
    let sizes = store
        .nodes
        .borrow()
        .iter()
        .map(|(k, v)| (*k, v.len()))
        .collect::<Vec<_>>();
    let reloaded = Memory::load(memory.len(), sizes, 20_000);
    assert_eq!(reloaded.view(), memory.view());
    assert_eq!(reloaded.view_size(), memory.view_size());
}

#[test]
fn render_puts_marks_on_line_ends_before_each_limit() {
    let mut rng = Rng(7);
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for _ in 0..3_000 {
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        memory.append();
        drain(&mut memory, &store);
    }
    let view = render_view(&memory, &store);
    assert!(view.text.starts_with("<chat>\n") && view.text.ends_with("</chat>"));
    assert_eq!(view.marks.len(), 3, "a full view has all three marks");
    for (mark, limit) in view.marks.iter().zip(MARKS) {
        assert_eq!(&view.text[mark - 1..*mark], "\n", "a mark ends a line");
        assert!(view.text[..*mark].chars().count() <= limit);
    }
    let small = Memory::new(VIEW);
    assert!(
        render_view(&small, &store).marks.is_empty(),
        "marks past the end are skipped"
    );
}

#[test]
fn size_loop_retries_with_the_cut_and_keeps_the_shortest() {
    let long = "é".repeat(300); // 600 bytes
    match size_check(std::slice::from_ref(&long)) {
        SizeCheck::Retry(msg) => {
            assert!(msg.starts_with(
                "That line is 600 bytes; the limit is 512. It must end where it is cut here:\n"
            ));
            assert!(msg.ends_with("| ← LIMIT"));
            assert_eq!(cut_at_bytes(&long, 512).len(), 512);
        }
        other => panic!("expected a retry, got {other:?}"),
    }
    assert_eq!(
        cut_at_bytes(&long, 511).len(),
        510,
        "never splits a character"
    );
    let tries: Vec<String> = (0..TRIES).map(|k| "z".repeat(530 - k)).collect();
    assert_eq!(
        size_check(&tries),
        SizeCheck::Accept("z".repeat(530 - (TRIES - 1)))
    );
    assert_eq!(
        size_check(&["  fits  ".into()]),
        SizeCheck::Accept("fits".into())
    );
    assert_eq!(size_check(&["   ".into()]), SizeCheck::Fail);
}

#[test]
fn compactor_requests_carry_no_ids_and_the_scale_line() {
    assert_eq!(SCALE.len(), NODE, "SCALE must be exactly NODE bytes");
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for text in ["short one", &"w".repeat(2_000)] {
        store.push(Kind::User, text.to_string());
        memory.append();
    }
    drain(&mut memory, &store);
    let request = compact_request(
        &memory,
        &store,
        NodeId::new(1, 0),
        CompactPrompt::default().text("Chief"),
    );
    assert!(request.context.starts_with("<chat>\n") && request.context.ends_with("</chat>"));
    assert!(
        !request.context.contains("+1|") && !request.step.contains("0+1"),
        "no ids in a compactor call"
    );
    assert!(
        request.step.contains(SCALE)
            && request
                .step
                .contains("Merge these two lines into one, in at most 512 bytes:")
    );
}

#[test]
fn compactor_prompt_is_selectable_and_defaults_to_taelins() {
    assert_eq!(CompactPrompt::default(), CompactPrompt::Taelin);
    let taelin = CompactPrompt::Taelin.text("Chief");
    assert!(taelin.starts_with("You write the memory of Chief, an AI agent"));
    assert!(!taelin.contains("{agent}"), "every placeholder is filled");
    assert_eq!(
        taelin,
        CompactPrompt::Taelin.text("Chief"),
        "byte-identical across calls"
    );
    let cmux = CompactPrompt::Cmux.text("Chief");
    assert!(cmux.starts_with(&taelin), "ours extends Taelin's");
    assert!(cmux.contains("Never copy a secret into a line"));
    assert_eq!(
        CompactPrompt::Custom("Summarize for {agent}.".into()).text("Ada"),
        "Summarize for Ada."
    );
    assert_eq!(CompactPrompt::Cmux.name(), "cmux");
}

#[test]
fn zoom_refuses_addresses_whose_end_overflows() {
    // Audit round 1: `id + n` wrapped past u64::MAX, so the bounds check
    // passed and the store was asked for a message that does not exist.
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for text in ["a", "b"] {
        store.push(Kind::User, text);
        memory.append();
    }
    drain(&mut memory, &store);
    for (id, n) in [(u64::MAX, 1), (u64::MAX - 1, 2), (1 << 63, 1 << 63)] {
        assert_eq!(
            zoom(&memory, &store, id, n).unwrap_err().to_string(),
            format!("No line {id}+{n}.")
        );
    }
}
