//! The app's input handle (`cmux_input_*`, R-INPUT stage S2) answers every focus call of a window exactly as the
//! window focus handle (`cmux_focus_*`) does: the recorded focus corpus (tests/focus/corpus.json) replays through
//! both, and each step's reply must come back with the same bytes (fields, strings, effects, overlays), then the same
//! focus history, window record and journal export. The router in between copies no event and no effect: over the
//! corpus, the input handle's focus events make no more allocations than the window handle's, and a topology report
//! makes at most the router's tab index on top.

use cmux_focus_core::close_aim::Press;
use cmux_focus_core::event::FocusEvent;
use cmux_focus_core::state::FocusState;
use cmux_focus_core::topology::Topology;
use cmux_layout_reducer_ffi::focus::{CmuxFocusReply, CmuxFocusStr, CmuxFocusStrings, Focus, NONE};
use cmux_layout_reducer_ffi::input::Input;
use serde_json::{Value, json};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

/// Counts this thread's allocations (tests run on their own threads).
struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

// SAFETY: every call goes to the system allocator; the count is a thread-local cell (no allocation).
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        // SAFETY: the caller's contract.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: the caller's contract.
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        // SAFETY: the caller's contract.
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn allocations() -> u64 {
    ALLOCATIONS.with(Cell::get)
}

const WINDOW: &str = "window-1";
/// A Mac's physical memory (it only bounds the key lanes).
const MEMORY: u64 = 16 << 30;

fn corpus() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/focus/corpus.json");
    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap()
}

/// `count` items at `ptr` (none when `count` is 0).
fn items<'a, T>(ptr: *const T, count: u32) -> &'a [T] {
    if count == 0 {
        return &[];
    }
    // SAFETY: a reply's arrays hold their counts of items until the handle's next call.
    unsafe { std::slice::from_raw_parts(ptr, count as usize) }
}

fn text(range: CmuxFocusStr, bytes: &[u8]) -> Value {
    if range.offset == NONE {
        return Value::Null;
    }
    let start = range.offset as usize;
    Value::String(String::from_utf8(bytes[start..start + range.len as usize].to_vec()).unwrap())
}

/// Every field a reply carries, its strings decoded, and its string bytes as they are.
fn snapshot(reply: &CmuxFocusReply) -> Value {
    let strings = items(reply.strings, reply.strings_len);
    let resolved = |r: &cmux_layout_reducer_ffi::focus::CmuxFocusResolved| {
        json!([r.kind, r.overlay, text(r.pane, strings), text(r.tab, strings)])
    };
    let effects: Vec<Value> = items(reply.effects, reply.effect_count)
        .iter()
        .map(|e| {
            json!([
                e.kind,
                e.context,
                e.active,
                text(e.pane, strings),
                text(e.tab, strings),
                resolved(&e.resolved)
            ])
        })
        .collect();
    json!({
        "flags": [reply.ok, reply.changed, reply.window_key, reply.app_active, reply.sidebar_hidden, reply.target,
                  reply.target_keyboard, reply.context, reply.browser_focus_mode_active, reply.dragging,
                  reply.has_expectation, reply.expectation_key, reply.expectation_target,
                  reply.expectation_target_keyboard, reply.omnibar_return, reply.returns_to_omnibar],
        "generation": [reply.generation, reply.expectation_generation],
        "pane": text(reply.pane, strings),
        "workspace": text(reply.workspace, strings),
        "expectation": [text(reply.expectation_id, strings), text(reply.expectation_away_from, strings)],
        "resolved": resolved(&reply.resolved),
        "underlying": resolved(&reply.underlying),
        "typing_tab": text(reply.typing_tab, strings),
        "overlays": items(reply.overlays, reply.overlay_count),
        "effects": effects,
        "string_bytes": strings,
    })
}

fn list(strings: &CmuxFocusStrings) -> Vec<Value> {
    let bytes = items(strings.bytes, strings.bytes_len);
    items(strings.items, strings.count).iter().map(|range| text(*range, bytes)).collect()
}

