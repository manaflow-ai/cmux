use super::query::{Dim, LedgerQuery};
use super::*;
use serde_json::json;
use std::fs::OpenOptions;
use std::io::Write;

const DAY: u64 = DAY_MS;
/// 2026-11-08T00:00:00Z.
const D0: u64 = 20_765 * DAY;

fn rec(dir: &str, kind: &str, at: u64, msg: Value) -> EventRecord {
    EventRecord { seq: 0, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

fn ctx(harness: &str, family: &str) -> TurnContext {
    TurnContext {
        model: None,
        info: SessionInfo {
            title: Some(format!("{harness} chat")),
            harness: harness.into(),
            family: Some(family.into()),
            workspace_id: Some("ws-1".into()),
            branch: Some("main".into()),
            account: Some("work".into()),
            created_at: D0,
            ..Default::default()
        },
    }
}

/// One turn of `id`: a prompt at `at`, the agent starting a second later, `tools` tool calls,
/// and a result ten seconds after the start carrying `result`.
fn turn(l: &Ledger, id: &str, at: u64, tools: u64, result: Value, harness: &str, family: &str) {
    l.record(id, &rec("out", "user_message", at, json!({"text": "go"})), || ctx(harness, family));
    l.record(id, &rec("mux", "turn_started", at + 1_000, json!({})), || ctx(harness, family));
    for _ in 0..tools {
        l.record(id, &rec("in", "tool_call", at + 2_000, json!({})), || ctx(harness, family));
    }
    l.record(id, &rec("mux", "turn_result", at + 11_000, result), || ctx(harness, family));
}

fn mem() -> Ledger {
    Ledger::open_with(None, COMPACT_BYTES, "leo@test".into())
}

fn all(since: u64, until: u64) -> LedgerQuery {
    LedgerQuery { since, until, limit: 200, dims: Dim::ALL.to_vec() }
}

fn rollup<'a>(reply: &'a LedgerReply, dim: &str) -> &'a Vec<Value> {
    match reply.rollups.get(dim) {
        Some(Value::Array(v)) => v,
        other => panic!("rollup {dim}: {other:?}"),
    }
}

#[test]
fn a_turn_is_priced_by_its_harness_else_the_table_else_counts_unpriced() {
    let l = mem();
    // The harness's own cost wins over the table.
    turn(
        &l,
        "a",
        D0 + 1_000,
        3,
        json!({"status": "completed", "model": "claude-opus-5-5", "costUsd": 0.5, "inputTokens": 1_000_000}),
        "claude",
        "claude",
    );
    // No harness cost: tokens at the table's price (1M input at $1.25 + 1M output at $10).
    turn(
        &l,
        "b",
        D0 + 2_000,
        0,
        json!({"model": "gpt-5", "inputTokens": 1_000_000, "outputTokens": 1_000_000}),
        "codex",
        "codex",
    );
    // A model the table does not list.
    turn(&l, "c", D0 + 3_000, 1, json!({"model": "mystery-1", "inputTokens": 10}), "omp", "omp");
    let reply = l.query(&all(D0, D0 + DAY - 1));
    let t = &reply.totals;
    assert_eq!(t.turns, 3);
    assert_eq!(t.sessions, 3);
    assert_eq!(t.tool_calls, 4);
    assert_eq!(t.unpriced_turns, 1);
    assert!((t.harness_cost_usd - 0.5).abs() < 1e-9);
    assert!((t.table_cost_usd - 11.25).abs() < 1e-9, "{}", t.table_cost_usd);
    assert!((t.cost_usd - 11.75).abs() < 1e-9);
    // Wall time runs from the agent's start to the result: 10 s a turn.
    assert_eq!(t.wall_ms, 30_000);
    let a = reply.rows.iter().find(|r| r.session_id == "a").unwrap();
    assert_eq!(a.vendor, "anthropic");
    assert_eq!(a.models, vec!["claude-opus-5-5".to_string()]);
    assert_eq!(a.totals.tool_calls, 3);
    let vendors = rollup(&reply, "vendor");
    let keys: Vec<&str> = vendors.iter().map(|v| v["key"].as_str().unwrap()).collect();
    assert_eq!(keys, vec!["openai", "anthropic", "omp"]);
    assert_eq!(reply.price_table.version, crate::pricing::table().version);
}

