//! Pane layout under large and deep trees (`layout_tree_stress`).
//!
//! Two surfaces a person waits on per layout command:
//!
//! - the reducer ([`cmux_layout_reducer::apply`]) the daemon runs to validate a
//!   tab move, split, close or row resize, on screens of 1, 50 and 500 panes, and
//!   with 500 or 5000 more panes in other workspaces the command never touches;
//! - the `optimistic` JSON round trip the app pays per split, New Column, New
//!   Row or pane close (`cmux_layout_reducer_json`, operation `optimistic`):
//!   parse the request, answer, encode, on balanced trees of 1, 64 and 512 panes
//!   and on degenerate chains of depth 50, 200 and 500. The request is what the
//!   app's walks build from the whole screen (`support/optimistic_app.rs`): the
//!   found nodes and facts, never the trees.
//!
//! The timing sweep runs only when asked: `CMUX_STRESS=1`, or a `cargo test`
//! filter naming `layout_tree_stress_sweep`. It prints one `STRESS-LAYOUT-TREE`
//! JSON line per case. The work-count tests below always run.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::collections::BTreeMap;
use std::time::Instant;

#[path = "support/optimistic_app.rs"]
mod optimistic_app;

use cmux_layout_reducer::optimistic::{self, Dir, Node, Patch, Request};
use cmux_layout_reducer::{
    Column, Edge, LayoutOp, LayoutOpKind, LayoutState, Row, Screen as LayoutScreen, TabContent,
    Workspace, apply,
};
use optimistic_app::{Built, Screen};
use serde_json::{Value, json};

// ---------------------------------------------------------------------------
// Allocation counting: the work the deterministic tests count.

struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

/// Allocations `work` makes on this thread.
fn allocations<T>(work: impl FnOnce() -> T) -> (u64, T) {
    let before = ALLOCATIONS.with(Cell::get);
    let out = work();
    (ALLOCATIONS.with(Cell::get) - before, out)
}

// ---------------------------------------------------------------------------
// Reducer corpus.

const NEW_ID: u64 = 1 << 40;

/// One focused workspace whose screen has `panes` panes (two tabs each) in a
/// strip column with two rows, and `others` more panes spread over other
/// workspaces of 50 panes each.
struct Corpus {
    state: LayoutState,
    /// The focused screen's panes, in order.
    panes: Vec<u64>,
    column: u64,
    rows: Vec<u64>,
}

fn corpus(panes: usize, others: usize) -> Corpus {
    let mut next = 1u64;
    let mut id = || {
        next += 1;
        next
    };
    let mut state = LayoutState::default();
    let add_pane = |state: &mut LayoutState, id: &mut dyn FnMut() -> u64| {
        let pane = id();
        let tabs = vec![id(), id()];
        for tab in &tabs {
            state.tabs.insert(
                *tab,
                TabContent { runtime: *tab, terminal: Some(format!("term-{tab}")), dead: false },
            );
        }
        state.panes.insert(pane, tabs);
        pane
    };
    let workspace = id();
    let screen = id();
    let column = id();
    let focused: Vec<u64> = (0..panes).map(|_| add_pane(&mut state, &mut id)).collect();
    let rows = if panes >= 2 {
        let top = panes / 2;
        vec![
            Row { id: id(), height_permille: 500, len: top },
            Row { id: id(), height_permille: 500, len: panes - top },
        ]
    } else {
        Vec::new()
    };
    let row_ids = rows.iter().map(|row| row.id).collect();
    state.workspaces.push(Workspace {
        id: workspace,
        screens: vec![LayoutScreen {
            id: screen,
            columns: vec![Column { id: column, panes: focused.clone(), rows }],
            columns_active: true,
        }],
    });
    let mut left = others;
    while left > 0 {
        let count = left.min(50);
        left -= count;
        let workspace = id();
        let screen = id();
        let panes: Vec<u64> = (0..count).map(|_| add_pane(&mut state, &mut id)).collect();
        state.workspaces.push(Workspace {
            id: workspace,
            screens: vec![LayoutScreen {
                id: screen,
                columns: vec![Column::single(0, panes)],
                columns_active: false,
            }],
        });
    }
    assert!(cmux_layout_reducer::check_state(&state).is_empty());
    Corpus { state, panes: focused, column, rows: row_ids }
}

