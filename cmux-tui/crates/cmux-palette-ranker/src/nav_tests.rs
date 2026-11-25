use super::*;
use crate::scope_graph::{Descriptor, Parents};

fn descriptor(
    id: &str,
    prefix: Option<&str>,
    keywords: &[&str],
    parents: Parents,
    empty: i64,
) -> Descriptor {
    Descriptor {
        id: id.into(),
        title: id.into(),
        symbol: "command".into(),
        placeholder: String::new(),
        prefix: prefix.map(str::to_string),
        keywords: keywords.iter().map(|k| k.to_string()).collect(),
        parents,
        empty_query_selection: empty,
        open_action: None,
        owner: "client".into(),
    }
}

fn graph() -> Graph {
    Graph::build(
        descriptor("root", None, &[], Parents::Root {}, 0),
        vec![
            descriptor("tabs", Some("%"), &["tabs"], Parents::Root {}, 1),
            descriptor("actions", Some(">"), &["actions"], Parents::Anywhere {}, 0),
            descriptor("workspaces", None, &["ws"], Parents::Root {}, 0),
        ],
    )
}

struct Harness {
    graph: Graph,
    config: Config,
    state: State,
}

impl Harness {
    fn new() -> Harness {
        Harness { graph: graph(), config: Config::default(), state: State::default() }
    }

    fn send(&mut self, event: Event) -> Vec<Effect> {
        Reducer { graph: &self.graph, config: &self.config }.reduce(&mut self.state, event)
    }

    fn top(&self) -> &Level {
        self.state.levels.last().unwrap()
    }

    fn open(&mut self) -> Vec<Effect> {
        self.send(Event::Open { scope: None, query: String::new() })
    }

    /// A batch for the top level's current generation.
    fn rows(&mut self, rows: Vec<Row>, is_final: bool) -> Vec<Effect> {
        let (level_id, generation) = (self.top().id, self.top().generation);
        self.send(Event::Results {
            level_id,
            generation,
            rows,
            replace: true,
            is_final,
            empty_query_selection: None,
            provisional: false,
        })
    }
}

fn row(id: &str) -> Row {
    Row { id: id.into(), enters: None, drills: None, is_enabled: true }
}

fn rows(ids: &[&str]) -> Vec<Row> {
    ids.iter().map(|id| row(id)).collect()
}

fn load(level_id: i64, scope: &str, query: &str, generation: i64, context: Option<&str>) -> Effect {
    Effect::Load {
        level_id,
        scope: scope.into(),
        query: query.into(),
        generation,
        context: context.map(str::to_string),
    }
}

#[test]
fn open_pushes_the_root_and_loads_it() {
    let mut h = Harness::new();
    assert_eq!(h.open(), vec![load(1, "root", "", 1, None)]);
    assert!(h.state.is_open);
    assert_eq!(h.state.next_level_id, 2);
    assert_eq!(h.top().entry, Entry::Root {});
    assert!(h.top().pending_reset && h.top().is_loading);
}

#[test]
fn open_on_a_scope_pushes_it_above_the_root_with_the_query() {
    let mut h = Harness::new();
    let effects = h.send(Event::Open { scope: Some("tabs".into()), query: "abc".into() });
    assert_eq!(
        effects,
        vec![
            load(1, "root", "", 1, None),
            load(2, "tabs", "abc", 1, None),
            Effect::AnnounceEntered { scope: "tabs".into() },
        ]
    );
    assert_eq!(h.top().entry, Entry::Opened {});
    // Opening again cancels the old levels first, top first.
    let effects = h.send(Event::Open { scope: Some("root".into()), query: "q".into() });
    assert_eq!(effects[..2], [Effect::Cancel { level_id: 2 }, Effect::Cancel { level_id: 1 }]);
    assert_eq!(effects[2], load(3, "root", "q", 1, None));
}

#[test]
fn events_on_a_closed_palette_do_nothing() {
    let mut h = Harness::new();
    assert!(h.send(Event::Tab {}).is_empty());
    assert!(h.send(Event::SetQuery { text: "x".into(), allows_scope_entry: true }).is_empty());
    assert_eq!(h.state, State::default());
}

#[test]
fn a_prefix_typed_into_an_empty_query_enters_its_scope() {
    let mut h = Harness::new();
    h.open();
    let effects = h.send(Event::SetQuery { text: "%foo".into(), allows_scope_entry: true });
    assert_eq!(
        effects,
        vec![load(2, "tabs", "foo", 1, None), Effect::AnnounceEntered { scope: "tabs".into() }]
    );
    assert_eq!(h.top().entry, Entry::Prefix { prefix: "%".into() });
    assert!(!h.state.levels[0].pending_reset, "the parent keeps its selection");
}

