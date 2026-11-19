//! Stress for the row-layout reducer (`sidebar.workspaceRow.lines`, `linesByKind`,
//! `linesByAgent`) the way a heavy user and a hot-reloading customize file hit it: hundreds to
//! twenty thousand workspace rows, every agent and kind, a thousand rapid edits, and the
//! degenerate values a hand-edited file holds (empty, huge, malformed, unicode, conflicting
//! layers). Leo, 2026-11-17: "we should be stress testing everything that isn't already stress
//! tested"; "No soaks: break it fast, repeatedly, under load".
//!
//! Run the table with
//! `cargo test -p cmux-layout-reducer --release sidebar_row_layout_stress -- --nocapture`.

use super::*;
use serde_json::json;
use std::collections::HashMap;
use std::time::Instant;

const KINDS: &[&str] = &["terminal", "agent", "browser", "mixed"];
const AGENTS: &[&str] = &["claude", "codex", "opencode", "pi", "gemini", "amp", "cursor", "droid"];

/// A small deterministic generator, so a failure names its seed.
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
}

/// Strings a person, an agent or a broken generator writes as a token.
fn junk(rng: &mut Rng) -> Value {
    match rng.below(14) {
        0..=5 => json!(TOKENS[rng.below(TOKENS.len())]),
        6 => json!("Name"),
        7 => json!("name\u{200b}"),
        8 => json!("名前🌿"),
        9 => json!("\u{202e}branch"),
        10 => json!(""),
        11 => json!(7),
        12 => json!({"token": "name"}),
        _ => json!([["name"]]),
    }
}

fn random_layout(rng: &mut Rng) -> Value {
    match rng.below(10) {
        0 => Value::Null,
        1 => json!("name"),
        2 => json!({}),
        _ => {
            let lines = rng.below(6);
            Value::Array(
                (0..lines)
                    .map(|_| match rng.below(8) {
                        0 => json!("not a line"),
                        _ => Value::Array((0..rng.below(20)).map(|_| junk(rng)).collect()),
                    })
                    .collect(),
            )
        }
    }
}

fn random_map(rng: &mut Rng, keys: &[&str]) -> Value {
    match rng.below(6) {
        0 => Value::Null,
        1 => json!([["name"]]),
        _ => {
            let mut map = Map::new();
            for key in keys {
                if rng.below(2) == 0 {
                    map.insert((*key).to_owned(), random_layout(rng));
                }
            }
            Value::Object(map)
        }
    }
}

/// What every answer promises the row that draws it, whatever was written.
fn assert_draws(response: &Response, context: &str) {
    if !response.custom {
        assert!(response.lines.is_empty() && response.source.is_none(), "{context}");
        return;
    }
    assert!(!response.lines.is_empty() && response.lines.len() <= MAX_LINES, "{context}");
    // The name is on the first line; where on it follows the written order.
    assert!(response.lines[0].contains(&"name"), "{context}: {:?}", response.lines);
    let mut seen = Vec::new();
    for line in &response.lines {
        assert!(!line.is_empty(), "{context}");
        assert!(line.iter().filter(|t| **t != "name").count() <= MAX_TOKENS, "{context}");
        for token in line {
            assert!(!SLOTS.contains(token), "{context}: slot {token} drawn as text");
            assert!(!seen.contains(token), "{context}: {token} twice");
            seen.push(*token);
        }
    }
    assert!(response.problems.len() <= MAX_LINES * (MAX_SCANNED + 1) + 3, "{context}");
}

#[test]
fn ten_thousand_random_settings_files_each_draw_a_row() {
    let mut rng = Rng(0x5eed_cafe);
    for case in 0..10_000 {
        let request = Request {
            lines: Some(random_layout(&mut rng)),
            lines_by_kind: Some(random_map(&mut rng, KINDS)),
            lines_by_agent: Some(random_map(&mut rng, AGENTS)),
            kind: Some(KINDS[rng.below(KINDS.len())].to_owned()),
            agent: (rng.below(3) > 0).then(|| AGENTS[rng.below(AGENTS.len())].to_owned()),
        };
        let response = respond(&request);
        assert_draws(&response, &format!("case {case}: {request:?}"));
        // Same settings, same answer: a hot reload that rewrites the file unchanged never
        // reshuffles a row.
        assert_eq!(response, respond(&request), "case {case}");
    }
}