/// The reducer commands a person makes on the focused screen.
fn reducer_ops(corpus: &Corpus) -> Vec<(&'static str, LayoutOpKind)> {
    let first = corpus.panes[0];
    let last = *corpus.panes.last().expect("a pane");
    let tabs = &corpus.state.panes[&last];
    let mut ops = vec![
        ("reorder", LayoutOpKind::MoveTab { tab: tabs[0], pane: last, index: 2 }),
        (
            "split",
            LayoutOpKind::MoveTabToSplit {
                tab: tabs[1],
                pane: last,
                edge: Edge::Right,
                new_pane: NEW_ID,
                respawn: None,
            },
        ),
        ("close", LayoutOpKind::CloseTab { tab: tabs[1] }),
    ];
    if first != last {
        ops.push(("move", LayoutOpKind::MoveTab { tab: tabs[1], pane: first, index: 0 }));
    }
    if !corpus.rows.is_empty() {
        ops.push((
            "resize",
            LayoutOpKind::SetRowHeights {
                column: corpus.column,
                heights: vec![(corpus.rows[0], 400), (corpus.rows[1], 600)],
                fit: true,
            },
        ));
    }
    ops
}

fn run(state: &LayoutState, kind: &LayoutOpKind) -> LayoutState {
    let op = LayoutOp { key: String::new(), kind: kind.clone() };
    apply(state, &op).unwrap_or_else(|reject| panic!("{kind:?}: {reject}")).0
}

// ---------------------------------------------------------------------------
// Optimistic corpus.

fn split_node(id: &mut u64, dir: Dir, a: Node, b: Node) -> Node {
    *id += 1;
    Node::Split {
        split: Some(*id),
        split_id: Some(format!("split_{id:032x}")),
        dir,
        ratio: 0.5,
        a: Box::new(a),
        b: Box::new(b),
    }
}

/// A balanced tree over `panes`.
fn balanced(panes: &[u64], id: &mut u64, dir: Dir) -> Node {
    if let [pane] = panes {
        return Node::Leaf { pane: *pane };
    }
    let (a, b) = panes.split_at(panes.len() / 2);
    let other = if dir == Dir::Right { Dir::Down } else { Dir::Right };
    let a = balanced(a, id, other);
    let b = balanced(b, id, other);
    split_node(id, dir, a, b)
}

/// A degenerate chain: each split holds one pane and the rest (depth `panes - 1`), as
/// splitting the newest pane again and again makes.
fn chain(panes: &[u64], id: &mut u64) -> Node {
    let mut node = Node::Leaf { pane: *panes.last().expect("a pane") };
    for pane in panes.iter().rev().skip(1) {
        node = split_node(id, Dir::Right, Node::Leaf { pane: *pane }, node);
    }
    node
}

/// A strip screen of one column holding `tree` (the daemon keeps the compat tree beside it).
fn screen(tree: Node, panes: Vec<u64>) -> Screen {
    let column = optimistic_app::Column {
        id: 1 << 50,
        width: 1.0,
        layout: tree.clone(),
        dock: None,
        rows: Vec::new(),
    };
    Screen { layout: tree, columns: vec![column], zoomed_pane: None, panes }
}

fn tree_screen(shape: &str, size: usize) -> Screen {
    let panes: Vec<u64> = (1..=size as u64).collect();
    let mut id = 1 << 20;
    let tree = match shape {
        "balanced" => balanced(&panes, &mut id, Dir::Right),
        _ => chain(&panes, &mut id),
    };
    screen(tree, panes)
}

/// The app's per-command optimistic requests on `screen`, built by its walks: split the deepest
/// pane, New Column and New Row beside it, close it.
fn optimistic_built(screen: &Screen) -> Vec<(&'static str, Built)> {
    let deepest = *screen.panes.last().expect("a pane");
    let leaf = (1u64 << 62) | 1;
    let split = json!({"op": "split", "target": deepest, "dir": "down", "ratio": 0.5,
        "leaf": leaf, "split_id": "split_new"});
    let mut column = split.clone();
    column["column"] = json!({"handle": leaf, "width": 0.5});
    let mut row = split.clone();
    row["row"] = json!({"handle": leaf, "height": 300});
    let remove = json!({"op": "remove_pane", "pane": deepest});
    [("split", split), ("column", column), ("row", row), ("remove_pane", remove)]
        .into_iter()
        .map(|(name, intent)| (name, optimistic_app::request(screen, &intent).expect(name)))
        .collect()
}

fn optimistic_requests(screen: &Screen) -> Vec<(&'static str, Vec<u8>)> {
    optimistic_built(screen)
        .into_iter()
        .map(|(name, built)| (name, serde_json::to_vec(&built.request).expect("encode")))
        .collect()
}

/// What `cmux_layout_reducer_json` does for `optimistic`: parse, answer, encode.
fn round_trip(request: &[u8]) -> Result<Vec<u8>, String> {
    let request: Request = optimistic::parse_request(request).map_err(|e| e.to_string())?;
    serde_json::to_vec(&optimistic::respond(&request)).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Timing sweep.

fn sweep_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("layout_tree_stress_sweep"))
        && !args.iter().any(|a| a == "--exact")
}