#[test]
fn a_prefix_is_text_when_scope_entry_is_off_or_the_query_is_not_empty() {
    let mut h = Harness::new();
    h.open();
    let effects = h.send(Event::SetQuery { text: "%".into(), allows_scope_entry: false });
    assert_eq!(effects, vec![load(1, "root", "%", 2, None)]);
    h.send(Event::SetQuery { text: String::new(), allows_scope_entry: true });
    h.config.prefix_entry = false;
    h.send(Event::SetQuery { text: "%".into(), allows_scope_entry: true });
    assert_eq!(h.state.levels.len(), 1);
    h.config.prefix_entry = true;
    h.send(Event::SetQuery { text: "%>".into(), allows_scope_entry: true });
    assert_eq!(h.state.levels.len(), 1, "the query was not empty");
    assert!(h.send(Event::SetQuery { text: "%>".into(), allows_scope_entry: true }).is_empty());
}

#[test]
fn keyword_and_tab_enter_the_scope_and_consume_the_keyword() {
    let mut h = Harness::new();
    h.open();
    h.send(Event::SetQuery { text: " TABS ".into(), allows_scope_entry: true });
    let effects = h.send(Event::Tab {});
    assert_eq!(
        effects,
        vec![load(2, "tabs", "", 1, None), Effect::AnnounceEntered { scope: "tabs".into() }]
    );
    assert_eq!(h.top().entry, Entry::Keyword { keyword: "tabs".into() });
    let parent = &h.state.levels[0];
    assert_eq!(parent.query, "");
    assert_eq!(parent.generation, 3);
    assert!(parent.pending_reset && parent.is_loading);
}

#[test]
fn tab_enters_drills_or_opens_actions_of_the_selected_row() {
    let mut h = Harness::new();
    h.open();
    let mut scope_row = row("go-tabs");
    scope_row.enters = Some("tabs".into());
    let mut drill_row = row("ws-1");
    drill_row.drills = Some("workspaces".into());
    let mut disabled = row("off");
    disabled.is_enabled = false;
    h.rows(vec![scope_row, drill_row, row("plain"), disabled], true);
    assert_eq!(h.top().selection.as_deref(), Some("go-tabs"));
    let effects = h.send(Event::Tab {});
    assert_eq!(effects[0], load(2, "tabs", "", 1, Some("go-tabs")));
    assert_eq!(h.top().entry, Entry::Row { row: "go-tabs".into() });
    h.send(Event::ShiftTab {});
    h.send(Event::Select { row: "ws-1".into() });
    h.send(Event::Tab {});
    assert_eq!(h.top().entry, Entry::Drill { row: "ws-1".into() });
    assert_eq!(h.top().context().as_deref(), Some("ws-1"));
    h.send(Event::Escape {});
    h.send(Event::Select { row: "plain".into() });
    assert_eq!(h.send(Event::Tab {}), vec![Effect::OpenActions { row_id: "plain".into() }]);
    h.send(Event::Select { row: "off".into() });
    assert!(h.send(Event::Tab {}).is_empty());
}

#[test]
fn escape_pops_then_clears_then_dismisses() {
    let mut h = Harness::new();
    h.open();
    h.send(Event::SetQuery { text: "%x".into(), allows_scope_entry: true });
    let effects = h.send(Event::Escape {});
    assert_eq!(
        effects,
        vec![
            Effect::Cancel { level_id: 2 },
            load(1, "root", "", 2, None),
            Effect::AnnounceLeft { to: "root".into() }
        ]
    );
    h.send(Event::SetQuery { text: "abc".into(), allows_scope_entry: true });
    assert_eq!(h.send(Event::Escape {}), vec![load(1, "root", "", 4, None)]);
    assert_eq!(h.send(Event::Escape {}), vec![Effect::Cancel { level_id: 1 }, Effect::Dismiss {}]);
    assert!(!h.state.is_open && h.state.levels.is_empty());
}

#[test]
fn an_opened_scope_is_not_pushed_so_escape_clears_and_closes() {
    let mut h = Harness::new();
    h.send(Event::Open { scope: Some("tabs".into()), query: String::new() });
    let effects = h.send(Event::Escape {});
    assert_eq!(
        effects,
        vec![Effect::Cancel { level_id: 2 }, Effect::Cancel { level_id: 1 }, Effect::Dismiss {}]
    );
}