#[test]
fn unicode_and_lookalike_tokens_are_reported_never_drawn() {
    let response = respond(
        &serde_json::from_value(json!({
            "lines": [["Name", "name\u{200b}", "名前🌿", "\u{202e}branch", "", "BRANCH", "branch"]]
        }))
        .expect("request"),
    );
    assert_eq!(response.lines, vec![vec!["name", "branch"]]);
    let unknown = response.problems.iter().filter(|p| p.why == "unknownToken").count();
    assert_eq!(unknown, 6, "{:?}", response.problems);
}

#[test]
fn conflicting_layers_fall_through_in_order() {
    // The agent's layout is malformed, the kind map is not a map, `lines` is fine: `lines` wins,
    // and both broken layers are reported where they are.
    let response = respond(
        &serde_json::from_value(json!({
            "lines": [["name", "branch"]],
            "linesByKind": [["name"]],
            "linesByAgent": {"claude": "branch"},
            "kind": "agent",
            "agent": "claude",
        }))
        .expect("request"),
    );
    assert_eq!(response.source, Some("all"));
    assert_eq!(response.lines, vec![vec!["name", "branch"]]);
    let mut at: Vec<&str> = response.problems.iter().map(|p| p.at.as_str()).collect();
    at.sort_unstable();
    assert_eq!(at, [format!("{KEY_BY_AGENT}.claude"), KEY_BY_KIND.to_owned()]);
}

/// A hand-edited file can hold one enormous string (a pasted log, a runaway generator). The
/// answer quotes the token so Settings can say what was ignored, but never the whole of it:
/// the app reads every answer into a fixed buffer, once per (kind, agent) pair per reload.
#[test]
fn a_huge_unknown_token_is_quoted_short() {
    let huge = "x".repeat(1 << 20);
    let response =
        respond(&serde_json::from_value(json!({"lines": [[huge, "branch"]]})).expect("request"));
    assert_eq!(response.lines, vec![vec!["name", "branch"]]);
    let quoted = response.problems[0].token.as_deref().expect("token");
    assert!(quoted.chars().count() <= MAX_QUOTED + 1, "quoted {} chars", quoted.len());
    assert!(quoted.starts_with("xxxx") && quoted.ends_with('…'));

    // Every scanned entry a huge string: the answer stays as small as the bounded walk.
    let line: Vec<String> =
        (0..MAX_SCANNED).map(|i| format!("{i}{}", "y".repeat(1 << 16))).collect();
    let worst =
        respond(&serde_json::from_value(json!({"lines": vec![line; MAX_LINES]})).expect("request"));
    let bytes = serde_json::to_vec(&worst).expect("json").len();
    assert!(bytes < 16 * 1024, "answer is {bytes} bytes");

    // A short token is quoted whole, multi-byte text cut on a character boundary.
    let short = respond(&serde_json::from_value(json!({"lines": [["名前🌿"]]})).expect("request"));
    assert_eq!(short.problems[0].token.as_deref(), Some("名前🌿"));
    let long_unicode = "名".repeat(MAX_QUOTED * 3);
    let cut =
        respond(&serde_json::from_value(json!({"lines": [[long_unicode]]})).expect("request"));
    let quoted = cut.problems[0].token.as_deref().expect("token");
    assert_eq!(quoted.chars().count(), MAX_QUOTED + 1);
}

fn nanos(runs: usize, mut f: impl FnMut()) -> u128 {
    let mut best = u128::MAX;
    for _ in 0..5 {
        let start = Instant::now();
        for _ in 0..runs {
            f();
        }
        best = best.min(start.elapsed().as_nanos() / runs as u128);
    }
    best
}

/// `workspaces` rows over every kind and agent, as `(kind, agent)` pairs.
fn rows(workspaces: usize) -> Vec<(String, Option<String>)> {
    (0..workspaces)
        .map(|w| {
            let kind = KINDS[w % KINDS.len()];
            let agent = (kind == "agent" || kind == "mixed").then(|| AGENTS[w % AGENTS.len()]);
            (kind.to_owned(), agent.map(str::to_owned))
        })
        .collect()
}