#[test]
fn pull_requests_roll_up_with_the_repository_they_name() {
    let l = mem();
    let pr = "https://github.com/acme/widgets/pull/7";
    turn(&l, "a", D0, 0, json!({"model": "claude-opus-5-5", "costUsd": 1.0}), "claude", "claude");
    l.note_pull_request("a", pr);
    turn(
        &l,
        "a",
        D0 + 60_000,
        0,
        json!({"model": "claude-opus-5-5", "costUsd": 2.0}),
        "claude",
        "claude",
    );
    turn(&l, "b", D0, 0, json!({"model": "claude-opus-5-5", "costUsd": 4.0}), "claude", "claude");
    let reply = l.query(&all(D0, D0 + DAY - 1));
    let prs = rollup(&reply, "pr");
    assert_eq!(prs.len(), 1);
    assert_eq!(prs[0]["key"], pr);
    assert_eq!(prs[0]["label"], "acme/widgets#7");
    // The session's spend that day, before and after it opened the pull request.
    assert_eq!(prs[0]["costUsd"], 3.0);
    assert_eq!(prs[0]["sessions"], 1);
    let repos = rollup(&reply, "repo");
    let acme = repos.iter().find(|r| r["key"] == "acme/widgets").unwrap();
    assert_eq!(acme["costUsd"], 3.0);
    let none = repos.iter().find(|r| r["key"] == "none").unwrap();
    assert_eq!(none["costUsd"], 4.0);
    let a = reply.rows.iter().find(|r| r.session_id == "a").unwrap();
    assert_eq!(a.repo.as_deref(), Some("acme/widgets"));
    assert_eq!(a.pull_requests, vec![pr.to_string()]);
}

#[test]
fn days_are_utc_and_a_range_takes_whole_days() {
    let l = mem();
    let cost = |c: f64| json!({"model": "claude-opus-5-5", "costUsd": c});
    // Prompted at 23:59:55 on day 0, its result written at 00:00:06 on day 1.
    turn(&l, "a", D0 + DAY - 5_000, 0, cost(1.0), "claude", "claude");
    turn(&l, "a", D0 + DAY + 5_000, 0, cost(2.0), "claude", "claude");
    // The day before day 0.
    turn(&l, "a", D0 - 60_000, 0, cost(4.0), "claude", "claude");
    // A turn is on the day its result was written.
    let day1 = l.query(&all(D0 + DAY, D0 + 2 * DAY - 1));
    assert_eq!(day1.totals.cost_usd, 3.0);
    let day0 = l.query(&all(D0, D0 + DAY - 1));
    assert_eq!(day0.totals.cost_usd, 0.0);
    // Any instant of a day takes the whole day.
    let noon = l.query(&all(D0 + DAY + DAY / 2, D0 + DAY + DAY / 2));
    assert_eq!(noon.totals.cost_usd, 3.0);
    let both = l.query(&all(D0 - DAY, D0 + 2 * DAY));
    let days = rollup(&both, "day");
    let keys: Vec<&str> = days.iter().map(|d| d["key"].as_str().unwrap()).collect();
    assert_eq!(keys, vec!["2026-11-07", "2026-11-09"]);
}

#[test]
fn a_fork_copy_counts_nothing() {
    let l = mem();
    l.suppress("fork");
    turn(
        &l,
        "fork",
        D0,
        2,
        json!({"model": "claude-opus-5-5", "costUsd": 9.0}),
        "claude",
        "claude",
    );
    l.unsuppress("fork");
    turn(
        &l,
        "fork",
        D0 + 1_000,
        0,
        json!({"model": "claude-opus-5-5", "costUsd": 1.0}),
        "claude",
        "claude",
    );
    let reply = l.query(&all(D0, D0 + DAY));
    assert_eq!(reply.totals.cost_usd, 1.0);
    assert_eq!(reply.totals.tool_calls, 0);
}

#[test]
fn group_by_names_the_rollups_and_rejects_unknown_ones() {
    let q =
        LedgerQuery::from_params(&json!({"groupBy": ["repo", "day", "repo"], "limit": 3}), 1_000)
            .unwrap();
    assert_eq!(q.dims, vec![Dim::Repo, Dim::Day]);
    assert_eq!(q.limit, 3);
    assert_eq!(q.until, 1_000);
    assert!(LedgerQuery::from_params(&json!({"groupBy": ["colour"]}), 0).is_err());
    assert!(LedgerQuery::from_params(&json!({"since": 5, "until": 4}), 0).is_err());
    let l = mem();
    turn(&l, "a", D0, 0, json!({"costUsd": 1.0}), "claude", "claude");
    let reply = l.query(&LedgerQuery { dims: vec![Dim::Repo], ..all(D0, D0) });
    assert_eq!(reply.rollups.keys().collect::<Vec<_>>(), vec!["repo"]);
    // The reply's names are the contract's.
    let v = serde_json::to_value(&reply).unwrap();
    for key in ["priceTable", "range", "totals", "rows", "rollups"] {
        assert!(v.get(key).is_some(), "{key}");
    }
    let row = &v["rows"][0];
    for key in [
        "sessionId",
        "title",
        "harness",
        "vendor",
        "models",
        "workspaceId",
        "pullRequests",
        "person",
        "account",
        "createdAt",
        "lastAt",
        "costUsd",
        "harnessCostUsd",
        "tableCostUsd",
        "unpricedTurns",
        "inputTokens",
        "outputTokens",
        "cacheReadTokens",
        "cacheWriteTokens",
        "cacheSavedUsd",
        "turns",
        "toolCalls",
        "wallMs",
        "sessions",
    ] {
        assert!(row.get(key).is_some(), "row {key}: {row}");
    }
    assert_eq!(row["person"], "leo@test");
}

