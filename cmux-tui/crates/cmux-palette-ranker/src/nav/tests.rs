//! The reducer's rules (plans/cmux-next/palette-scopes.md 4.3) and the seeded property tests of
//! its invariants (4.4: I1-I6, P1-P6).

use super::*;
use serde_json::{Value, json};
use std::collections::BTreeSet;

fn scope(id: &str, prefix: Option<&str>, keywords: &[&str], parents: Parents) -> Descriptor {
    Descriptor {
        id: id.to_owned(),
        title: id.to_owned(),
        prefix: prefix.map(str::to_owned),
        keywords: keywords.iter().map(|k| (*k).to_owned()).collect(),
        parents,
        ..Descriptor::default()
    }
}

fn only(ids: &[&str]) -> Parents {
    Parents::Only(ids.iter().map(|id| (*id).to_owned()).collect::<BTreeSet<_>>())
}

fn graph() -> Graph {
    let mut tabs = scope("tabs", Some("@"), &["tabs"], Parents::Root);
    tabs.empty_query_selection = 1;
    Graph::new(
        Descriptor { id: ROOT.to_owned(), title: "Commands".to_owned(), ..Descriptor::default() },
        vec![
            tabs,
            scope("workspaces", Some("#"), &["ws", "Workspaces"], Parents::Root),
            scope("actions", None, &[], Parents::Anywhere),
            scope("files", Some("/"), &["files"], only(&["root", "workspaces"])),
            scope("feed", Some("!"), &["feed", "inbox"], Parents::Root),
            scope("history", Some(";"), &["history"], only(&["tabs"])),
            scope("apps", None, &["apps"], Parents::Root),
            scope("nested", Some("$"), &["nested"], Parents::Anywhere),
        ],
    )
}

fn reducer() -> Reducer {
    Reducer::new(graph(), Config::default())
}

fn rows(ids: &[&str]) -> Vec<Row> {
    ids.iter().map(|id| Row::new(*id)).collect()
}

fn results(state: &State, ids: &[&str], is_final: bool) -> Event {
    let top = state.top().expect("open");
    Event::Results {
        level_id: top.id,
        generation: top.generation,
        rows: rows(ids),
        replace: true,
        is_final,
        empty_query_selection: None,
        provisional: false,
    }
}

fn open(reducer: &Reducer) -> State {
    let mut state = State::default();
    reducer.reduce(&mut state, Event::Open { scope: None, query: String::new() });
    state
}

#[test]
fn open_makes_the_root_and_an_opened_scope_above_it() {
    let reducer = reducer();
    let mut state = State::default();
    let effects =
        reducer.reduce(&mut state, Event::Open { scope: Some("tabs".into()), query: "abc".into() });
    assert_eq!(state.levels.len(), 2);
    assert_eq!(state.levels[0].entry, Entry::Root);
    assert_eq!(state.levels[0].query, "");
    assert_eq!(state.levels[1].entry, Entry::Opened);
    assert_eq!(state.levels[1].query, "abc");
    assert_eq!(
        effects,
        vec![
            Effect::Load {
                level_id: 1,
                scope: "root".into(),
                query: "".into(),
                generation: 1,
                context: None
            },
            Effect::Load {
                level_id: 2,
                scope: "tabs".into(),
                query: "abc".into(),
                generation: 1,
                context: None
            },
            Effect::AnnounceEntered { scope: "tabs".into() },
        ]
    );
    // Opening the root by name is a plain open with the query on the root.
    let effects =
        reducer.reduce(&mut state, Event::Open { scope: Some("root".into()), query: "q".into() });
    assert_eq!(state.levels.len(), 1);
    assert_eq!(state.levels[0].query, "q");
    assert_eq!(effects[..2], [Effect::Cancel { level_id: 2 }, Effect::Cancel { level_id: 1 }]);
}