#[test]
fn backspace_on_empty_pops_and_pop_to_keeps_the_root() {
    let mut h = Harness::new();
    h.open();
    h.send(Event::Push { scope: "tabs".into(), row: None, query: "q".into() });
    assert!(h.send(Event::BackspaceOnEmpty {}).is_empty(), "the field is not empty");
    h.send(Event::SetQuery { text: String::new(), allows_scope_entry: true });
    h.send(Event::BackspaceOnEmpty {});
    assert_eq!(h.state.levels.len(), 1);
    assert!(h.send(Event::PopTo { index: -5 }).is_empty());
    assert!(h.send(Event::BackspaceOnEmpty {}).is_empty());
}

#[test]
fn pushes_stop_at_the_depth_limit() {
    let mut h = Harness::new();
    h.config.max_depth = 2;
    h.open();
    h.send(Event::Push { scope: "a".into(), row: Some("r".into()), query: String::new() });
    assert_eq!(h.top().entry, Entry::Command { row: Some("r".into()) });
    let effects = h.send(Event::Push { scope: "b".into(), row: None, query: String::new() });
    assert_eq!(effects, vec![Effect::Refused { refusal: Refusal::DepthLimit {} }]);
    // A prefix at the limit is text.
    h.send(Event::SetQuery { text: ">".into(), allows_scope_entry: true });
    assert_eq!(h.top().query, ">");
    // A max depth below 2 counts as 2.
    h.config.max_depth = 0;
    assert_eq!(h.send(Event::Push { scope: "b".into(), row: None, query: String::new() }).len(), 1);
}

#[test]
fn move_wraps_and_pins() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a", "b", "c"]), true);
    h.send(Event::Move { delta: -1 });
    assert_eq!(h.top().selection.as_deref(), Some("c"));
    assert!(h.top().selection_pinned);
    h.send(Event::Move { delta: 2 });
    assert_eq!(h.top().selection.as_deref(), Some("b"));
    h.send(Event::ClearSelection {});
    h.send(Event::Move { delta: 1 });
    assert_eq!(h.top().selection.as_deref(), Some("a"), "from no selection, down is the first row");
}

#[test]
fn results_for_another_generation_or_level_are_dropped() {
    let mut h = Harness::new();
    h.open();
    let effects = h.send(Event::Results {
        level_id: 1,
        generation: 9,
        rows: rows(&["a"]),
        replace: true,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    });
    assert!(effects.is_empty());
    assert!(h.top().rows.is_empty());
    h.send(Event::Results {
        level_id: 7,
        generation: 1,
        rows: rows(&["a"]),
        replace: true,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    });
    assert!(h.top().rows.is_empty());
}

#[test]
fn batches_append_and_dedupe_within_a_generation() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a", "b", "a"]), false);
    let (level_id, generation) = (h.top().id, h.top().generation);
    h.send(Event::Results {
        level_id,
        generation,
        rows: rows(&["b", "c"]),
        replace: false,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    });
    let ids: Vec<_> = h.top().rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids, ["a", "b", "c"]);
    assert!(!h.top().is_loading);
    assert_eq!(h.top().rows_query.as_deref(), Some(""));
}

#[test]
fn the_empty_query_selects_the_scopes_default_row() {
    let mut h = Harness::new();
    h.send(Event::Open { scope: Some("tabs".into()), query: String::new() });
    h.rows(rows(&["current", "previous", "older"]), true);
    assert_eq!(h.top().selection.as_deref(), Some("previous"));
    // A batch's own index wins and is clamped to the rows.
    let (level_id, generation) = (h.top().id, h.top().generation + 1);
    h.send(Event::Refresh {});
    h.send(Event::SetQuery { text: "x".into(), allows_scope_entry: true });
    h.send(Event::SetQuery { text: String::new(), allows_scope_entry: true });
    let _ = (level_id, generation);
    let (level_id, generation) = (h.top().id, h.top().generation);
    h.send(Event::Results {
        level_id,
        generation,
        rows: rows(&["a", "b"]),
        replace: true,
        is_final: true,
        empty_query_selection: Some(5),
        provisional: false,
    });
    assert_eq!(h.top().selection.as_deref(), Some("b"));
    assert_eq!(h.top().empty_query_selection, Some(5));
    // A typed query selects the first row.
    h.send(Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    h.rows(rows(&["x", "y"]), true);
    assert_eq!(h.top().selection.as_deref(), Some("x"));
}

#[test]
fn a_refresh_keeps_the_selection_by_id_or_by_position() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a", "b", "c"]), true);
    h.send(Event::Select { row: "b".into() });
    h.send(Event::Refresh {});
    h.rows(rows(&["z", "b"]), true);
    assert_eq!(h.top().selection.as_deref(), Some("b"));
    h.send(Event::Refresh {});
    h.rows(rows(&["p", "q", "r"]), true);
    assert_eq!(h.top().selection.as_deref(), Some("q"), "the gone row's position");
    h.send(Event::Refresh {});
    h.rows(rows(&[]), true);
    assert_eq!(h.top().selection, None);
}