/// A full customize file: a layout for every row, one per kind, one per agent.
fn settings(edit: usize) -> (Value, Value, Value) {
    let pick = |i: usize| TOKENS[(edit + i) % TOKENS.len()];
    let lines = json!([["icon", "name", pick(1)], [pick(2), pick(3)], ["progress"]]);
    let by_kind: Map<String, Value> = KINDS
        .iter()
        .enumerate()
        .map(|(k, kind)| ((*kind).into(), json!([["name", pick(k + 4)]])))
        .collect();
    let by_agent: Map<String, Value> = AGENTS
        .iter()
        .enumerate()
        .map(|(a, agent)| ((*agent).into(), json!([["name", pick(a)], [pick(a + 5), "working"]])))
        .collect();
    (lines, Value::Object(by_kind), Value::Object(by_agent))
}

/// One hot reload: resolve the rows the sidebar draws, once per (kind, agent) pair as the app
/// does. Returns the pairs resolved.
fn reload(rows: &[(String, Option<String>)], edit: usize) -> usize {
    let (lines, by_kind, by_agent) = settings(edit);
    let mut cache: HashMap<(&str, Option<&str>), Response> = HashMap::new();
    for (kind, agent) in rows {
        cache.entry((kind, agent.as_deref())).or_insert_with(|| {
            respond(&Request {
                lines: Some(lines.clone()),
                lines_by_kind: Some(by_kind.clone()),
                lines_by_agent: Some(by_agent.clone()),
                kind: Some(kind.clone()),
                agent: agent.clone(),
            })
        });
    }
    cache.len()
}

#[test]
fn sidebar_row_layout_stress() {
    // Per-row cost: a typical layout against the worst a file can hold (every scanned entry an
    // unknown 64 KiB string). Before the quoted-token cap the worst row copied 3 MiB per resolve.
    let typical: Request = serde_json::from_value(json!({
        "lines": [["icon", "name", "branch"], ["agentStatus", "lastActivity"]], "kind": "agent"
    }))
    .expect("typical");
    let line: Vec<String> =
        (0..MAX_SCANNED).map(|i| format!("{i}{}", "z".repeat(1 << 16))).collect();
    let worst: Request =
        serde_json::from_value(json!({"lines": vec![line; MAX_LINES], "kind": "agent"}))
            .expect("worst");
    let typical_ns = nanos(2_000, || {
        std::hint::black_box(respond(std::hint::black_box(&typical)));
    });
    let worst_ns = nanos(50, || {
        std::hint::black_box(respond(std::hint::black_box(&worst)));
    });
    println!("row | typical {typical_ns} ns | worst file {worst_ns} ns");
    // Relative, so a debug build or a loaded runner moves both sides: 70x after the cap, 566x
    // before it (the 3 MiB copy).
    let bound = typical_ns.max(50) * 200;
    assert!(
        worst_ns < bound,
        "the worst file costs {worst_ns} ns per resolve vs {typical_ns} typical"
    );

    // Hot reload and rapid edits at every sidebar size: the resolves per reload stay at the
    // number of (kind, agent) pairs, so a reload costs the same at 100 rows and 20,000.
    println!("workspaces | resolves per reload | reload p50 us | 1000 edits ms");
    let mut per_reload = Vec::new();
    for workspaces in [100, 1_000, 5_000, 20_000] {
        let rows = rows(workspaces);
        let pairs = reload(&rows, 0);
        assert!(pairs <= KINDS.len() * (AGENTS.len() + 1), "{pairs} resolves at {workspaces}");
        let mut samples: Vec<u128> = (0..40)
            .map(|edit| {
                let start = Instant::now();
                std::hint::black_box(reload(&rows, edit));
                start.elapsed().as_nanos()
            })
            .collect();
        samples.sort_unstable();
        let start = Instant::now();
        for edit in 0..1_000 {
            reload(&rows, edit);
        }
        let edits_ms = start.elapsed().as_millis();
        println!("{workspaces} | {pairs} | {} | {edits_ms}", samples[20] / 1_000);
        per_reload.push(samples[20]);
    }
    // The walk over rows to find their pairs is linear and tiny; the reducer work is per pair.
    // Allow the row walk, never a per-row resolve (that would be 200x at 20,000).
    assert!(
        per_reload[3] < per_reload[0] * 40 + 2_000_000,
        "reload at 20,000 rows {} ns vs {} ns at 100",
        per_reload[3],
        per_reload[0]
    );
}