/// Microseconds, as sampled.
#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1e6);
    }

    fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 10.0).round() / 10.0
        };
        json!({ "n": v.len(), "p50_us": at(0.5), "p95_us": at(0.95), "max_us": at(1.0) })
    }
}

/// Samples per case: enough for a stable p95 while the whole sweep stays in seconds.
fn samples_for(size: usize) -> usize {
    if size >= 2000 { 60 } else { 200 }
}

#[test]
fn layout_tree_stress_sweep() {
    if !sweep_selected() {
        return;
    }
    let started = Instant::now();
    for (panes, others) in [(1, 0), (50, 0), (500, 0), (1, 500), (1, 5000), (50, 5000)] {
        let corpus = corpus(panes, others);
        for (name, kind) in reducer_ops(&corpus) {
            let (allocs, _) = allocations(|| run(&corpus.state, &kind));
            let mut samples = Samples::default();
            for _ in 0..samples_for(panes + others) {
                let start = Instant::now();
                let next = run(&corpus.state, &kind);
                samples.push(start);
                drop(next);
            }
            let mut line = samples.summary();
            line["surface"] = json!("reducer");
            line["op"] = json!(name);
            line["screen_panes"] = json!(panes);
            line["other_panes"] = json!(others);
            line["allocations"] = json!(allocs);
            println!("STRESS-LAYOUT-TREE {line}");
        }
    }
    for (shape, size) in [
        ("balanced", 1),
        ("balanced", 64),
        ("balanced", 512),
        ("chain", 2),
        ("chain", 50),
        ("chain", 64),
        ("chain", 200),
        ("chain", 256),
        ("chain", 500),
    ] {
        let screen = tree_screen(shape, size);
        for (name, request) in optimistic_requests(&screen) {
            let (allocs, answer) = allocations(|| round_trip(&request));
            let Ok(answer) = answer else {
                let line = json!({
                    "surface": "optimistic", "op": name, "shape": shape, "panes": size,
                    "error": answer.unwrap_err(), "request_bytes": request.len(),
                });
                println!("STRESS-LAYOUT-TREE {line}");
                continue;
            };
            let mut samples = Samples::default();
            for _ in 0..samples_for(size) {
                let start = Instant::now();
                let out = round_trip(&request);
                samples.push(start);
                drop(out);
            }
            let mut line = samples.summary();
            line["surface"] = json!("optimistic");
            line["op"] = json!(name);
            line["shape"] = json!(shape);
            line["panes"] = json!(size);
            line["request_bytes"] = json!(request.len());
            line["answer_bytes"] = json!(answer.len());
            line["allocations"] = json!(allocs);
            println!("STRESS-LAYOUT-TREE {line}");
        }
    }
    println!("STRESS-LAYOUT-TREE {}", json!({ "sweep_ms": started.elapsed().as_millis() }));
}

// ---------------------------------------------------------------------------
// Deterministic work counts (always run).

/// A reducer command on one screen should cost the same however many panes
/// other workspaces hold: the daemon validates every tab move with it, so a
/// cost that grows with the whole layout grows with every workspace a person
/// opens. Today it does not hold: `apply` clones the whole state and checks
/// every pane twice, and the daemon projects its whole state around it twice
/// more (https://github.com/manaflow-ai/cmux/issues/45007). Run it with `--ignored` to see the gap.
#[test]
#[ignore = "apply is O(all panes) per command; follow-up https://github.com/manaflow-ai/cmux/issues/45007"]
fn reducer_command_work_does_not_grow_with_untouched_workspaces() {
    let small = corpus(4, 0);
    let large = corpus(4, 5000);
    let ops_small = reducer_ops(&small);
    let ops_large = reducer_ops(&large);
    let mut report = BTreeMap::new();
    for ((name, kind_small), (_, kind_large)) in ops_small.iter().zip(&ops_large) {
        let (a, _) = allocations(|| run(&small.state, kind_small));
        let (b, _) = allocations(|| run(&large.state, kind_large));
        report.insert(*name, (a, b));
    }
    for (name, (small, large)) in &report {
        assert!(
            *large <= small + 64,
            "{name}: {small} allocations with 4 panes, {large} with 5000 more in other \
             workspaces (every op: {report:?})"
        );
    }
}