#[test]
fn return_runs_the_selection_or_waits_for_fresh_rows() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a", "b"]), true);
    assert_eq!(
        h.send(Event::Activate { row: None }),
        vec![Effect::Run { level_id: 1, row_id: "a".into() }]
    );
    // New text: Return waits for its rows and runs their default row.
    h.send(Event::SetQuery { text: "b".into(), allows_scope_entry: true });
    assert!(h.send(Event::Activate { row: None }).is_empty());
    assert!(h.top().pending_submit);
    assert_eq!(h.rows(rows(&["b"]), false), vec![Effect::Run { level_id: 1, row_id: "b".into() }]);
    // A click runs its row.
    assert_eq!(
        h.send(Event::Activate { row: Some("b".into()) }),
        vec![Effect::Run { level_id: 1, row_id: "b".into() }]
    );
    assert!(h.send(Event::Activate { row: Some("nope".into()) }).is_empty());
}

#[test]
fn a_refresh_of_the_same_text_runs_the_highlighted_row_at_once() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a", "b"]), true);
    h.send(Event::Select { row: "b".into() });
    h.send(Event::Refresh {});
    assert_eq!(
        h.send(Event::Activate { row: None }),
        vec![Effect::Run { level_id: 1, row_id: "b".into() }]
    );
}

#[test]
fn provisional_rows_keep_the_reset_so_return_waits_for_the_ranked_batch() {
    let mut h = Harness::new();
    h.open();
    let (level_id, generation) = (h.top().id, h.top().generation);
    let provisional = |rows: Vec<Row>, provisional: bool, is_final: bool| Event::Results {
        level_id,
        generation,
        rows,
        replace: true,
        is_final,
        empty_query_selection: None,
        provisional,
    };
    h.send(provisional(rows(&["cached", "x"]), true, false));
    assert_eq!(h.top().selection.as_deref(), Some("cached"));
    assert!(h.top().pending_reset);
    assert!(h.send(Event::Activate { row: None }).is_empty());
    let effects = h.send(provisional(rows(&["ranked", "cached"]), false, true));
    assert_eq!(effects, vec![Effect::Run { level_id, row_id: "ranked".into() }]);
}

#[test]
fn a_pinned_choice_waits_for_its_row_then_runs_nothing_it_did_not_show() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a", "b"]), true);
    h.send(Event::Select { row: "b".into() });
    // Same text, new generation, so Return needs the rows of the current query.
    h.send(Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    h.send(Event::Move { delta: 1 });
    assert!(h.send(Event::Activate { row: None }).is_empty());
    assert!(h.top().pending_submit);
    let chosen = h.top().selection.clone().unwrap();
    // A partial batch without the chosen row: the choice waits; the selection shows a row.
    assert!(h.rows(rows(&["x", "y"]), false).is_empty());
    assert_eq!(h.top().pending_choice.as_deref(), Some(chosen.as_str()));
    // Its row lands in a later batch of the same generation: Return runs it.
    let (level_id, generation) = (h.top().id, h.top().generation);
    let effects = h.send(Event::Results {
        level_id,
        generation,
        rows: rows(&[chosen.as_str()]),
        replace: false,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    });
    assert_eq!(effects, vec![Effect::Run { level_id, row_id: chosen }]);
}

#[test]
fn a_pinned_choice_missing_from_the_final_rows_runs_nothing() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a", "b"]), true);
    h.send(Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    h.send(Event::Move { delta: 1 });
    h.send(Event::Activate { row: None });
    h.rows(rows(&["x"]), false);
    assert!(h.top().pending_choice.is_some());
    let (level_id, generation) = (h.top().id, h.top().generation);
    let effects = h.send(Event::Results {
        level_id,
        generation,
        rows: rows(&["y"]),
        replace: false,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    });
    assert!(effects.is_empty());
    assert!(!h.top().pending_submit && h.top().pending_choice.is_none());
}

#[test]
fn a_cleared_selection_survives_batches_until_the_user_moves() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a"]), true);
    h.send(Event::ClearSelection {});
    h.send(Event::Refresh {});
    h.rows(rows(&["a", "b"]), true);
    assert_eq!(h.top().selection, None);
    assert!(h.send(Event::Activate { row: None }).is_empty());
    // A pop back to the level resumes normal selection.
    h.send(Event::Push { scope: "tabs".into(), row: None, query: String::new() });
    h.send(Event::Escape {});
    assert!(!h.top().selection_suppressed);
}