/// A window record's workspace, pane pairs, sorted: each handle lists its own map in that map's order.
fn pairs(strings: &CmuxFocusStrings) -> Vec<(String, String)> {
    let items = list(strings);
    let mut pairs: Vec<(String, String)> =
        items.chunks(2).map(|pair| (pair[0].to_string(), pair[1].to_string())).collect();
    pairs.sort();
    pairs
}

fn tabs(topology: &Topology) -> u64 {
    topology.panes.iter().map(|pane| pane.tabs.len() as u64).sum()
}

#[derive(Default)]
struct Totals {
    sequences: u64,
    event_steps: u64,
    topology_steps: u64,
    /// Allocations of the window handle and of the input handle over the focus events, and over the topology reports.
    events: [u64; 2],
    topologies: [u64; 2],
    /// The most the router's tab index may add over the topology reports: three per tab (its id, its surface, its
    /// terminal) and two for its maps.
    index_budget: u64,
}

/// Replays one corpus sequence through both handles: each step's reply must be the same, then the history, the
/// window record, the journal export and the Close Tab aim.
fn replay(sequence: &Value, totals: &mut Totals) {
    let seed = &sequence["seed"];
    let initial = serde_json::to_vec(&sequence["initial"]).unwrap();
    let mut old = Focus::new();
    let mut new = Input::new(MEMORY);
    assert!(new.window_open(WINDOW).is_some());
    assert!(old.import(&initial), "seed {seed}: the window handle refused the initial state");
    assert!(
        new.focus_import(WINDOW, &initial),
        "seed {seed}: the input handle refused the initial state"
    );
    assert_eq!(
        snapshot(new.focus_current(WINDOW).unwrap()),
        snapshot(old.current()),
        "seed {seed}: the reply after the import"
    );
    for (index, step) in sequence["steps"].as_array().unwrap().iter().enumerate() {
        let event: FocusEvent = serde_json::from_value(step["event"].clone()).unwrap();
        let (want, got) = match event {
            FocusEvent::Topology { topology } => {
                let (for_old, for_new) = (topology.clone(), topology);
                totals.index_budget += 3 * tabs(&for_new) + 2;
                totals.topology_steps += 1;
                let start = allocations();
                let reply = old.set_topology(for_old);
                totals.topologies[0] += allocations() - start;
                let want = snapshot(reply);
                let start = allocations();
                let reply = new.focus_set_topology(WINDOW, for_new).unwrap();
                totals.topologies[1] += allocations() - start;
                (want, snapshot(reply))
            }
            event => {
                totals.event_steps += 1;
                let start = allocations();
                let reply = old.send(&event);
                totals.events[0] += allocations() - start;
                let want = snapshot(reply);
                let start = allocations();
                let reply = new.focus_send(WINDOW, &event).unwrap();
                totals.events[1] += allocations() - start;
                (want, snapshot(reply))
            }
        };
        assert_eq!(got, want, "seed {seed} step {index}: the reply to {}", step["event"]);
    }
    let workspace = old.state().topology.workspace.clone();
    assert_eq!(
        list(new.focus_recent_panes(WINDOW, None).unwrap()),
        list(old.recent_panes(None)),
        "seed {seed}"
    );
    if let Some(workspace) = workspace.as_deref() {
        assert_eq!(
            list(new.focus_recent_panes(WINDOW, Some(workspace)).unwrap()),
            list(old.recent_panes(Some(workspace))),
            "seed {seed}: the history of {workspace}"
        );
    }
    assert_eq!(
        pairs(new.focus_remembered(WINDOW).unwrap()),
        pairs(old.remembered()),
        "seed {seed}"
    );
    let export: Value = serde_json::from_str(&new.focus_export(WINDOW).unwrap()).unwrap();
    assert_eq!(export, old.state().export(), "seed {seed}: the export");
    // The Close Tab aim: a move, its frame, a close that empties the pane, then a press soon after it.
    let pane = old.state().pane.clone();
    assert_eq!(
        new.focus_pane_moved(WINDOW, pane.as_deref()),
        old.pane_moved(pane.as_deref()),
        "seed {seed}"
    );
    let serial = old.pane_moved(None);
    assert_eq!(new.focus_pane_moved(WINDOW, None), serial, "seed {seed}: the move serial");
    old.frame_presented(serial, 10.0);
    new.focus_frame_presented(WINDOW, serial, 10.0);
    if let Some(pane) = pane.as_deref() {
        let close = Press { time: 10.1, is_key: true, is_repeat: false };
        old.pane_emptied(pane, close);
        new.focus_pane_emptied(WINDOW, pane, close);
    }
    for press in [
        Press { time: 10.2, is_key: true, is_repeat: true },
        Press { time: 10.3, is_key: true, is_repeat: false },
        Press { time: 30.0, is_key: false, is_repeat: false },
    ] {
        assert_eq!(
            new.focus_aims_at_emptied_pane(WINDOW, press),
            old.aims_at_emptied_pane(press),
            "seed {seed}: the Close Tab aim of {press:?}"
        );
    }
    totals.sequences += 1;
}

