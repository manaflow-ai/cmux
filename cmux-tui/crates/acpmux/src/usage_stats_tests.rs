use super::*;
use serde_json::json;
use std::io::Write;

const SID: &str = "01a18ad5-89bc-7a02-905f-8f4fbef7fed2";

fn ms(text: &str) -> u64 {
    crate::server::machine_health::rfc3339_ms(text).unwrap()
}

fn models() -> Models {
    let mut m = Models::default();
    let opus = Prices { input: 4.0, output: 20.0, cache_read: 0.2, cache_write: 5.0 };
    m.add("claude-opus-5-5", Some(opus), Some(1_000_000));
    let astra = Prices { input: 2.0, output: 10.0, cache_read: 0.5, cache_write: 2.0 };
    m.add("gpt-6-astra", Some(astra), Some(400_000));
    m
}

fn append(path: &Path, records: &[Value]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    for r in records {
        writeln!(f, "{r}").unwrap();
    }
}

fn assistant(id: &str, at: &str, usage: Value, sidechain: bool) -> Value {
    json!({"type": "assistant", "isSidechain": sidechain, "timestamp": at,
        "message": {"id": id, "model": "claude-opus-5-5", "role": "assistant",
            "content": [{"type": "text", "text": "hi"}], "usage": usage}})
}

fn usage(input: u64, write: u64, read: u64, output: u64) -> Value {
    json!({"input_tokens": input, "cache_creation_input_tokens": write,
        "cache_read_input_tokens": read, "output_tokens": output})
}

/// A Claude chat in `home` (its CLAUDE_CONFIG_DIR), and the path of its transcript.
fn claude(home: &Path) -> (Source, PathBuf) {
    let cwd = PathBuf::from("/work/repo.x");
    let mut env = BTreeMap::new();
    env.insert("CLAUDE_CONFIG_DIR".to_owned(), home.display().to_string());
    let source = Source {
        family: "claude".into(),
        agent_session_id: SID.into(),
        cwd,
        created_at: ms("2026-10-30T00:00:00Z"),
        argv: vec!["/usr/local/bin/claude".into(), "--autocompact".into(), "200k".into()],
        env,
    };
    (source, home.join("projects/-work-repo-x").join(format!("{SID}.jsonl")))
}