#[test]
fn cache_reads_count_what_they_saved_against_the_input_price() {
    let l = mem();
    // Opus 5.5: input $4, cache read $0.20 per million. 1M cache-read tokens saved $3.80, even
    // when the agent reported the turn's cost itself.
    turn(
        &l,
        "a",
        D0 + 1_000,
        0,
        json!({"model": "claude-opus-5-5", "costUsd": 1.0, "inputTokens": 10, "cacheReadTokens": 1_000_000}),
        "claude",
        "claude",
    );
    // Priced from the table: the same saving beside the table's cost.
    turn(
        &l,
        "b",
        D0 + 2_000,
        0,
        json!({"model": "claude-opus-5-5", "inputTokens": 10, "cacheReadTokens": 500_000}),
        "claude",
        "claude",
    );
    // No cache reads, and a model the table lacks: nothing saved, never a guess.
    turn(
        &l,
        "c",
        D0 + 3_000,
        0,
        json!({"model": "claude-opus-5-5", "inputTokens": 10}),
        "claude",
        "claude",
    );
    turn(&l, "d", D0 + 4_000, 0, json!({"model": "mystery-1", "cacheReadTokens": 9}), "omp", "omp");
    let reply = l.query(&all(D0, D0 + DAY - 1));
    assert!((reply.totals.cache_saved_usd - 5.7).abs() < 1e-9, "{}", reply.totals.cache_saved_usd);
    let row =
        |id: &str| reply.rows.iter().find(|r| r.session_id == id).unwrap().totals.cache_saved_usd;
    assert!((row("a") - 3.8).abs() < 1e-9);
    assert!((row("b") - 1.9).abs() < 1e-9);
    assert_eq!(row("c"), 0.0);
    assert_eq!(row("d"), 0.0);
    // A rollup adds them up as it adds cost.
    let models = rollup(&reply, "model");
    let opus = models.iter().find(|m| m["key"] == "claude-opus-5-5").unwrap();
    assert!((opus["cacheSavedUsd"].as_f64().unwrap() - 5.7).abs() < 1e-9);
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-ledger-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn the_file_folds_back_to_the_same_ledger() {
    let dir = scratch("roundtrip");
    let pr = "https://github.com/acme/widgets/pull/9";
    let before = {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        turn(
            &l,
            "a",
            D0,
            2,
            json!({"model": "claude-opus-5-5", "costUsd": 1.5}),
            "claude",
            "claude",
        );
        turn(
            &l,
            "b",
            D0 + DAY,
            0,
            json!({"model": "gpt-5", "inputTokens": 1000}),
            "codex",
            "codex",
        );
        l.note_pull_request("a", pr);
        l.flush();
        l.query(&all(0, D0 + 3 * DAY))
    };
    let after = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(after.lock().existed);
    assert_eq!(after.query(&all(0, D0 + 3 * DAY)), before);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_large_file_is_compacted_to_its_buckets() {
    let dir = scratch("compact");
    let path = dir.join(store::FILE);
    let before = {
        // A tiny bound: every flush past it rewrites the file.
        let l = Ledger::open_with(Some(dir.clone()), 2_000, "leo@test".into());
        for i in 0..200 {
            let at = D0 + (i % 4) * DAY + i;
            turn(
                &l,
                "a",
                at,
                1,
                json!({"model": "claude-opus-5-5", "costUsd": 0.25}),
                "claude",
                "claude",
            );
        }
        l.flush();
        l.query(&all(0, D0 + 5 * DAY))
    };
    let text = std::fs::read_to_string(&path).unwrap();
    // One session line and one line per (day, session, model) bucket: four days.
    let spend = text.lines().filter(|l| l.contains("\"t\":\"u\"")).count();
    assert!(spend <= 4 + 200 / 2, "{spend} spend lines");
    let after = Ledger::open_with(Some(dir.clone()), 2_000, "leo@test".into());
    let folded = after.query(&all(0, D0 + 5 * DAY));
    assert_eq!(folded, before);
    assert_eq!(folded.totals.turns, 200);
    assert!((folded.totals.cost_usd - 50.0).abs() < 1e-9);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_first_start_seeds_each_session_once() {
    let dir = scratch("seed");
    let seed = |id: &str, cost: Option<f64>| Seed {
        id: id.into(),
        at: D0 + 5,
        turns: 4,
        totals: TurnUsage { cost_usd: cost, input_tokens: Some(1_000_000), ..Default::default() },
        ctx: TurnContext { model: Some("claude-opus-5-5".into()), ..ctx("claude", "claude") },
    };
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        l.seed(vec![seed("a", Some(2.0)), seed("b", None)]);
        // Once only.
        l.seed(vec![seed("c", Some(5.0))]);
        let reply = l.query(&all(D0, D0));
        assert_eq!(reply.totals.turns, 8);
        // a: the harness's 2.0; b: 1M input at $4.
        assert!((reply.totals.cost_usd - 6.0).abs() < 1e-9);
        l.flush();
    }
    // The file exists now: a restart seeds nothing more.
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    l.seed(vec![seed("d", Some(7.0))]);
    assert!((l.query(&all(D0, D0)).totals.cost_usd - 6.0).abs() < 1e-9);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A crash during the first start's seed must not stand in for a ledger. The seed used to append
/// a line per row, so a crash part way through left a file that folded as existing: no reseed,
/// and the sessions after the crash had no rows, for good. Now the seed is one rewrite (the
/// file holds the whole snapshot or nothing), and a file with no line that parses, such as a
/// first write torn by the crash, is seeded again.
#[test]
fn a_torn_or_partial_first_seed_is_rebuilt() {
    let dir = scratch("seed-torn");
    let path = dir.join(store::FILE);
    let seed = |id: &str, cost: f64| Seed {
        id: id.into(),
        at: D0 + 5,
        turns: 2,
        totals: TurnUsage { cost_usd: Some(cost), ..Default::default() },
        ctx: TurnContext { model: Some("claude-opus-5-5".into()), ..ctx("claude", "claude") },
    };
    // The crash cut the seed's first line short: nothing in the file parses.
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(&path, br#"{"t":"s","sid":"a","info":{"title":"cla"#).unwrap();
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        assert!(l.wants_seed(), "a file with no whole line is not a ledger");
        l.seed(vec![seed("a", 1.0), seed("b", 2.0), seed("c", 4.0)]);
        l.flush();
    }
    // The seed is the state's snapshot, written whole: every session line, then every bucket,
    // not the row-by-row appends a crash could stop between.
    let text = std::fs::read_to_string(&path).unwrap();
    let kinds: Vec<&str> =
        text.lines().map(|line| if line.contains("\"t\":\"s\"") { "s" } else { "u" }).collect();
    assert_eq!(kinds, ["s", "s", "s", "u", "u", "u"], "{text}");
    assert!(!dir.join(format!("{}.tmp", store::FILE)).exists());
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(!l.wants_seed());
    let reply = l.query(&all(D0, D0));
    assert_eq!(reply.totals.turns, 6);
    assert!((reply.totals.cost_usd - 7.0).abs() < 1e-9);
    // A turn after the seed appends after it, and a restart keeps both.
    turn(
        &l,
        "a",
        D0 + 100,
        0,
        json!({"model": "claude-opus-5-5", "costUsd": 0.5}),
        "claude",
        "claude",
    );
    l.flush();
    drop(l);
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert_eq!(l.query(&all(D0, D0)).totals.turns, 7);
    let _ = std::fs::remove_dir_all(&dir);
}

/// An empty ledger file (created, never written) is not a ledger either.
#[test]
fn an_empty_ledger_file_is_seeded() {
    let dir = scratch("seed-empty");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(store::FILE), b"").unwrap();
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(l.wants_seed());
    let _ = std::fs::remove_dir_all(&dir);
}

/// A read visits the buckets of its days only: a year of other days, and thousands of other
/// sessions on them, add nothing to it.
#[test]
fn a_read_touches_only_the_buckets_in_its_range() {
    let l = mem();
    let cost = json!({"model": "claude-opus-5-5", "costUsd": 0.01});
    // 365 earlier days with 20 sessions each.
    for day in 1..=365u64 {
        for s in 0..20 {
            let id = format!("old-{s}");
            turn(&l, &id, D0 - day * DAY, 0, cost.clone(), "claude", "claude");
        }
    }
    // Today: three sessions.
    for s in 0..3 {
        turn(&l, &format!("new-{s}"), D0 + 10, 0, cost.clone(), "claude", "claude");
    }
    let state = l.lock();
    let (reply, visited) = query::fold(&state, &all(D0, D0 + DAY - 1), "leo@test");
    assert_eq!(visited, 3);
    assert_eq!(reply.rows.len(), 3);
    let (_, visited_week) = query::fold(&state, &all(D0 - 7 * DAY, D0 - DAY), "leo@test");
    assert_eq!(visited_week, 7 * 20);
}

#[test]
fn a_purged_session_leaves_the_index_and_the_file() {
    let dir = scratch("purge");
    let path = dir.join(store::FILE);
    let secret = |_: &str, _: &str| TurnContext {
        model: None,
        info: SessionInfo {
            title: Some("private plans".into()),
            workspace_id: Some("ws-incognito".into()),
            cwd: Some("/nowhere/private".into()),
            ..ctx("claude", "claude").info
        },
    };
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        let cost = json!({"model": "claude-opus-5-5", "costUsd": 1.0});
        turn(&l, "keep", D0, 0, cost.clone(), "claude", "claude");
        for (kind, at) in [("user_message", D0), ("turn_result", D0 + DAY + 5)] {
            let dir = if kind == "turn_result" { "mux" } else { "out" };
            l.record("gone", &rec(dir, kind, at, cost.clone()), || secret("", ""));
        }
        l.note_pull_request("gone", "https://github.com/acme/secret/pull/1");
        l.flush();
        l.purge("gone");
        // A repository lookup handed to the writer after the purge adds no row back.
        let checkout = dir.join("checkout");
        std::fs::create_dir_all(checkout.join(".git")).unwrap();
        std::fs::write(
            checkout.join(".git/config"),
            "[remote \"origin\"]\n\turl = https://github.com/acme/secret.git\n",
        )
        .unwrap();
        l.send(Work::Repo { sid: "gone".into(), cwd: checkout });
        l.flush();
        let reply = l.query(&all(0, D0 + 3 * DAY));
        assert_eq!(reply.totals.turns, 1);
        assert!(!l.lock().sessions.contains_key("gone"));
        assert!(l.lock().days.values().all(|b| b.keys().all(|k| &*k.session != "gone")));
    }
    let text = std::fs::read_to_string(&path).unwrap();
    for needle in ["gone", "private plans", "ws-incognito", "/nowhere/private", "acme/secret"] {
        assert!(!text.contains(needle), "{needle} is still in the file:\n{text}");
    }
    let after = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    let reply = after.query(&all(0, D0 + 3 * DAY));
    assert_eq!(reply.totals.turns, 1);
    assert!(!after.lock().sessions.contains_key("gone"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_tombstone_in_the_file_drops_what_came_before_it() {
    let dir = scratch("tombstone");
    std::fs::create_dir_all(&dir).unwrap();
    let spend = |sid: &str| {
        format!(
            r#"{{"t":"u","sid":"{sid}","at":{D0},"model":"m","pv":"v","costUsd":1.0,"turns":1}}"#
        )
    };
    let text = format!("{}\n{}\n{{\"t\":\"p\",\"sid\":\"x\"}}\n", spend("x"), spend("y"));
    std::fs::write(dir.join(store::FILE), text).unwrap();
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert_eq!(l.query(&all(D0, D0)).totals.turns, 1);
    assert!(!l.lock().sessions.contains_key("x"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_line_from_before_cache_savings_gets_them_on_fold() {
    let dir = scratch("cache-saved-backfill");
    std::fs::create_dir_all(&dir).unwrap();
    let line = format!(
        r#"{{"t":"u","sid":"x","at":{D0},"model":"claude-opus-5-5","pv":"v","costUsd":1.0,"cacheReadTokens":1000000,"turns":1}}"#
    );
    std::fs::write(dir.join(store::FILE), format!("{line}\n")).unwrap();
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    let saved = l.query(&all(D0, D0)).totals.cache_saved_usd;
    assert!((saved - 3.8).abs() < 1e-9, "{saved}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_torn_last_line_is_cut_so_later_turns_survive_restarts() {
    let dir = scratch("torn");
    let path = dir.join(store::FILE);
    let cost = json!({"model": "claude-opus-5-5", "costUsd": 1.0});
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        turn(&l, "a", D0, 0, cost.clone(), "claude", "claude");
        l.flush();
    }
    // A crash mid-write: half a line, no newline.
    let mut f = OpenOptions::new().append(true).open(&path).unwrap();
    f.write_all(br#"{"t":"u","sid":"a","at":1,"mod"#).unwrap();
    drop(f);
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        assert_eq!(l.query(&all(D0, D0)).totals.turns, 1);
        turn(&l, "a", D0 + 100, 0, cost.clone(), "claude", "claude");
        l.flush();
    }
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        assert_eq!(l.query(&all(D0, D0)).totals.turns, 2, "the second restart keeps both");
        turn(&l, "a", D0 + 200, 0, cost.clone(), "claude", "claude");
        l.flush();
    }
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert_eq!(l.query(&all(D0, D0)).totals.turns, 3);
    assert!(std::fs::read_to_string(&path).unwrap().ends_with('\n'));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_turn_with_a_model_and_no_counts_is_unpriced_not_free() {
    let l = mem();
    turn(&l, "a", D0, 0, json!({"model": "claude-opus-5-5"}), "claude", "claude");
    let reply = l.query(&all(D0, D0));
    assert_eq!(reply.totals.unpriced_turns, 1);
    assert_eq!(reply.totals.table_cost_usd, 0.0);
}

#[test]
fn a_seeded_session_looks_up_its_repository() {
    let dir = scratch("seed-repo");
    let checkout = dir.join("checkout");
    std::fs::create_dir_all(checkout.join(".git")).unwrap();
    std::fs::write(
        checkout.join(".git/config"),
        "[remote \"origin\"]\n\turl = https://github.com/acme/widgets.git\n",
    )
    .unwrap();
    let l = Ledger::open_with(Some(dir.join("ledger")), COMPACT_BYTES, "leo@test".into());
    let mut c = TurnContext { model: Some("claude-opus-5-5".into()), ..ctx("claude", "claude") };
    c.info.cwd = Some(checkout.to_string_lossy().into_owned());
    l.seed(vec![Seed {
        id: "a".into(),
        at: D0,
        turns: 1,
        totals: TurnUsage { cost_usd: Some(1.0), ..Default::default() },
        ctx: c,
    }]);
    l.flush();
    assert_eq!(
        l.lock().sessions.get("a").and_then(|i| i.repo.clone()).as_deref(),
        Some("acme/widgets")
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn close_drains_the_writer_before_it_ends() {
    let dir = scratch("close");
    let cost = json!({"model": "claude-opus-5-5", "costUsd": 1.0});
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        for i in 0..50 {
            turn(&l, "a", D0 + i, 1, cost.clone(), "claude", "claude");
        }
        // No flush: the shutdown's close is what writes the queue out.
        assert!(l.close(std::time::Duration::from_secs(10)));
        // A line after the close stays in memory and does not fail.
        turn(&l, "a", D0 + 99, 0, cost.clone(), "claude", "claude");
        assert!(l.close(std::time::Duration::from_secs(1)));
    }
    let after = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert_eq!(after.query(&all(D0, D0)).totals.turns, 50);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_folded_session_with_no_repository_looks_it_up() {
    let dir = scratch("fold-repo");
    let checkout = dir.join("checkout");
    std::fs::create_dir_all(checkout.join(".git")).unwrap();
    std::fs::write(
        checkout.join(".git/config"),
        "[remote \"origin\"]\n\turl = git@github.com:acme/widgets.git\n",
    )
    .unwrap();
    let ledger_dir = dir.join("ledger");
    std::fs::create_dir_all(&ledger_dir).unwrap();
    let line = json!({"t": "s", "sid": "a", "harness": "claude", "cwd": checkout, "createdAt": 1});
    std::fs::write(ledger_dir.join(store::FILE), format!("{line}\n")).unwrap();
    let l = Ledger::open_with(Some(ledger_dir), COMPACT_BYTES, "leo@test".into());
    l.flush();
    assert_eq!(
        l.lock().sessions.get("a").and_then(|i| i.repo.clone()).as_deref(),
        Some("acme/widgets")
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_seeded_session_with_turns_and_no_usage_counts_them_unpriced() {
    let l = mem();
    l.seed(vec![Seed {
        id: "a".into(),
        at: D0,
        turns: 3,
        totals: TurnUsage::default(),
        ctx: TurnContext { model: Some("claude-opus-5-5".into()), ..ctx("claude", "claude") },
    }]);
    let t = l.query(&all(D0, D0)).totals;
    assert_eq!((t.turns, t.unpriced_turns), (3, 3));
    assert_eq!(t.cost_usd, 0.0);
}

#[test]
fn nothing_is_recorded_about_a_session_after_its_purge() {
    let dir = scratch("late-writers");
    let path = dir.join(store::FILE);
    let late = "https://github.com/acme/secret/pull/2";
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        let cost = json!({"model": "claude-opus-5-5", "costUsd": 1.0});
        turn(&l, "keep", D0, 0, cost.clone(), "claude", "claude");
        turn(&l, "gone", D0, 1, cost.clone(), "claude", "claude");
        l.flush();
        l.purge("gone");
        // An in-flight tool update, turn and meta save after the purge write nothing.
        l.note_pull_request("gone", late);
        turn(&l, "gone", D0 + 60_000, 1, cost.clone(), "claude", "claude");
        let info = SessionInfo { title: Some("after the purge".into()), ..Default::default() };
        l.note_session_info("gone", info);
        l.seed([Seed {
            id: "gone".into(),
            at: D0,
            turns: 3,
            totals: TurnUsage::default(),
            ctx: ctx("claude", "claude"),
        }]);
        l.flush();
        assert!(!l.lock().sessions.contains_key("gone"));
        assert!(!l.lock().open.contains_key("gone"));
        assert_eq!(l.query(&all(0, D0 + 3 * DAY)).totals.turns, 1);
    }
    let text = std::fs::read_to_string(&path).unwrap();
    for needle in ["\"gone\"", late, "after the purge"] {
        assert!(!text.contains(needle), "{needle} is in the file:\n{text}");
    }
    let after = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(!after.lock().sessions.contains_key("gone"));
    assert_eq!(after.query(&all(0, D0 + 3 * DAY)).totals.turns, 1);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A purge blocks its id only until a chat is created under it again (a trigger's fixed id):
/// the new chat's turns count, the purged one's spend does not come back.
#[test]
fn a_chat_recreated_under_a_purged_id_counts_again() {
    let l = mem();
    let cost = json!({"model": "claude-opus-5-5", "costUsd": 1.0});
    turn(&l, "same", D0, 0, cost.clone(), "claude", "claude");
    l.purge("same");
    turn(&l, "same", D0 + 1_000, 0, cost.clone(), "claude", "claude");
    assert_eq!(l.query(&all(D0, D0)).totals.turns, 0);
    l.reopen("same");
    turn(&l, "same", D0 + 60_000, 0, cost.clone(), "claude", "claude");
    let reply = l.query(&all(D0, D0));
    assert_eq!(reply.totals.turns, 1);
    assert!((reply.totals.cost_usd - 1.0).abs() < 1e-9);
}

#[test]
fn a_meta_change_writes_one_session_line_only_when_a_field_changed() {
    let dir = scratch("session-info");
    let path = dir.join(store::FILE);
    let lines = || std::fs::read_to_string(&path).unwrap().lines().count();
    {
        let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
        // A session the ledger does not hold yet gets its fields at its first turn.
        l.note_session_info("a", ctx("claude", "claude").info);
        l.flush();
        assert!(!l.lock().sessions.contains_key("a"));
        turn(&l, "a", D0, 0, json!({"model": "claude-opus-5-5"}), "claude", "claude");
        l.flush();
        let before = lines();
        let renamed = SessionInfo {
            title: Some("renamed".into()),
            branch: Some("feature".into()),
            workspace_id: Some("ws-2".into()),
            account: Some("home".into()),
            ..ctx("claude", "claude").info
        };
        l.note_session_info("a", renamed.clone());
        l.flush();
        assert_eq!(lines(), before + 1);
        // The same fields again, or none: nothing written.
        l.note_session_info("a", renamed);
        l.note_session_info("a", SessionInfo::default());
        l.flush();
        assert_eq!(lines(), before + 1);
    }
    let after = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    let s = after.lock();
    let row = s.sessions.get("a").unwrap();
    assert_eq!(row.title.as_deref(), Some("renamed"));
    assert_eq!(row.branch.as_deref(), Some("feature"));
    assert_eq!(row.workspace_id.as_deref(), Some("ws-2"));
    assert_eq!(row.account.as_deref(), Some("home"));
    drop(s);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_cut_session_list_keeps_the_biggest_spenders() {
    let l = mem();
    // The oldest chat spent the most; two newer ones spent less.
    turn(&l, "old", D0, 0, json!({"costUsd": 9.0}), "claude", "claude");
    turn(&l, "new", D0 + 10, 0, json!({"costUsd": 1.0}), "claude", "claude");
    turn(&l, "newer", D0 + 20, 0, json!({"costUsd": 2.0}), "claude", "claude");
    let reply = l.query(&LedgerQuery { limit: 2, ..all(D0, D0 + 20) });
    let ids: Vec<_> = reply.rows.iter().map(|r| r.session_id.as_str()).collect();
    assert_eq!(ids, ["old", "newer"]);
    // The totals still count every chat.
    assert_eq!(reply.totals.sessions, 3);
}

/// A first seed whose rewrite fails writes nothing rather than a part: a line in the file would
/// read as a ledger and skip the seed for good. The rewrite is tried again at the next step, and a
/// restart before one lands seeds again.
#[test]
fn a_failed_seed_rewrite_leaves_no_partial_ledger() {
    let dir = scratch("seed-fails");
    let path = dir.join(store::FILE);
    let tmp = dir.join(format!("{}.tmp", store::FILE));
    let seed = |id: &str| Seed {
        id: id.into(),
        at: D0 + 5,
        turns: 1,
        totals: TurnUsage { cost_usd: Some(1.0), ..Default::default() },
        ctx: TurnContext { model: Some("claude-opus-5-5".into()), ..ctx("claude", "claude") },
    };
    // A directory where the rewrite's temporary file goes: the rewrite fails.
    std::fs::create_dir_all(&tmp).unwrap();
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(l.wants_seed());
    l.seed(vec![seed("a"), seed("b")]);
    l.flush();
    // A turn while the seed waits appends nothing either.
    turn(&l, "a", D0 + 100, 0, json!({"costUsd": 0.5}), "claude", "claude");
    l.flush();
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(text.is_empty(), "{text}");
    assert!(Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into()).wants_seed());
    // Once the rewrite can land, the next step writes the whole state.
    std::fs::remove_dir_all(&tmp).unwrap();
    turn(&l, "b", D0 + 200, 0, json!({"costUsd": 0.25}), "claude", "claude");
    l.flush();
    drop(l);
    let l = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(!l.wants_seed());
    assert_eq!(l.query(&all(D0, D0)).totals.turns, 4);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A first start writes nothing before its seed: a watcher's turn while the store loads would
/// otherwise make a file that reads as a ledger, and a crash before the seed's rewrite landed
/// would skip the seed for good. The seed's rewrite carries the held turn.
#[test]
fn a_first_start_writes_nothing_before_its_seed() {
    let dir = scratch("seed-holds");
    let path = dir.join(store::FILE);
    let l = Ledger::open_as(Some(dir.clone()), COMPACT_BYTES, "leo@test".into(), true);
    turn(&l, "live", D0 + 100, 0, json!({"costUsd": 0.5}), "claude", "claude");
    l.flush();
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(text.is_empty(), "{text}");
    // A crash here: the next start still seeds.
    assert!(Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into()).wants_seed());
    l.seed(vec![Seed {
        id: "old".into(),
        at: D0 + 5,
        turns: 2,
        totals: TurnUsage { cost_usd: Some(1.0), ..Default::default() },
        ctx: TurnContext { model: Some("claude-opus-5-5".into()), ..ctx("claude", "claude") },
    }]);
    l.flush();
    drop(l);
    let after = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(!after.wants_seed());
    let t = after.query(&all(D0, D0)).totals;
    assert_eq!(t.turns, 3);
    assert!((t.cost_usd - 1.5).abs() < 1e-9);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A first start with nothing to seed still ends the hold: later turns reach the file.
#[test]
fn an_empty_seed_ends_the_hold() {
    let dir = scratch("seed-empty-ends-hold");
    let l = Ledger::open_as(Some(dir.clone()), COMPACT_BYTES, "leo@test".into(), true);
    l.seed(Vec::new());
    turn(&l, "a", D0, 0, json!({"costUsd": 0.5}), "claude", "claude");
    l.flush();
    drop(l);
    let after = Ledger::open_with(Some(dir.clone()), COMPACT_BYTES, "leo@test".into());
    assert!(!after.wants_seed());
    assert_eq!(after.query(&all(D0, D0)).totals.turns, 1);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A deleted chat's late record, after a new chat took its id, neither counts nor removes the
/// new chat's spend: the old chat's own flag is read under the ledger's lock.
#[test]
fn a_deleted_chats_late_record_leaves_its_replacement_alone() {
    let l = mem();
    let c = || ctx("claude", "claude");
    let old = AtomicBool::new(false);
    let new = AtomicBool::new(false);
    let r = |l: &Ledger, gone: &AtomicBool, kind: &str, at: u64, msg: Value| {
        let dir = match kind {
            "user_message" => "out",
            "tool_call" => "in",
            _ => "mux",
        };
        l.record_as("same", Some(gone), &rec(dir, kind, at, msg), c);
    };
    r(&l, &old, "user_message", D0, json!({"text": "go"}));
    r(&l, &old, "turn_started", D0 + 1_000, json!({}));
    // Deleted (`Hub::kill` sets the flag, then purges), then created again under the same id.
    old.store(true, Ordering::SeqCst);
    l.purge("same");
    l.reopen("same");
    r(&l, &new, "user_message", D0 + 60_000, json!({"text": "go"}));
    r(&l, &new, "turn_started", D0 + 61_000, json!({}));
    // The old chat's paused watcher resumes: a tool call and a result.
    r(&l, &old, "tool_call", D0 + 62_000, json!({}));
    r(&l, &old, "turn_result", D0 + 63_000, json!({"costUsd": 5.0}));
    assert!(l.lock().open.contains_key("same"), "the new chat's turn is still open");
    r(&l, &new, "turn_result", D0 + 71_000, json!({"costUsd": 1.0}));
    let t = l.query(&all(D0, D0)).totals;
    assert_eq!(t.turns, 1);
    assert!((t.cost_usd - 1.0).abs() < 1e-9, "{}", t.cost_usd);
    // The new chat keeps counting.
    r(&l, &new, "user_message", D0 + 80_000, json!({"text": "go"}));
    r(&l, &new, "turn_started", D0 + 81_000, json!({}));
    r(&l, &new, "turn_result", D0 + 90_000, json!({"costUsd": 1.0}));
    assert_eq!(l.query(&all(D0, D0)).totals.turns, 2);
}