#[test]
fn restart_clears_the_rows_and_edits_the_query() {
    let mut h = Harness::new();
    h.open();
    h.rows(rows(&["a"]), true);
    let effects = h.send(Event::Restart { query: "new".into() });
    assert_eq!(effects, vec![load(1, "root", "new", 2, None)]);
    assert!(h.top().rows.is_empty());
}

#[test]
fn entering_a_scope_row_on_return_pushes_it() {
    let mut h = Harness::new();
    h.open();
    let mut scope_row = row("go-actions");
    scope_row.enters = Some("actions".into());
    let mut unknown = row("go-nowhere");
    unknown.enters = Some("missing".into());
    h.rows(vec![scope_row, unknown], true);
    h.send(Event::Activate { row: None });
    assert_eq!(h.top().scope, "actions");
    assert_eq!(h.top().entry, Entry::Row { row: "go-actions".into() });
    h.send(Event::Escape {});
    assert_eq!(
        h.send(Event::Activate { row: Some("go-nowhere".into()) }),
        vec![Effect::Run { level_id: 1, row_id: "go-nowhere".into() }]
    );
}

/// The Swift app sends its value types' synthesized `Codable` JSON: these shapes must keep
/// decoding, and the reply must decode back into the Swift types.
#[test]
fn the_json_is_swifts_synthesized_codable() {
    let events = [
        (r#"{"open":{"query":""}}"#, Event::Open { scope: None, query: String::new() }),
        (r#"{"close":{}}"#, Event::Close {}),
        (
            r#"{"setQuery":{"_0":"x","allowsScopeEntry":false}}"#,
            Event::SetQuery { text: "x".into(), allows_scope_entry: false },
        ),
        (r#"{"activate":{}}"#, Event::Activate { row: None }),
        (
            r#"{"push":{"_0":"tabs","query":"q"}}"#,
            Event::Push { scope: "tabs".into(), row: None, query: "q".into() },
        ),
        (r#"{"move":{"_0":-1}}"#, Event::Move { delta: -1 }),
        (
            r#"{"results":{"levelID":1,"generation":2,"rows":[{"id":"a","isEnabled":true}],"replace":true,"isFinal":false,"provisional":false}}"#,
            Event::Results {
                level_id: 1,
                generation: 2,
                rows: rows(&["a"]),
                replace: true,
                is_final: false,
                empty_query_selection: None,
                provisional: false,
            },
        ),
        (r#"{"restart":{"query":"z"}}"#, Event::Restart { query: "z".into() }),
    ];
    for (json, event) in events {
        assert_eq!(serde_json::from_str::<Event>(json).unwrap(), event, "{json}");
    }
    let effects = serde_json::to_value(vec![
        load(1, "root", "", 1, None),
        Effect::Refused { refusal: Refusal::DepthLimit {} },
        Effect::AnnounceLeft { to: "root".into() },
        Effect::Run { level_id: 1, row_id: "a".into() },
    ])
    .unwrap();
    assert_eq!(
        effects,
        serde_json::json!([
            {"load": {"levelID": 1, "scope": "root", "query": "", "generation": 1}},
            {"refused": {"_0": {"depthLimit": {}}}},
            {"announceLeft": {"to": "root"}},
            {"run": {"levelID": 1, "rowID": "a"}},
        ])
    );
    let mut h = Harness::new();
    h.open();
    h.send(Event::Push { scope: "x".into(), row: Some("r".into()), query: String::new() });
    let state = serde_json::to_value(&h.state).unwrap();
    assert_eq!(state["nextLevelID"], 3);
    assert_eq!(state["levels"][1]["entry"], serde_json::json!({"command": {"_0": "r"}}));
    assert_eq!(state["levels"][0]["entry"], serde_json::json!({"root": {}}));
    let back: State = serde_json::from_value(state).unwrap();
    assert_eq!(back, h.state);
}

#[test]
fn answer_reduces_a_request() {
    let request: ReduceRequest = serde_json::from_value(serde_json::json!({
        "graph": serde_json::to_value(graph()).unwrap(),
        "config": {"prefixEntry": true, "keywordEntry": true, "maxDepth": 8},
        "state": serde_json::to_value(State::default()).unwrap(),
        "event": {"open": {"scope": "tabs", "query": ""}},
    }))
    .unwrap();
    let reply = answer(request);
    assert_eq!(reply.state.levels.len(), 2);
    assert_eq!(reply.effects.len(), 3);
}