#[test]
fn a_claude_transcript_counts_each_message_once_and_reads_only_what_was_appended() {
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let now = ms("2026-10-30T12:00:00Z");
    append(
        &path,
        &[
            json!({"type": "user", "timestamp": "2026-10-30T11:00:00Z", "message": {"content": "go"}}),
            // Claude Code writes one line per content block; each repeats the message's usage.
            assistant("msg_1", "2026-10-30T11:00:01Z", usage(10, 1000, 0, 100), false),
            assistant("msg_1", "2026-10-30T11:00:01Z", usage(10, 1000, 0, 100), false),
            json!({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-10-30T11:30:00Z",
                "compactMetadata": {"trigger": "auto", "preTokens": 190_000}}),
            // Older than a day: neither its tokens nor its compaction count.
            assistant("msg_0", "2026-10-28T11:00:00Z", usage(1, 1, 1, 1), false),
            json!({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-10-28T11:30:00Z"}),
            // An API error Claude Code made up carries no spend.
            assistant("msg_s", "2026-10-30T11:31:00Z", usage(0, 0, 0, 0), false)
                .tap(|v| v["message"]["model"] = json!("<synthetic>")),
        ],
    );
    let mut tracker = Tracker::default();
    let first = tracker.refresh(&source, now, &models());
    assert_eq!(first.tokens24h, 1110);
    assert_eq!(first.context_tokens, Some(1010));
    assert_eq!(first.context_window, Some(1_000_000));
    assert_eq!(first.compactions24h, 1);
    assert_eq!(first.autocompact_cap, Some(200_000));
    assert_eq!(first.launcher.as_deref(), Some("claude"));
    // 10 input at $4, 1000 cache writes at $5, 100 output at $20, per million.
    assert_eq!(first.cost_usd24h, Some(0.0070));
    assert_eq!(first.updated_at, now);

    // The next message's first line, then a half-written line: only complete lines are read.
    append(&path, &[assistant("msg_2", "2026-10-30T11:59:00Z", usage(5, 0, 1010, 50), false)]);
    let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    write!(f, "{}", assistant("msg_3", "2026-10-30T11:59:30Z", usage(1, 0, 0, 1), false)).unwrap();
    let second = tracker.refresh(&source, now, &models());
    assert_eq!(second.tokens24h, 1110 + 1065);
    assert_eq!(second.context_tokens, Some(1015));
    writeln!(f).unwrap();
    // A subagent's line in the chat's own file (a sidechain) is spend, not the chat's context.
    append(&path, &[assistant("msg_4", "2026-10-30T11:59:40Z", usage(7, 0, 0, 0), true)]);
    let third = tracker.refresh(&source, now, &models());
    assert_eq!(third.tokens24h, 1110 + 1065 + 2 + 7);
    assert_eq!(third.context_tokens, Some(1));

    // A day later every bucket has aged out; the last call's context stays.
    let later = tracker.refresh(&source, now + DAY_MS, &models());
    assert_eq!((later.tokens24h, later.compactions24h, later.cost_usd24h), (0, 0, None));
    assert_eq!(later.context_tokens, Some(1));
}

#[test]
fn claude_subagents_count_as_spawns_and_spend_and_live_until_finished() {
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    // On the real clock: a subagent is live while its file changed in the last half hour.
    let now = crate::store::now_ms();
    let ago = |minutes: u64| iso(now - minutes * MINUTE_MS);
    append(&path, &[assistant("msg_1", &ago(60), usage(1, 0, 0, 1), false)]);
    let dir = path.parent().unwrap().join(SID).join("subagents");
    // Started two hours ago and finished.
    append(
        &dir.join("agent-a1.jsonl"),
        &[
            json!({"type": "user", "isSidechain": true, "timestamp": ago(120)}),
            assistant("msg_a1", &ago(119), usage(100, 0, 0, 10), true),
        ],
    );
    std::fs::write(dir.join("agent-a1.meta.json"), r#"{"finished":true}"#).unwrap();
    // Started ten minutes ago and still running.
    append(
        &dir.join("agent-a2.jsonl"),
        &[
            json!({"type": "user", "isSidechain": true, "timestamp": ago(10)}),
            assistant("msg_a2", &ago(9), usage(200, 0, 0, 20), true),
        ],
    );
    std::fs::write(dir.join("agent-a2.meta.json"), r#"{"agentType":"Explore"}"#).unwrap();
    let mut tracker = Tracker::default();
    let stats = tracker.refresh(&source, now, &models());
    assert_eq!(stats.subagents24h, 2);
    assert_eq!(stats.subagents1h, 1);
    assert_eq!(stats.subagents_live, 1);
    assert_eq!(stats.tokens24h, 2 + 110 + 220);
    assert_eq!(stats.context_tokens, Some(1), "a subagent's call is not the chat's context");

    // The running one finishes: no longer live, and a later pass never counts it twice.
    std::fs::write(dir.join("agent-a2.meta.json"), r#"{"finished":true}"#).unwrap();
    let again = tracker.refresh(&source, now, &models());
    assert_eq!((again.subagents24h, again.subagents_live, again.tokens24h), (2, 0, 332));
}

fn iso(at: u64) -> String {
    crate::server::iso(at)
}

#[test]
fn a_codex_rollout_is_found_by_its_day_and_counts_each_token_report_once() {
    let home = tempfile::tempdir().unwrap();
    let created = ms("2026-10-29T23:59:00Z");
    let mut env = BTreeMap::new();
    env.insert("CODEX_HOME".to_owned(), home.path().display().to_string());
    let source = Source {
        family: "codex".into(),
        agent_session_id: SID.into(),
        cwd: "/work".into(),
        created_at: created,
        argv: vec!["codex-acp".into(), "-c".into(), "model_auto_compact_token_limit=150000".into()],
        env,
    };
    // Written on the next UTC day: still found next to its creation day.
    let path =
        home.path().join(format!("sessions/2026/10/30/rollout-2026-10-30T00-00-00-{SID}.jsonl"));
    let tokens = |total: u64, input: u64, cached: u64, output: u64| {
        json!({"timestamp": "2026-10-30T11:00:00Z", "type": "event_msg", "payload": {"type": "token_count",
            "info": {"total_token_usage": {"total_tokens": total},
                "last_token_usage": {"input_tokens": input, "cached_input_tokens": cached,
                    "output_tokens": output, "total_tokens": input + output},
                "model_context_window": 258_400}}})
    };
    append(
        &path,
        &[
            json!({"timestamp": "2026-10-30T10:59:00Z", "type": "turn_context", "payload": {"model": "gpt-6-astra"}}),
            tokens(1100, 1000, 400, 100),
            // A rate-limit update repeats the same totals.
            tokens(1100, 1000, 400, 100),
            json!({"timestamp": "2026-10-30T11:01:00Z", "type": "response_item",
            "payload": {"type": "function_call", "name": "spawn_agent", "arguments": "{}"}}),
            json!({"timestamp": "2026-10-30T11:02:00Z", "type": "compacted", "payload": {"message": "..."}}),
            tokens(3300, 2000, 0, 200),
        ],
    );
    let stats = Tracker::default().refresh(&source, ms("2026-10-30T12:00:00Z"), &models());
    assert_eq!(stats.tokens24h, 1100 + 2200);
    assert_eq!(stats.context_tokens, Some(2000));
    assert_eq!(stats.context_window, Some(258_400));
    assert_eq!((stats.compactions24h, stats.subagents24h, stats.subagents1h), (1, 1, 1));
    assert_eq!(stats.autocompact_cap, Some(150_000));
    assert_eq!(stats.launcher.as_deref(), Some("codex-acp"));
    // (600 at $2 + 400 cached at $0.5 + 100 at $10) + (2000 at $2 + 200 at $10), per million.
    assert_eq!(stats.cost_usd24h, Some(0.0084));
}

#[test]
fn the_autocompact_cap_comes_from_the_flag_then_the_env_then_the_settings() {
    let home = tempfile::tempdir().unwrap();
    let (mut source, _) = claude(home.path());
    assert_eq!(autocompact_cap(&source, None), Some(200_000));
    source.argv = vec!["claude".into(), "--autocompact=auto".into()];
    assert_eq!(autocompact_cap(&source, None), None, "auto is the harness's own default");
    source.argv = vec!["claude".into()];
    assert_eq!(autocompact_cap(&source, None), None, "nothing caps it");
    std::fs::write(home.path().join("settings.json"), r#"{"autoCompactWindow": 300000}"#).unwrap();
    assert_eq!(autocompact_cap(&source, None), Some(300_000));
    source.env.insert("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE".into(), "40".into());
    assert_eq!(autocompact_cap(&source, Some(1_000_000)), Some(400_000));
    source.env.insert("CLAUDE_CODE_AUTO_COMPACT_WINDOW".into(), "1M".into());
    assert_eq!(autocompact_cap(&source, None), Some(1_000_000));

    let mut codex = Source { family: "codex".into(), ..Source::default() };
    codex.env.insert("CODEX_HOME".into(), home.path().display().to_string());
    assert_eq!(autocompact_cap(&codex, None), None);
    std::fs::write(
        home.path().join("config.toml"),
        "model = \"gpt-6-astra\"\nmodel_auto_compact_token_limit = 180_000 # cap\n[x]\nmodel_auto_compact_token_limit = 1\n",
    )
    .unwrap();
    assert_eq!(autocompact_cap(&codex, None), Some(180_000));
}

#[test]
fn days_and_token_counts_read_as_the_harnesses_write_them() {
    assert_eq!(civil_from_days(0), (1970, 1, 1));
    assert_eq!(civil_from_days(ms("2026-10-30T12:00:00Z") / DAY_MS), (2026, 10, 30));
    assert_eq!(civil_from_days(ms("2024-02-29T00:00:00Z") / DAY_MS), (2024, 2, 29));
    assert_eq!(tokens("200k"), Some(200_000));
    assert_eq!(tokens("1_000_000"), Some(1_000_000));
    assert_eq!(tokens("auto"), None);
    assert_eq!(launcher(&["/home/u/.local/bin/claude-sr2".into()]).as_deref(), Some("claude-sr2"));
    let mut m = Models::default();
    m.add("Claude-Opus-5-5", None, Some(1));
    assert_eq!(m.window("claude-opus-5-5[1m]"), Some(1));
}

trait Tap {
    fn tap(self, f: impl FnOnce(&mut Self)) -> Self;
}

impl Tap for Value {
    fn tap(mut self, f: impl FnOnce(&mut Self)) -> Self {
        f(&mut self);
        self
    }
}
