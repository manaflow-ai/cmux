//! Ranking signals: context (workspace, group, title, folder, branch,
//! agent), focus history, the current workspace and match position.

use cmux_search::{Doc, EngineConfig, Kind, NameDoc, Query, SearchEngine, TargetContext};

const NOW: i64 = 1_800_000_000_000;
const MINUTE: i64 = 60_000;
const DAY: i64 = 86_400_000;

fn doc(kind: Kind, target: &str, text: &str, at_ms: i64) -> Doc {
    Doc {
        kind,
        source: target.to_owned(),
        target: target.to_owned(),
        position: Some(0),
        title: "zsh".to_owned(),
        text: text.to_owned(),
        at_ms,
        key: None,
    }
}

fn name(kind: Kind, target: &str, title: &str) -> NameDoc {
    NameDoc {
        key: target.to_owned(),
        kind,
        target: target.to_owned(),
        title: title.to_owned(),
        subtitle: String::new(),
        at_ms: NOW - DAY,
    }
}

fn context(
    workspace_id: &str,
    workspace: &str,
    group: &str,
    cwd: &str,
    branch: &str,
) -> TargetContext {
    TargetContext {
        workspace_id: workspace_id.to_owned(),
        workspace: workspace.to_owned(),
        group: group.to_owned(),
        title: "zsh".to_owned(),
        cwd: cwd.to_owned(),
        branch: branch.to_owned(),
        agent: String::new(),
    }
}

fn targets(engine: &SearchEngine, query: Query) -> Vec<String> {
    engine.search(&query).hits.into_iter().map(|hit| hit.target).collect()
}

#[test]
fn cmux_search_rank_a_word_can_match_the_workspace_instead_of_the_text() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    engine.set_context(
        "term:a",
        context("ws_a", "cmux-next app", "Performance", "~/fun/cmux", "feat-cmux-next"),
    );
    engine.set_context("term:b", context("ws_b", "website", "Web", "~/fun/web", "main"));
    engine.append(doc(Kind::Scrollback, "term:a", "error: migration 0042 failed", NOW - MINUTE));
    engine.append(doc(Kind::Scrollback, "term:b", "error: migration 0042 failed", NOW - MINUTE));
    assert_eq!(targets(&engine, Query::new("cmux-next migration", NOW)), vec!["term:a"]);
    assert_eq!(targets(&engine, Query::new("website migration", NOW)), vec!["term:b"]);
    // Group, folder and branch count too.
    assert_eq!(targets(&engine, Query::new("performance migration", NOW)), vec!["term:a"]);
    assert_eq!(targets(&engine, Query::new("feat-cmux-next 0042", NOW)), vec!["term:a"]);
    // A word nothing holds still finds nothing.
    assert!(targets(&engine, Query::new("zebra migration", NOW)).is_empty());
}

#[test]
fn cmux_search_rank_context_words_lift_a_hit_among_equal_matches() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    engine.set_context("term:a", context("ws_a", "billing", "", "", ""));
    engine.set_context("term:b", context("ws_b", "invoices", "", "", ""));
    engine.append(doc(Kind::Scrollback, "term:a", "invoices export finished", NOW - 2 * MINUTE));
    engine.append(doc(Kind::Scrollback, "term:b", "invoices export finished", NOW - 3 * MINUTE));
    // Both texts hold "invoices"; term:b's workspace is named that too.
    assert_eq!(targets(&engine, Query::new("invoices export", NOW))[0], "term:b");
}

#[test]
fn cmux_search_rank_tabs_match_by_title_plus_workspace() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    engine.upsert_name(name(Kind::Tab, "tab_1", "server"));
    engine.upsert_name(name(Kind::Tab, "tab_2", "server"));
    engine.set_context("tab_1", context("ws_a", "cmux-next app", "", "", ""));
    engine.set_context("tab_2", context("ws_b", "website", "", "", ""));
    assert_eq!(targets(&engine, Query::new("website server", NOW)), vec!["tab_2"]);
    // A name needs one word in its own title: the workspace alone is not a tab hit.
    assert!(targets(&engine, Query::new("website", NOW)).iter().all(|target| target != "tab_2"));
}

#[test]
fn cmux_search_rank_focus_history_and_current_workspace_break_ties() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    for target in ["tab_1", "tab_2", "tab_3"] {
        engine.upsert_name(name(Kind::Tab, target, "logs"));
    }
    engine.set_context("tab_3", context("ws_here", "here", "", "", ""));
    engine.record_focus("tab_2", NOW - 5 * MINUTE);
    assert_eq!(targets(&engine, Query::new("logs", NOW))[0], "tab_2");
    let mut query = Query::new("logs", NOW);
    query.workspace_id = Some("ws_here".to_owned());
    assert_eq!(targets(&engine, query)[0], "tab_3");
    // Focus fades within hours; opens (frecency) last days.
    engine.record_open("tab_1", NOW - DAY);
    assert_eq!(targets(&engine, Query::new("logs", NOW + 6 * 3_600_000))[0], "tab_1");
}

#[test]
fn cmux_search_rank_an_earlier_match_in_a_name_ranks_higher() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    engine.upsert_name(name(Kind::Workspace, "ws_late", "old notes and the deploy runbook"));
    engine.upsert_name(name(Kind::Workspace, "ws_early", "the deploy runbook and old notes"));
    assert_eq!(targets(&engine, Query::new("deploy", NOW))[0], "ws_early");
}

#[test]
fn cmux_search_rank_no_signal_crosses_a_tier() {
    let mut engine = SearchEngine::new(EngineConfig::default());
    engine.set_context("term:weak", context("ws_here", "deploy", "deploy", "deploy", "deploy"));
    engine.append(doc(Kind::Chief, "term:weak", "the redeployment went fine", NOW));
    engine.append(doc(Kind::Screen, "term:strong", "deploy", NOW - 6 * DAY));
    for _ in 0..20 {
        engine.record_open("term:weak", NOW);
        engine.record_focus("term:weak", NOW);
    }
    let mut query = Query::new("deploy", NOW);
    query.workspace_id = Some("ws_here".to_owned());
    let hits = engine.search(&query).hits;
    assert_eq!(hits[0].target, "term:strong");
    assert_eq!(hits[0].tier, 5);
}