#[test]
fn a_prefix_in_an_empty_query_enters_its_scope_with_the_rest_as_query() {
    let reducer = reducer();
    let mut state = open(&reducer);
    let effects = reducer
        .reduce(&mut state, Event::SetQuery { text: "@foo".into(), allows_scope_entry: true });
    assert_eq!(state.levels.len(), 2);
    assert_eq!(state.levels[1].scope, "tabs");
    assert_eq!(state.levels[1].entry, Entry::Prefix("@".into()));
    assert_eq!(state.levels[1].query, "foo");
    assert_eq!(state.levels[0].query, "");
    assert!(matches!(effects.last(), Some(Effect::AnnounceEntered { scope }) if scope == "tabs"));
    // Not from a scope that does not allow it, not with text, not when refused by the caller.
    let mut state = open(&reducer);
    reducer.reduce(&mut state, Event::SetQuery { text: "@".into(), allows_scope_entry: false });
    assert_eq!(state.levels.len(), 1);
    reducer.reduce(&mut state, Event::SetQuery { text: "a@".into(), allows_scope_entry: true });
    reducer.reduce(&mut state, Event::SetQuery { text: "a@b".into(), allows_scope_entry: true });
    assert_eq!(state.levels.len(), 1);
    // A prefix with a combining mark is another grapheme: no scope.
    let mut state = open(&reducer);
    reducer
        .reduce(&mut state, Event::SetQuery { text: "@\u{301}x".into(), allows_scope_entry: true });
    assert_eq!(state.levels.len(), 1);
}

#[test]
fn backspace_on_empty_pops_and_the_root_consumes_it() {
    let reducer = reducer();
    let mut state = open(&reducer);
    reducer.reduce(&mut state, Event::SetQuery { text: "#".into(), allows_scope_entry: true });
    assert_eq!(state.levels.len(), 2);
    let effects = reducer.reduce(&mut state, Event::BackspaceOnEmpty);
    assert_eq!(state.levels.len(), 1);
    assert_eq!(
        effects,
        vec![
            Effect::Cancel { level_id: 2 },
            Effect::Load {
                level_id: 1,
                scope: "root".into(),
                query: "".into(),
                generation: 2,
                context: None
            },
            Effect::AnnounceLeft { to: "root".into() },
        ]
    );
    assert!(reducer.reduce(&mut state, Event::BackspaceOnEmpty).is_empty());
    assert!(state.is_open);
}

#[test]
fn tab_enters_a_keyword_then_scope_row_then_drill_else_actions() {
    let reducer = reducer();
    let mut state = open(&reducer);
    reducer.reduce(&mut state, Event::SetQuery { text: " WS ".into(), allows_scope_entry: true });
    reducer.reduce(&mut state, Event::Tab);
    assert_eq!(state.levels.len(), 2);
    assert_eq!(state.levels[1].entry, Entry::Keyword("ws".into()));
    assert_eq!(state.levels[0].query, "");
    reducer.reduce(&mut state, Event::ShiftTab);

    let top = state.top().unwrap();
    let batch = Event::Results {
        level_id: top.id,
        generation: top.generation,
        rows: vec![
            Row { id: "r1".into(), enters: Some("feed".into()), drills: None, is_enabled: true },
            Row { id: "r2".into(), enters: None, drills: Some("actions".into()), is_enabled: true },
            Row { id: "r3".into(), enters: Some("nowhere".into()), drills: None, is_enabled: true },
            Row { id: "r4".into(), enters: None, drills: None, is_enabled: false },
        ],
        replace: true,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    };
    reducer.reduce(&mut state, batch);
    assert_eq!(state.levels[0].selection.as_deref(), Some("r1"));
    reducer.reduce(&mut state, Event::Tab);
    assert_eq!(state.levels[1].entry, Entry::Row("r1".into()));
    reducer.reduce(&mut state, Event::ShiftTab);
    reducer.reduce(&mut state, Event::Select { row_id: "r2".into() });
    let effects = reducer.reduce(&mut state, Event::Tab);
    assert_eq!(state.levels[1].entry, Entry::Drill("r2".into()));
    assert!(matches!(&effects[0], Effect::Load { context: Some(row), .. } if row == "r2"));
    reducer.reduce(&mut state, Event::ShiftTab);
    reducer.reduce(&mut state, Event::Select { row_id: "r3".into() });
    assert_eq!(
        reducer.reduce(&mut state, Event::Tab),
        vec![Effect::OpenActions { row_id: "r3".into() }]
    );
    reducer.reduce(&mut state, Event::Select { row_id: "r4".into() });
    assert!(reducer.reduce(&mut state, Event::Tab).is_empty());
}

