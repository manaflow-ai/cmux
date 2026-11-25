use super::*;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn options(query: &str) -> Options {
    Options { query: query.to_owned(), kinds: KINDS.to_vec(), limit: 10 }
}

#[test]
fn parses_query_kinds_and_limit() {
    let parsed =
        parse_options(&strings(&["deploy", "fix", "--kind", "session,terminal", "--limit=5"]))
            .unwrap();
    assert_eq!(
        parsed,
        Options {
            query: "deploy fix".into(),
            kinds: vec![Kind::Session, Kind::Terminal],
            limit: 5
        }
    );
    let parsed =
        parse_options(&strings(&["x", "--kind", "browser", "--kind", "workspace"])).unwrap();
    assert_eq!(parsed.kinds, vec![Kind::Browser, Kind::Workspace]);
    assert!(parse_options(&strings(&["x", "--kind", "files"])).is_err());
    assert!(parse_options(&strings(&["x", "--limit", "0"])).is_err());
    assert!(parse_options(&strings(&["--kind", "session"])).is_err());
    assert!(parse_options(&strings(&["x", "--bogus"])).is_err());
    assert_eq!(parse_options(&strings(&["--", "--kind"])).unwrap().query, "--kind");
}

#[test]
fn search_page_filter_tokens_narrow_kinds() {
    let parsed = parse_options(&strings(&["in:terminal", "panic"])).unwrap();
    assert_eq!(parsed.query, "panic");
    assert_eq!(parsed.kinds, vec![Kind::Terminal]);
    let parsed = parse_options(&strings(&["-in:browser", "panic"])).unwrap();
    assert_eq!(parsed.kinds, vec![Kind::Session, Kind::Workspace, Kind::Terminal]);
    let parsed =
        parse_options(&strings(&["kind:session", "panic", "--kind", "session,browser"])).unwrap();
    assert_eq!(parsed.kinds, vec![Kind::Session]);
}

#[test]
fn sidebar_tree_gives_workspace_tab_and_terminal_rows() {
    let tree = json!({"workspaces": [
        {"id": 1, "key": "ws_a", "name": "billing", "short_id": "a1", "active": false,
         "screens": [{"panes": [{"id": 3, "layout": {"type": "leaf", "pane": 3},
            "tabs": [
                {"surface": 7, "terminal_id": "term_7", "title": "cargo test", "cwd": "/src/billing"},
                {"surface": 8, "terminal_id": "term_8", "title": "old", "dead": true},
                {"surface": 9, "title": "Docs", "url": "https://example.com/docs"}
            ]}]}]},
        {"id": 2, "key": "ws_b", "name": "search", "active": true,
         "screens": [{"panes": [{"tabs": [{"surface": 11, "terminal_id": "term_11", "title": "zsh"}]}]}]}
    ]});
    let (rows, terminals) = sidebar_rows(&tree);
    let titles = rows.iter().map(|row| row.title.as_str()).collect::<Vec<_>>();
    assert_eq!(titles, ["billing", "cargo test", "old", "Docs", "search", "zsh"]);
    assert!(rows.iter().all(|row| row.kind == Kind::Workspace && !row.found));
    assert_eq!(rows[0].subtitle, "3 tab(s)");
    assert_eq!(rows[3].record["url"], "https://example.com/docs");
    // The active workspace's terminal first; a dead terminal and a browser tab are not searched.
    assert_eq!(terminals.iter().map(|terminal| terminal.surface).collect::<Vec<_>>(), [11, 7]);
    assert_eq!(terminals[1].workspace, "billing");
}

#[test]
fn session_hits_become_rows_once_per_turn() {
    let answer = json!({
        "hits": [
            {"session": "lane-a", "session_id": "s1", "host": "box", "turn_time": "09:00",
             "role": "user", "preview": "fix the deploy"},
            {"session": "lane-a", "session_id": "s1", "host": "box", "turn_time": "09:00",
             "role": "assistant", "preview": "deploy fixed"},
            {"session": "", "session_id": "s2", "host": "", "turn_time": "10:00",
             "role": "user", "preview": "deploy again"}
        ],
        "incomplete": ["peer x: offline"]
    });
    let (rows, incomplete) = sessions::rows(&answer);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].title, "lane-a");
    assert_eq!(rows[0].subtitle, "box · 09:00 · fix the deploy");
    assert_eq!(rows[1].title, "s2");
    assert!(rows.iter().all(|row| row.found));
    assert_eq!(incomplete, ["peer x: offline"]);
}

fn row(kind: Kind, title: &str, found: bool) -> Row {
    Row {
        kind,
        title: title.to_owned(),
        subtitle: String::new(),
        keywords: Vec::new(),
        handles: Vec::new(),
        found,
        record: Value::Null,
    }
}

#[test]
fn ranks_with_the_palette_engine_grouped_by_kind() {
    let rows = vec![
        row(Kind::Browser, "Deploy docs", true),
        row(Kind::Workspace, "unrelated", false),
        row(Kind::Workspace, "deploy", false),
        row(Kind::Session, "lane-deploy", true),
        // A content hit the ranker cannot match (the words were in its context) stays, last.
        row(Kind::Terminal, "connection refused", true),
        row(Kind::Terminal, "deploy: ok", true),
    ];
    let ranked = rank(&options("deploy"), rows);
    let shown = ranked.iter().map(|(row, _)| (row.kind, row.title.as_str())).collect::<Vec<_>>();
    assert_eq!(
        shown,
        [
            (Kind::Session, "lane-deploy"),
            (Kind::Workspace, "deploy"),
            (Kind::Terminal, "deploy: ok"),
            (Kind::Terminal, "connection refused"),
            (Kind::Browser, "Deploy docs"),
        ]
    );
    assert!(ranked[1].1.is_some());
    assert!(ranked[3].1.is_none());
}

#[test]
fn limit_applies_per_kind() {
    let rows = (0..5)
        .map(|index| row(Kind::Session, &format!("deploy {index}"), true))
        .chain((0..5).map(|index| row(Kind::Browser, &format!("deploy page {index}"), true)));
    let mut options = options("deploy");
    options.limit = 2;
    let ranked = rank(&options, rows.collect());
    assert_eq!(ranked.iter().filter(|(row, _)| row.kind == Kind::Session).count(), 2);
    assert_eq!(ranked.iter().filter(|(row, _)| row.kind == Kind::Browser).count(), 2);
}

#[test]
fn browser_rows_read_history_entries() {
    let rows = browser_rows(&json!({"entries": [
        {"id": "page:1", "kind": "page", "title": "", "url": "https://example.com/a"},
        {"id": "page:2", "kind": "page", "title": "Example", "url": "https://example.com/b"}
    ]}));
    assert_eq!(rows[0].title, "https://example.com/a");
    assert_eq!(rows[1].title, "Example");
    assert_eq!(rows[1].subtitle, "https://example.com/b");
}

#[test]
fn only_the_search_verb_is_claimed() {
    assert_eq!(run_if_requested(&strings(&["agent", "search", "x"])), None);
    assert_eq!(run_if_requested(&strings(&["docs", "search", "x"])), None);
    assert_eq!(run_if_requested(&strings(&["search", "--help"])), Some(0));
}
