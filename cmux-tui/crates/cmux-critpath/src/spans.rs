//! Any trace as a JSONL span file, so every timeline we own feeds one analysis: landing (PR green
//! to merged), the nightly's phases, cmux-ci jobs, glaeda-gh runs and checks.
//!
//! One span per line: `{"run": "cmux#123", "id": "ci", "name": "macos-tests", "cat": "ci:macos",
//! "state": "wait", "start": 1795570000000, "end": 1795570600000, "follows": ["push"]}`.
//! Times are epoch milliseconds (or `start_s`/`end_s` seconds); `follows` names spans of the same
//! run that had to end first (the follows-from links); `state` is ours, model, tool or wait.
//! A span that follows one the file never defines keeps its own start.

use crate::{Graph, Node, State};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

fn ms(v: &Value, key: &str) -> Option<i64> {
    if let Some(x) = v.get(key).and_then(Value::as_f64) {
        return Some(x as i64);
    }
    v.get(format!("{key}_s")).and_then(Value::as_f64).map(|s| (s * 1000.0) as i64)
}

/// The runs of a span file, in the order each run first appears. Lines that are not spans are
/// counted in the second value, never guessed.
pub fn parse(text: &str) -> (Vec<Graph>, usize) {
    let mut runs: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    let mut order = Vec::new();
    let mut bad = 0;
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            bad += 1;
            continue;
        };
        if ms(&v, "start").is_none() || ms(&v, "end").is_none() {
            bad += 1;
            continue;
        }
        let run = v.get("run").and_then(Value::as_str).unwrap_or("run").to_string();
        if !runs.contains_key(&run) {
            order.push(run.clone());
        }
        runs.entry(run).or_default().push(v);
    }
    let graphs = order
        .into_iter()
        .map(|run| {
            let mut spans = runs.remove(&run).unwrap_or_default();
            spans.sort_by_key(|v| (ms(v, "start").unwrap_or(0), ms(v, "end").unwrap_or(0)));
            build(run, spans)
        })
        .collect();
    (graphs, bad)
}

fn build(label: String, spans: Vec<Value>) -> Graph {
    let mut g = Graph { label, nodes: Vec::new() };
    let mut index: HashMap<String, usize> = HashMap::new();
    // Causal order: a span goes in once everything it follows is in (or never will be).
    let ids: Vec<Option<String>> =
        spans.iter().map(|v| v.get("id").and_then(Value::as_str).map(str::to_string)).collect();
    let known: std::collections::HashSet<&str> = ids.iter().flatten().map(String::as_str).collect();
    let mut placed = vec![false; spans.len()];
    loop {
        let mut progressed = false;
        for ((v, id), placed) in spans.iter().zip(&ids).zip(placed.iter_mut()) {
            if *placed {
                continue;
            }
            let follows: Vec<&str> = v
                .get("follows")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).filter(|f| known.contains(f)).collect())
                .unwrap_or_default();
            if !follows.iter().all(|f| index.contains_key(*f)) {
                continue;
            }
            let name = v.get("name").and_then(Value::as_str).or(id.as_deref()).unwrap_or("span");
            let node = Node {
                name: name.to_string(),
                cat: v.get("cat").and_then(Value::as_str).unwrap_or(name).to_string(),
                state: State::parse(v.get("state").and_then(Value::as_str).unwrap_or("wait")),
                start: ms(v, "start").unwrap_or(0),
                end: ms(v, "end").unwrap_or(0),
                deps: follows.iter().filter_map(|f| index.get(*f).copied()).collect(),
            };
            let at = g.push(node);
            if let Some(id) = id {
                index.insert(id.clone(), at);
            }
            *placed = true;
            progressed = true;
        }
        if !progressed {
            break;
        }
    }
    // A cycle of follows: what is left goes in as roots, so nothing is dropped.
    for (v, placed) in spans.iter().zip(&placed) {
        if !placed {
            let name = v.get("name").and_then(Value::as_str).unwrap_or("span");
            g.push(Node {
                name: name.to_string(),
                cat: v.get("cat").and_then(Value::as_str).unwrap_or(name).to_string(),
                state: State::parse(v.get("state").and_then(Value::as_str).unwrap_or("wait")),
                start: ms(v, "start").unwrap_or(0),
                end: ms(v, "end").unwrap_or(0),
                deps: Vec::new(),
            });
        }
    }
    g
}
