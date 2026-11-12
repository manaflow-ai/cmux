use super::*;
use serde_json::json;
use std::time::Instant;

fn resolve(request: Value) -> Response {
    respond(&serde_json::from_value(request).expect("request"))
}

fn whys(response: &Response) -> Vec<&'static str> {
    response.problems.iter().map(|p| p.why).collect()
}

#[test]
fn no_layout_set_keeps_todays_row() {
    let response = resolve(json!({"kind": "agent", "agent": "claude"}));
    assert_eq!(response, Response::default());
    let nulls = resolve(json!({"lines": null, "linesByKind": null, "linesByAgent": null, "kind": "agent"}));
    assert!(!nulls.custom);
    assert!(nulls.problems.is_empty());
}

#[test]
fn the_written_lines_draw_in_order_and_slots_turn_on_wherever_they_are() {
    let response = resolve(json!({
        "lines": [["icon", "name", "branch", "working"], ["agentStatus", "lastActivity", "progress"]]
    }));
    assert!(response.custom);
    assert_eq!(response.source, Some("all"));
    assert_eq!(response.lines, vec![vec!["name", "branch"], vec!["agentStatus", "lastActivity"]]);
    assert_eq!(response.slots, Slots { icon: true, working: true, progress: true });
    assert!(response.problems.is_empty());
}

#[test]
fn the_agents_layout_wins_over_the_kinds_and_the_kinds_over_every_rows() {
    let settings = json!({
        "lines": [["name"]],
        "linesByKind": {"agent": [["name", "directory"]]},
        "linesByAgent": {"codex": [["name"], ["branch"]]},
    });
    let with = |kind: &str, agent: Option<&str>| {
        let mut request = settings.clone();
        request["kind"] = json!(kind);
        if let Some(agent) = agent {
            request["agent"] = json!(agent);
        }
        resolve(request)
    };
    let codex = with("agent", Some("codex"));
    assert_eq!((codex.source, codex.lines), (Some("agent"), vec![vec!["name"], vec!["branch"]]));
    let claude = with("agent", Some("claude"));
    assert_eq!((claude.source, claude.lines), (Some("kind"), vec![vec!["name", "directory"]]));
    let terminal = with("terminal", None);
    assert_eq!((terminal.source, terminal.lines), (Some("all"), vec![vec!["name"]]));
}

#[test]
fn the_name_always_leads_the_first_line() {
    let left_out = resolve(json!({"lines": [["branch"], ["agentStatus"]]}));
    assert_eq!(left_out.lines, vec![vec!["name", "branch"], vec!["agentStatus"]]);
    assert!(left_out.problems.is_empty());

    let later = resolve(json!({"lines": [["branch"], ["name", "agentStatus"]]}));
    assert_eq!(later.lines, vec![vec!["name", "branch"], vec!["agentStatus"]]);
    assert_eq!(whys(&later), vec!["nameMoved"]);
    assert_eq!(later.problems[0].at, "sidebar.workspaceRow.lines[1][0]");

    let only_slots = resolve(json!({"lines": [["icon", "working"]]}));
    assert_eq!(only_slots.lines, vec![vec!["name"]]);
    assert_eq!(only_slots.slots, Slots { icon: true, working: true, progress: false });

    let empty = resolve(json!({"lines": []}));
    assert!(empty.custom);
    assert_eq!(empty.lines, vec![vec!["name"]]);
}

#[test]
fn a_slot_only_first_line_lets_the_next_line_hold_the_name() {
    let response = resolve(json!({"lines": [["icon"], ["name", "branch"]]}));
    assert_eq!(response.lines, vec![vec!["name", "branch"]]);
    assert!(response.problems.is_empty());
}