#[test]
fn escape_pops_pushed_levels_then_clears_then_closes() {
    let reducer = reducer();
    let mut state = State::default();
    reducer.reduce(&mut state, Event::Open { scope: Some("tabs".into()), query: "x".into() });
    reducer.reduce(&mut state, Event::SetQuery { text: "".into(), allows_scope_entry: true });
    reducer.reduce(&mut state, Event::SetQuery { text: ";".into(), allows_scope_entry: true });
    assert_eq!(state.levels.len(), 3);
    reducer.reduce(&mut state, Event::Escape);
    assert_eq!(state.levels.len(), 2);
    reducer.reduce(&mut state, Event::SetQuery { text: "y".into(), allows_scope_entry: true });
    reducer.reduce(&mut state, Event::Escape);
    assert_eq!(state.levels.len(), 2);
    assert_eq!(state.levels[1].query, "");
    let effects = reducer.reduce(&mut state, Event::Escape);
    assert!(!state.is_open);
    assert_eq!(effects.last(), Some(&Effect::Dismiss));
}

#[test]
fn return_waits_for_fresh_rows_and_runs_the_default_row() {
    let reducer = reducer();
    let mut state = open(&reducer);
    let batch = results(&state, &["a", "b"], true);
    reducer.reduce(&mut state, batch);
    reducer.reduce(&mut state, Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    assert!(reducer.reduce(&mut state, Event::Activate { row_id: None }).is_empty());
    assert!(state.levels[0].pending_submit);
    let batch = results(&state, &["c", "d"], true);
    let effects = reducer.reduce(&mut state, batch);
    assert_eq!(effects, vec![Effect::Run { level_id: 1, row_id: "c".into() }]);
}

#[test]
fn a_chosen_row_survives_fresh_batches_and_waits_for_a_later_batch() {
    let reducer = reducer();
    let mut state = open(&reducer);
    reducer.reduce(&mut state, Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    let batch = results(&state, &["a", "b", "c"], false);
    reducer.reduce(&mut state, batch);
    reducer.reduce(&mut state, Event::Move { delta: 2 });
    assert_eq!(state.levels[0].selection.as_deref(), Some("c"));
    // A fresh batch of the same query keeps the chosen row by id.
    reducer.reduce(&mut state, Event::Refresh);
    let batch = results(&state, &["c", "a"], true);
    reducer.reduce(&mut state, batch);
    assert_eq!(state.levels[0].selection.as_deref(), Some("c"));
    // A refresh of the same text: Return runs the highlighted row at once.
    let mut state = open(&reducer);
    reducer.reduce(&mut state, Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    let batch = results(&state, &["a", "b", "c"], false);
    reducer.reduce(&mut state, batch);
    reducer.reduce(&mut state, Event::Select { row_id: "c".into() });
    reducer.reduce(&mut state, Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    reducer.reduce(&mut state, Event::Refresh);
    // rows are stale for this generation but of the same text: Return runs at once.
    assert_eq!(
        reducer.reduce(&mut state, Event::Activate { row_id: None }),
        vec![Effect::Run { level_id: 1, row_id: "c".into() }]
    );
}

#[test]
fn an_empty_query_selects_the_scopes_row_clamped() {
    let reducer = reducer();
    let mut state = State::default();
    reducer.reduce(&mut state, Event::Open { scope: Some("tabs".into()), query: String::new() });
    let batch = results(&state, &["current", "previous"], true);
    reducer.reduce(&mut state, batch);
    assert_eq!(state.levels[1].selection.as_deref(), Some("previous"));
    reducer.reduce(&mut state, Event::Refresh);
    let batch = results(&state, &["only"], true);
    reducer.reduce(&mut state, batch);
    assert_eq!(state.levels[1].selection.as_deref(), Some("only"));
}

#[test]
fn later_batches_append_deduplicated_and_older_generations_are_ignored() {
    let reducer = reducer();
    let mut state = open(&reducer);
    let first = results(&state, &["a", "b", "a"], false);
    reducer.reduce(&mut state, first);
    let top = state.top().unwrap();
    let more = Event::Results {
        level_id: top.id,
        generation: top.generation,
        rows: rows(&["b", "c"]),
        replace: false,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    };
    reducer.reduce(&mut state, more);
    let ids: Vec<_> = state.levels[0].rows.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(ids, ["a", "b", "c"]);
    let stale = Event::Results {
        level_id: 1,
        generation: 0,
        rows: rows(&["z"]),
        replace: true,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    };
    let before = state.clone();
    assert!(reducer.reduce(&mut state, stale).is_empty());
    assert_eq!(state, before);
}

#[test]
fn clear_selection_survives_batches_until_navigation() {
    let reducer = reducer();
    let mut state = open(&reducer);
    let batch = results(&state, &["a", "b"], true);
    reducer.reduce(&mut state, batch);
    reducer.reduce(&mut state, Event::ClearSelection);
    reducer.reduce(&mut state, Event::Refresh);
    let batch = results(&state, &["a", "b"], true);
    reducer.reduce(&mut state, batch);
    assert_eq!(state.levels[0].selection, None);
    assert!(reducer.reduce(&mut state, Event::Activate { row_id: None }).is_empty());
    // From no selection, -1 wraps from index -1 to the first row (the Swift reducer's arithmetic).
    reducer.reduce(&mut state, Event::Move { delta: -1 });
    assert_eq!(state.levels[0].selection.as_deref(), Some("a"));
}

#[test]
fn depth_is_limited() {
    let reducer = Reducer::new(graph(), Config { max_depth: 0, ..Config::default() });
    assert_eq!(reducer.config.max_depth, 2);
    let mut state = State::default();
    reducer.reduce(&mut state, Event::Open { scope: Some("tabs".into()), query: String::new() });
    let effects = reducer
        .reduce(&mut state, Event::Push { scope: "feed".into(), row: None, query: String::new() });
    assert_eq!(effects, vec![Effect::Refused { reason: Refusal::DepthLimit }]);
}

#[test]
fn the_graph_refuses_collisions_and_bad_prefixes() {
    let graph = Graph::new(
        Descriptor { id: ROOT.into(), ..Descriptor::default() },
        vec![
            scope("a", Some("@"), &["Alpha", "alpha", ""], Parents::Root),
            scope("root", None, &[], Parents::Root),
            scope("a", None, &[], Parents::Root),
            scope("b", Some("@"), &["alpha", "beta"], Parents::Root),
            scope("c", Some("x"), &[], Parents::Root),
            scope("d", Some("@"), &["alpha"], only(&["tabs"])),
            scope("e", Some("€"), &[], Parents::Root),
        ],
    );
    let ids: Vec<_> = graph.scopes.iter().map(|d| d.id.as_str()).collect();
    assert_eq!(ids, ["a", "b", "c", "d", "e"]);
    assert_eq!(graph.descriptor("a").unwrap().keywords, ["alpha"]);
    assert_eq!(graph.descriptor("b").unwrap().prefix, None);
    assert_eq!(graph.descriptor("b").unwrap().keywords, ["beta"]);
    assert_eq!(graph.descriptor("d").unwrap().prefix.as_deref(), Some("@"));
    assert_eq!(graph.descriptor("e").unwrap().prefix.as_deref(), Some("€"));
    assert_eq!(
        graph.problems,
        vec![
            Problem::ReservedId { id: "root".into() },
            Problem::DuplicateId { id: "a".into() },
            Problem::PrefixCollision { id: "b".into(), with: "a".into(), prefix: "@".into() },
            Problem::KeywordCollision { id: "b".into(), with: "a".into(), keyword: "alpha".into() },
            Problem::InvalidPrefix { id: "c".into(), prefix: "x".into() },
        ]
    );
    assert_eq!(graph.child_by_keyword("root", " ALPHA\t").map(|d| d.id.as_str()), Some("a"));
    assert_eq!(graph.child_by_keyword("tabs", "alpha").map(|d| d.id.as_str()), Some("d"));
    assert!(graph.child_by_keyword("root", "  ").is_none());
    assert!(
        graph.can_enter("d", "tabs")
            && !graph.can_enter("d", "root")
            && !graph.can_enter("root", "root")
    );
    assert_eq!(graph.children("root").len(), 4);
    assert!(
        !graph::is_valid_prefix("@@")
            && !graph::is_valid_prefix(" ")
            && !graph::is_valid_prefix("é")
    );
    assert!(
        graph::is_valid_prefix("+") && graph::is_valid_prefix("^") && graph::is_valid_prefix("_")
    );
}

#[test]
fn the_handle_answers_json_and_sends_rows_only_when_they_change() {
    let mut nav = Nav::new(Reducer::default());
    let graph: Value = serde_json::from_slice(
        &nav.call(
            json!({"op": "graph", "install": true, "root": {"id": "root", "title": "All"},
                   "scopes": [{"id": "tabs", "prefix": "@", "keywords": ["Tabs"], "parents": {"kind": "root"}}]})
            .to_string()
            .as_bytes(),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(graph["scopes"][0]["keywords"], json!(["tabs"]));
    assert_eq!(graph["root"]["parents"], json!({"kind": "only", "scopes": []}));
    let config: Value = serde_json::from_slice(
        &nav.call(
            br#"{"op":"config","config":{"prefixEntry":true,"keywordEntry":true,"maxDepth":1}}"#,
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(config["maxDepth"], 2);
    let step: Value = serde_json::from_slice(
        &nav.call(br#"{"op":"reduce","events":[{"type":"open"},{"type":"setQuery","text":"@x"}]}"#)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(step["state"]["levels"][1]["entry"], json!({"kind": "prefix", "value": "@"}));
    assert_eq!(step["state"]["levels"][1]["rows"], json!([]));
    assert_eq!(step["effects"][1]["type"], "load");
    assert_eq!(step["effects"][1]["levelID"], 2);
    let step: Value = serde_json::from_slice(
        &nav.call(
            br#"{"op":"reduce","events":[{"type":"results","levelID":2,"generation":1,"rows":[{"id":"a"},{"id":"b","drills":"tabs","isEnabled":false}],"replace":true,"isFinal":true}]}"#,
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        step["state"]["levels"][1]["rows"],
        json!([{"id": "a", "isEnabled": true}, {"id": "b", "drills": "tabs", "isEnabled": false}])
    );
    assert!(step["state"]["levels"][0].get("rows").is_none());
    assert_eq!(step["state"]["levels"][1]["selection"], "a");
    let step: Value = serde_json::from_slice(
        &nav.call(br#"{"op":"reduce","events":[{"type":"move","delta":1}]}"#).unwrap(),
    )
    .unwrap();
    assert!(step["state"]["levels"][1].get("rows").is_none());
    assert_eq!(step["state"]["levels"][1]["selection"], "b");
    let full: Value =
        serde_json::from_slice(&nav.call(br#"{"op":"state","full":true}"#).unwrap()).unwrap();
    assert_eq!(full["levels"][0]["rows"], json!([]));
    assert!(nav.call(b"{\"op\":\"nope\"}").is_err());
}

// MARK: Property tests (section 4.4)

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

const SCOPES: [&str; 8] =
    ["tabs", "workspaces", "actions", "files", "feed", "history", "apps", "nested"];

fn random_event(rng: &mut Rng, state: &State) -> Event {
    let row_ids = ["r0", "r1", "r2", "r3", "r4"];
    match rng.below(16) {
        0 => Event::Open {
            scope: if rng.below(2) == 0 { None } else { Some((*rng.pick(&SCOPES)).to_owned()) },
            query: String::new(),
        },
        1 => Event::Close,
        2 => {
            let text =
                *rng.pick(&["", "@", "#q", "/x", "ws", "tabs", "feed", "abc", "$", "!", "nested"]);
            Event::SetQuery { text: text.to_owned(), allows_scope_entry: rng.below(4) != 0 }
        }
        3 => Event::BackspaceOnEmpty,
        4 => Event::Tab,
        5 => Event::ShiftTab,
        6 => Event::Escape,
        7 => Event::PopTo { index: rng.below(4) as i64 - 1 },
        8 => Event::Activate {
            row_id: if rng.below(2) == 0 { None } else { Some((*rng.pick(&row_ids)).to_owned()) },
        },
        9 => Event::Push {
            scope: (*rng.pick(&SCOPES)).to_owned(),
            row: Some((*rng.pick(&row_ids)).to_owned()),
            query: String::new(),
        },
        10 => Event::Move { delta: rng.below(5) as i64 - 2 },
        11 => Event::Select { row_id: (*rng.pick(&row_ids)).to_owned() },
        12 => Event::ClearSelection,
        13 => Event::Refresh,
        // Restart keeps the selection until the next batch (a page swapped in place), which I3
        // does not allow for; `restart_keeps_the_selection_until_its_batch` pins it.
        14 => Event::Refresh,
        _ => {
            let level = if state.levels.is_empty() {
                None
            } else {
                Some(&state.levels[rng.below(state.levels.len())])
            };
            let count = rng.below(5);
            let rows = (0..count)
                .map(|_| {
                    let id = (*rng.pick(&row_ids)).to_owned();
                    let mut row = Row::new(id);
                    match rng.below(4) {
                        0 => row.enters = Some((*rng.pick(&SCOPES)).to_owned()),
                        1 => row.drills = Some((*rng.pick(&SCOPES)).to_owned()),
                        2 => row.is_enabled = false,
                        _ => {}
                    }
                    row
                })
                .collect();
            Event::Results {
                level_id: level.map_or(99, |l| l.id),
                generation: level.map_or(1, |l| l.generation - rng.below(2) as i64),
                rows,
                replace: rng.below(2) == 0,
                is_final: rng.below(3) != 0,
                empty_query_selection: if rng.below(3) == 0 {
                    Some(rng.below(3) as i64)
                } else {
                    None
                },
                provisional: rng.below(4) == 0,
            }
        }
    }
}

fn check_invariants(reducer: &Reducer, state: &State, effects: &[Effect], context: &str) {
    // I1
    if state.is_open {
        assert!(!state.levels.is_empty(), "{context}");
        assert_eq!(state.levels[0].scope, ROOT, "{context}");
        assert_eq!(state.levels[0].entry, Entry::Root, "{context}");
        assert!(state.levels[1..].iter().all(|l| l.entry != Entry::Root), "{context}");
    } else {
        assert!(state.levels.is_empty(), "{context}");
    }
    // I2
    assert!(state.levels.len() as i64 <= reducer.config.max_depth, "{context}");
    assert!(state.levels.windows(2).all(|w| w[0].id < w[1].id), "{context}");
    assert!(state.levels.iter().all(|l| l.id < state.next_level_id), "{context}");
    for (index, level) in state.levels.iter().enumerate() {
        // I3
        if let Some(selection) = &level.selection {
            assert!(level.rows.iter().any(|row| &row.id == selection), "{context}: {level:?}");
        }
        // I4
        assert!(level.rows_generation <= level.generation, "{context}");
        // I5
        match &level.entry {
            Entry::Opened => assert_eq!(index, 1, "{context}"),
            Entry::Prefix(_) | Entry::Keyword(_) => {
                assert!(
                    reducer.graph.can_enter(&level.scope, &state.levels[index - 1].scope),
                    "{context}"
                );
            }
            Entry::Row(_) | Entry::Drill(_) => {
                assert!(reducer.graph.contains(&level.scope), "{context}");
            }
            _ => {}
        }
    }
    // I6
    for effect in effects {
        if let Effect::Load { level_id, generation, .. } = effect {
            let level = state.levels.iter().find(|l| l.id == *level_id);
            // A load for a level opened and closed in the same step (an open after close) is the
            // only exception: it names a level that the step itself removed.
            if let Some(level) = level {
                assert_eq!(level.generation, *generation, "{context}");
            }
        }
    }
}

fn visible(state: &State) -> Vec<(String, String, Option<String>)> {
    state.levels.iter().map(|l| (l.scope.clone(), l.query.clone(), l.selection.clone())).collect()
}

#[test]
fn invariants_hold_over_random_sequences() {
    let reducer = reducer();
    for seed in 1..=500u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let mut state = State::default();
        for step in 0..60 {
            let event = random_event(&mut rng, &state);
            let before = state.clone();
            let effects = reducer.reduce(&mut state, event.clone());
            let context = format!("seed {seed} step {step} {event:?}");
            check_invariants(&reducer, &state, &effects, &context);
            // P3
            if let Event::Results { level_id, generation, .. } = &event
                && before.levels.iter().find(|l| l.id == *level_id).map(|l| l.generation)
                    != Some(*generation)
            {
                assert_eq!(state, before, "{context}");
                assert!(effects.is_empty(), "{context}");
            }
            // P6
            if let Event::SetQuery { .. } = &event
                && state.levels.len() == before.levels.len()
                && !before.levels.is_empty()
            {
                let n = before.levels.len();
                assert_eq!(state.levels[..n - 1], before.levels[..n - 1], "{context}");
            }
            if state.is_open {
                // P1: a child's prefix then Backspace gives the same visible state.
                let top = state.top().unwrap();
                if top.query.is_empty()
                    && (state.levels.len() as i64) < reducer.config.max_depth
                    && let Some(child) =
                        reducer.graph.children(&top.scope).into_iter().find(|d| d.prefix.is_some())
                {
                    let mut probe = state.clone();
                    let prefix = child.prefix.clone().unwrap();
                    reducer.reduce(
                        &mut probe,
                        Event::SetQuery { text: prefix, allows_scope_entry: true },
                    );
                    reducer.reduce(&mut probe, Event::BackspaceOnEmpty);
                    assert_eq!(visible(&probe), visible(&state), "P1 {context}");
                }
                // P4
                let mut probe = state.clone();
                for _ in 0..state.levels.len() + 2 {
                    reducer.reduce(&mut probe, Event::Escape);
                }
                assert!(!probe.is_open, "P4 {context}");
                let mut probe = state.clone();
                for _ in 0..10 {
                    reducer.reduce(&mut probe, Event::BackspaceOnEmpty);
                }
                assert!(probe.is_open, "P4 {context}");
            }
        }
        // P5
        let mut fresh = State::default();
        reducer.reduce(&mut state, Event::Close);
        reducer.reduce(&mut state, Event::Open { scope: None, query: String::new() });
        reducer.reduce(&mut fresh, Event::Open { scope: None, query: String::new() });
        let strip = |s: &State| {
            s.levels
                .iter()
                .map(|l| (l.scope.clone(), l.entry.clone(), l.query.clone()))
                .collect::<Vec<_>>()
        };
        assert_eq!(strip(&state), strip(&fresh));
    }
}

#[test]
fn a_drill_round_trip_restores_the_parent_query_and_selection() {
    let reducer = reducer();
    let mut state = open(&reducer);
    reducer.reduce(&mut state, Event::SetQuery { text: "q".into(), allows_scope_entry: true });
    let top = state.top().unwrap();
    let batch = Event::Results {
        level_id: top.id,
        generation: top.generation,
        rows: vec![
            Row::new("a"),
            Row { id: "b".into(), enters: None, drills: Some("actions".into()), is_enabled: true },
        ],
        replace: true,
        is_final: true,
        empty_query_selection: None,
        provisional: false,
    };
    reducer.reduce(&mut state, batch);
    reducer.reduce(&mut state, Event::Select { row_id: "b".into() });
    let before = visible(&state);
    reducer.reduce(&mut state, Event::Tab);
    assert_eq!(state.levels.len(), 2);
    reducer.reduce(&mut state, Event::BackspaceOnEmpty);
    assert_eq!(visible(&state), before);
}

#[test]
fn an_assigned_prefix_wins_and_an_invalid_one_is_ignored() {
    let scopes = vec![
        scope("tabs", Some("@"), &[], Parents::Root),
        scope("files", Some("/"), &[], Parents::Root),
        scope("feed", Some("!"), &[], Parents::Root),
        scope("apps", Some("+"), &[], Parents::Root),
    ];
    let assigned: HashMap<String, Option<String>> = [
        ("files".to_owned(), Some("@".to_owned())),
        ("feed".to_owned(), None),
        ("apps".to_owned(), Some("ab".to_owned())),
    ]
    .into_iter()
    .collect();
    let prefixes: Vec<_> =
        graph::apply_assigned_prefixes(&assigned, scopes).into_iter().map(|d| d.prefix).collect();
    assert_eq!(prefixes, [None, Some("@".to_owned()), None, Some("+".to_owned())]);
}

#[test]
fn restart_keeps_the_selection_until_its_batch() {
    let reducer = reducer();
    let mut state = open(&reducer);
    let batch = results(&state, &["a", "b"], true);
    reducer.reduce(&mut state, batch);
    reducer.reduce(&mut state, Event::Select { row_id: "b".into() });
    let effects = reducer.reduce(&mut state, Event::Restart { query: "x".into() });
    assert!(state.levels[0].rows.is_empty());
    assert_eq!(state.levels[0].selection.as_deref(), Some("b"));
    assert!(matches!(&effects[..], [Effect::Load { query, .. }] if query == "x"));
    let batch = results(&state, &["c"], true);
    reducer.reduce(&mut state, batch);
    assert_eq!(state.levels[0].selection.as_deref(), Some("c"));
}

#[test]
fn the_handle_answers_search_tabs_rows_and_keeps_its_state() {
    let mut nav = Nav::new(Reducer::default());
    nav.call(br#"{"op":"reduce","events":[{"type":"open"}]}"#).unwrap();
    let answer: Value = serde_json::from_slice(
        &nav.call(
            json!({"op": "tabSearchRows", "style": "recent", "strings": {"current": "current"},
                   "entries": [{"id": "a", "kind": "terminal", "title": "A", "isCurrent": true, "lastUsed": 1.0},
                               {"id": "b", "kind": "browser", "title": "B", "host": "github.com", "lastUsed": 0.5},
                               {"id": "x", "kind": "other", "title": "X", "isClosed": true, "lastUsed": 2.0,
                                "closedText": "now"}]})
            .to_string()
            .as_bytes(),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(answer["emptyQuerySelection"], 1);
    assert_eq!(answer["rows"][0]["entry"], 0);
    assert_eq!(answer["rows"][0]["accessory"], "current");
    assert_eq!(answer["rows"][1]["subtitle"], "github.com");
    assert_eq!(answer["rows"][2]["section"]["id"], "tabSearch.closed");
    assert_eq!(answer["rows"][2]["accessory"], "now");
    assert!(nav.state.is_open);
}