#[test]
fn the_input_handle_replies_to_every_corpus_step_as_the_window_handle() {
    let corpus = corpus();
    let mut totals = Totals::default();
    for sequence in corpus["sequences"].as_array().unwrap() {
        replay(sequence, &mut totals);
    }
    assert!(totals.sequences >= 100, "the corpus holds {} sequences", totals.sequences);
    assert!(
        totals.event_steps >= 1_000 && totals.topology_steps >= 100,
        "only {} event steps and {} topology steps",
        totals.event_steps,
        totals.topology_steps
    );
    // The router's buffers (its effects, a window's left pane) grow once or twice per handle: at most 8 a sequence.
    let warm_up = 8 * totals.sequences;
    let [window_handle, input_handle] = totals.events;
    assert!(
        input_handle <= window_handle + warm_up,
        "the input handle made {input_handle} allocations over {} focus events, the window handle {window_handle} \
         (a copy per event: the router copies the event, its effects or the state)",
        totals.event_steps
    );
    let [window_handle, input_handle] = totals.topologies;
    assert!(
        input_handle <= window_handle + totals.index_budget + warm_up,
        "the input handle made {input_handle} allocations over {} topology reports, the window handle \
         {window_handle}, the tab index may add {} (a copy of the topology?)",
        totals.topology_steps,
        totals.index_budget
    );
}

/// An equal topology report, after the first: no allocation in either handle (the router judges the ended sinks of every
/// report, which allocates only while one is recorded: the replay records none).
#[test]
fn an_equal_topology_report_makes_no_allocation_in_either_handle() {
    let corpus = corpus();
    let sequence = &corpus["sequences"][0];
    let initial = serde_json::to_vec(&sequence["initial"]).unwrap();
    let mut old = Focus::new();
    let mut new = Input::new(MEMORY);
    new.window_open(WINDOW).unwrap();
    assert!(old.import(&initial) && new.focus_import(WINDOW, &initial));
    let topology = FocusState::import(&initial).unwrap().topology;
    // One report first: the router's effect buffer grows once (its first event), then never again.
    old.set_topology(topology.clone());
    new.focus_set_topology(WINDOW, topology.clone()).unwrap();
    let (for_old, for_new) = (topology.clone(), topology);
    let start = allocations();
    let reply = old.set_topology(for_old);
    let window_handle = allocations() - start;
    let want = snapshot(reply);
    let start = allocations();
    let reply = new.focus_set_topology(WINDOW, for_new).unwrap();
    let input_handle = allocations() - start;
    assert_eq!(snapshot(reply), want);
    assert_eq!((window_handle, input_handle), (0, 0), "an equal topology report allocated");
}

#[test]
fn a_window_that_is_not_open_has_no_reply_and_another_windows_focus_is_its_own() {
    let mut new = Input::new(MEMORY);
    let event = FocusEvent::AppActive { active: true };
    assert!(new.focus_send(WINDOW, &event).is_none());
    assert!(new.focus_current(WINDOW).is_none());
    new.window_open(WINDOW).unwrap();
    new.window_open("window-2").unwrap();
    let before = new.focus_export("window-2").unwrap();
    assert_eq!(new.focus_send(WINDOW, &event).unwrap().ok, 1);
    assert_eq!(
        new.focus_export("window-2").unwrap(),
        before,
        "an event of one window changed another"
    );
    new.window_close(WINDOW);
    assert!(new.focus_send(WINDOW, &event).is_none(), "a closed window still answers");
}