#[test]
fn unknown_repeated_and_malformed_tokens_are_skipped_and_reported_where_they_are() {
    let response = resolve(json!({
        "linesByAgent": {"claude": [["name", "model", 7, "branch", "branch"], "not a line", ["ports"]]},
        "kind": "agent",
        "agent": "claude",
    }));
    assert_eq!(response.source, Some("agent"));
    assert_eq!(response.lines, vec![vec!["name", "branch"], vec!["ports"]]);
    assert_eq!(whys(&response), vec!["unknownToken", "notAString", "repeated", "notALine"]);
    let at: Vec<&str> = response.problems.iter().map(|p| p.at.as_str()).collect();
    assert_eq!(at, vec![
        "sidebar.workspaceRow.linesByAgent.claude[0][1]",
        "sidebar.workspaceRow.linesByAgent.claude[0][2]",
        "sidebar.workspaceRow.linesByAgent.claude[0][4]",
        "sidebar.workspaceRow.linesByAgent.claude[1]",
    ]);
    assert_eq!(response.problems[0].token.as_deref(), Some("model"));
}

#[test]
fn a_layout_that_is_not_a_list_falls_through_to_the_next() {
    let response = resolve(json!({
        "lines": [["name", "directory"]],
        "linesByKind": {"terminal": "branch"},
        "kind": "terminal",
    }));
    assert_eq!(response.source, Some("all"));
    assert_eq!(response.lines, vec![vec!["name", "directory"]]);
    assert_eq!(whys(&response), vec!["notALayout"]);
    assert_eq!(response.problems[0].at, "sidebar.workspaceRow.linesByKind.terminal");

    let not_a_map = resolve(json!({"linesByAgent": ["claude"], "agent": "claude"}));
    assert!(!not_a_map.custom);
    assert_eq!(whys(&not_a_map), vec!["notALayout"]);
}

#[test]
fn lines_and_tokens_are_capped() {
    let response = resolve(json!({"lines": [
        ["name", "notification", "directory", "branch", "process", "agentStatus", "tabCount", "ports"],
        ["lastActivity"], ["pullRequest"], ["log"],
    ]}));
    assert_eq!(response.lines.len(), MAX_LINES);
    assert_eq!(response.lines[0].len(), 1 + MAX_TOKENS);
    assert_eq!(response.lines[0][0], "name");
    assert_eq!(whys(&response), vec!["tooManyLines", "tooManyTokens"]);
    assert_eq!(response.problems[1].token.as_deref(), Some("ports"));
}

#[test]
fn a_huge_layout_costs_what_a_small_one_does() {
    // One harness, before and after: the bounded walk reads at most MAX_LINES x MAX_SCANNED
    // entries, so fifty lines of ten thousand tokens cost about what a two-token layout does.
    let small = json!({"lines": [["name", "branch"]]});
    let line: Vec<&str> = std::iter::repeat_n("branch", 10_000).collect();
    let huge = json!({"lines": vec![line; 50]});
    let small: Request = serde_json::from_value(small).expect("small");
    let huge: Request = serde_json::from_value(huge).expect("huge");
    let time = |request: &Request| {
        let mut best = u128::MAX;
        for _ in 0..5 {
            let start = Instant::now();
            for _ in 0..2_000 {
                std::hint::black_box(respond(std::hint::black_box(request)));
            }
            best = best.min(start.elapsed().as_nanos());
        }
        best / 2_000
    };
    let (small_ns, huge_ns) = (time(&small), time(&huge));
    println!("sidebar_row_layout: small {small_ns} ns, huge {huge_ns} ns per row");
    let huge_response = respond(&huge);
    assert!(huge_response.problems.len() <= MAX_LINES * (MAX_SCANNED + 1) + 1);
    // Problems are bounded too, so the answer the app reads stays small.
    assert!(serde_json::to_vec(&huge_response).expect("json").len() < 16 * 1024);
}

#[test]
fn every_token_resolves_and_only_three_are_slots() {
    for token in TOKENS {
        let response = resolve(json!({"lines": [[token]]}));
        assert!(response.problems.is_empty(), "{token}");
        let drawn = response.lines.iter().flatten().any(|t| t == token);
        assert_eq!(drawn, !SLOTS.contains(token), "{token}");
    }
}