/// Until that lands, the bound that holds and must keep holding: a command's
/// work is at most linear in the layout, a few allocations per pane, never
/// quadratic (500 and 5000 panes cost the same per pane).
#[test]
fn reducer_command_work_is_at_most_linear_in_the_layout() {
    let per_pane = |others: usize| {
        let corpus = corpus(4, others);
        reducer_ops(&corpus)
            .iter()
            .map(|(name, kind)| {
                let (allocs, _) = allocations(|| run(&corpus.state, kind));
                (*name, allocs as f64 / (others + 4) as f64)
            })
            .collect::<BTreeMap<_, _>>()
    };
    let (mid, large) = (per_pane(500), per_pane(5000));
    for (name, at_mid) in &mid {
        let at_large = large[name];
        assert!(
            at_large <= at_mid * 1.25 && at_large <= 8.0,
            "{name}: {at_mid:.2} allocations per pane at 500 panes, {at_large:.2} at 5000"
        );
    }
}

/// The optimistic round trip costs the same however large the tree is: the request carries the
/// found nodes and facts, the answer a patch, so a 500-pane chain allocates what a 50-pane one
/// does (the whole-screen shape took 986 us for New Column at 64 panes and grew with every pane).
#[test]
fn optimistic_round_trip_work_does_not_grow_with_the_tree() {
    for name in ["split", "column", "row", "remove_pane"] {
        let work = |shape: &str, size: usize| {
            let screen = tree_screen(shape, size);
            let request = optimistic_requests(&screen)
                .into_iter()
                .find(|(n, _)| *n == name)
                .expect("request")
                .1;
            let (allocs, answer) = allocations(|| round_trip(&request));
            answer.unwrap_or_else(|e| panic!("{name} {shape} {size}: {e}"));
            (allocs, request.len())
        };
        for (shape, small, large) in [("chain", 50, 500), ("balanced", 64, 512)] {
            let (at_small, at_large) = (work(shape, small), work(shape, large));
            assert!(
                at_large.0 <= at_small.0 + 4 && at_large.1 <= at_small.1 + 16,
                "{name}: (allocations, request bytes) {at_small:?} on a {small}-pane {shape}, \
                 {at_large:?} on a {large}-pane {shape}"
            );
        }
    }
}

/// A screen split into a chain deeper than serde_json's default nesting limit
/// (128) still gets its optimistic view: the request answers and its patch
/// spliced into the screen shows the new pane, or hides the closed one.
#[test]
fn optimistic_answers_a_chain_deeper_than_the_json_nesting_limit() {
    for size in [127, 128, 300, 500] {
        let screen = tree_screen("chain", size);
        let deepest = *screen.panes.last().expect("a pane");
        for (name, built) in optimistic_built(&screen) {
            let request = serde_json::to_vec(&built.request).expect("encode");
            let answer = round_trip(&request)
                .unwrap_or_else(|e| panic!("{name} on a {size}-pane chain: {e}"));
            let answer: Value = optimistic::parse_value(&answer).expect("answer parses");
            assert!(!answer.is_null(), "{name} on a {size}-pane chain answered null");
            let patch: Patch = serde_json::from_value(answer).expect("patch");
            let view = optimistic_app::splice(&screen, &built, &patch);
            let shown = view.layout.contains((1 << 62) | 1);
            let kept = view.layout.contains(deepest);
            assert_eq!((shown, kept), (name != "remove_pane", name != "remove_pane"), "{name}");
        }
    }
}

/// A request nested beyond any layout a person can make is refused, not a
/// stack overflow of the app.
#[test]
fn optimistic_refuses_absurd_nesting() {
    let mut deep = String::from(r#"{"op":"insert_at_divider","split":1,"layout":"#);
    for _ in 0..200_000 {
        deep.push_str(
            r#"{"type":"split","dir":"right","ratio":0.5,"a":{"type":"leaf","pane":1},"b":"#,
        );
    }
    assert!(round_trip(deep.as_bytes()).is_err());
    assert!(round_trip(b"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[").is_err());
}

/// Degenerate inputs: an empty tree id set, one huge split id, duplicate panes.
#[test]
fn optimistic_degenerate_trees() {
    let huge = "\u{1F600}".repeat(100_000);
    let tree = Node::Split {
        split: Some(1),
        split_id: Some(huge),
        dir: Dir::Right,
        ratio: 0.5,
        a: Box::new(Node::Leaf { pane: 7 }),
        b: Box::new(Node::Leaf { pane: 7 }),
    };
    for (name, request) in optimistic_requests(&screen(tree, vec![7, 7])) {
        round_trip(&request).unwrap_or_else(|e| panic!("{name}: {e}"));
    }
    let lone = screen(Node::Leaf { pane: 1 }, vec![1]);
    for (name, request) in optimistic_requests(&lone) {
        round_trip(&request).unwrap_or_else(|e| panic!("{name}: {e}"));
    }
}
