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
        argv: Some(vec!["/usr/local/bin/claude".into(), "--autocompact".into(), "200k".into()]),
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
    let first = tracker.refresh(&source, now, &models()).unwrap();
    assert_eq!(first.tokens24h, Some(1110));
    assert_eq!(first.context_tokens, Some(1010));
    assert_eq!(first.context_window, Some(1_000_000));
    assert_eq!(first.compactions24h, Some(1));
    assert_eq!((first.autocompact, first.autocompact_cap), (Autocompact::Capped, Some(200_000)));
    assert_eq!(first.subagents_live, Some(0), "it never started one");
    assert_eq!(first.launcher.as_deref(), Some("claude"));
    // 10 input at $4, 1000 cache writes at $5, 100 output at $20, per million.
    assert_eq!(first.cost_usd24h, Some(0.0070));
    assert_eq!(first.updated_at, now);

    // The next message's first line, then a half-written line: only complete lines are read.
    append(&path, &[assistant("msg_2", "2026-10-30T11:59:00Z", usage(5, 0, 1010, 50), false)]);
    let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    write!(f, "{}", assistant("msg_3", "2026-10-30T11:59:30Z", usage(1, 0, 0, 1), false)).unwrap();
    let second = tracker.refresh(&source, now, &models()).unwrap();
    // The line still being written is not known yet: the day's count is unknown, not short.
    assert_eq!(second.tokens24h, None);
    assert_eq!(second.context_tokens, Some(1015));
    writeln!(f).unwrap();
    // A subagent's line in the chat's own file (a sidechain) is spend, not the chat's context.
    append(&path, &[assistant("msg_4", "2026-10-30T11:59:40Z", usage(7, 0, 0, 0), true)]);
    let third = tracker.refresh(&source, now, &models()).unwrap();
    assert_eq!(third.tokens24h, Some(1110 + 1065 + 2 + 7));
    assert_eq!(third.context_tokens, Some(1));

    // A day later every bucket has aged out; the last call's context stays.
    let later = tracker.refresh(&source, now + DAY_MS, &models()).unwrap();
    assert_eq!(
        (later.tokens24h, later.compactions24h, later.cost_usd24h),
        (Some(0), Some(0), None)
    );
    assert_eq!(later.context_tokens, Some(1));
}

#[test]
fn a_chat_whose_transcript_is_not_found_has_no_stats() {
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let mut tracker = Tracker::default();
    let now = ms("2026-10-30T12:00:00Z");
    assert_eq!(tracker.refresh(&source, now, &models()), None);
    // Looked for again only after a while, then found.
    append(&path, &[assistant("msg_1", "2026-10-30T11:00:00Z", usage(1, 0, 0, 1), false)]);
    assert_eq!(tracker.refresh(&source, now + 1000, &models()), None);
    assert_eq!(
        tracker.refresh(&source, now + LOOK_AGAIN_MS, &models()).unwrap().tokens24h,
        Some(2)
    );
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
    let stats = tracker.refresh(&source, now, &models()).unwrap();
    assert_eq!(stats.subagents24h, Some(2));
    assert_eq!(stats.subagents1h, Some(1));
    assert_eq!(stats.subagents_live, Some(1));
    assert_eq!(stats.tokens24h, Some(2 + 110 + 220));
    assert_eq!(stats.context_tokens, Some(1), "a subagent's call is not the chat's context");

    // The running one finishes: no longer live, and a later pass never counts it twice.
    std::fs::write(dir.join("agent-a2.meta.json"), r#"{"finished":true}"#).unwrap();
    let again = tracker.refresh(&source, now, &models()).unwrap();
    assert_eq!(
        (again.subagents24h, again.subagents_live, again.tokens24h),
        (Some(2), Some(0), Some(332))
    );
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
        argv: Some(vec![
            "codex-acp".into(),
            "-c".into(),
            "model_auto_compact_token_limit=150000".into(),
        ]),
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
    let stats = Tracker::default().refresh(&source, ms("2026-10-30T12:00:00Z"), &models()).unwrap();
    assert_eq!(stats.tokens24h, Some(1100 + 2200));
    assert_eq!(stats.context_tokens, Some(2000));
    assert_eq!(stats.context_window, Some(258_400));
    assert_eq!(
        (stats.compactions24h, stats.subagents24h, stats.subagents1h),
        (Some(1), Some(1), Some(1))
    );
    assert_eq!((stats.autocompact, stats.autocompact_cap), (Autocompact::Capped, Some(150_000)));
    assert_eq!(stats.subagents_live, None, "a Codex child is not in its rollout: the hub knows it");
    assert_eq!(stats.launcher.as_deref(), Some("codex-acp"));
    // (600 at $2 + 400 cached at $0.5 + 100 at $10) + (2000 at $2 + 200 at $10), per million.
    assert_eq!(stats.cost_usd24h, Some(0.0084));
}

#[test]
fn a_chat_whose_calls_are_all_older_than_the_day_keeps_its_last_calls_context() {
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    // A tool input that names its own timestamp: the record's is the line's last.
    let mut call = assistant("msg_2", "2026-10-28T10:00:00Z", usage(1, 2, 300, 4), false);
    call["message"]["content"] =
        json!([{"type": "tool_use", "input": {"timestamp": "2026-10-30T11:00:00Z"}}]);
    append(
        &path,
        &[
            assistant("msg_1", "2026-10-28T09:00:00Z", usage(5, 5, 5, 5), false),
            call,
            json!({"type": "user", "timestamp": "2026-10-28T10:00:01Z", "message": {"content": "x"}}),
            // Newer, but no call of the chat's: an API error Claude Code made up, a subagent's.
            assistant("msg_s", "2026-10-28T10:00:02Z", usage(0, 0, 0, 0), false)
                .tap(|v| v["message"]["model"] = json!("<synthetic>")),
            assistant("msg_3", "2026-10-28T10:00:03Z", usage(9, 9, 9, 9), true),
        ],
    );
    let stats = Tracker::default().refresh(&source, ms("2026-10-30T12:00:00Z"), &models()).unwrap();
    assert_eq!(stats.context_tokens, Some(303));
    assert_eq!((stats.tokens24h, stats.cost_usd24h), (Some(0), None));
}

/// Review of #28015: a first read cut exactly at a line start keeps that line.
#[test]
fn a_first_read_cut_at_a_line_start_keeps_that_line() {
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let now = ms("2026-10-30T12:00:00Z");
    let old = assistant("msg_0", "2026-10-28T09:00:00Z", usage(1, 0, 0, 1), false);
    let kept = assistant("msg_1", "2026-10-28T10:00:00Z", usage(3, 0, 0, 4), false);
    append(&path, &[old, kept.clone()]);
    // The cut falls on the last line's first byte.
    let first = format!("{kept}\n").len() as u64;
    let mut tracker = Tracker { limits: Some((first, u64::MAX)), ..Tracker::default() };
    let stats = tracker.refresh(&source, now, &models()).unwrap();
    assert_eq!(stats.context_tokens, Some(3), "the line at the cut was read");
    assert_eq!(stats.tokens24h, Some(0), "it starts before the day: the day's count is known");
}

/// Review of #28015: a line still being written, or one longer than a read step, never reads
/// as a known count, and a long line does not stop the reads after it.
#[test]
fn a_line_being_written_or_too_long_leaves_the_counts_unknown() {
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let now = ms("2026-10-30T12:00:00Z");
    append(&path, &[assistant("msg_1", "2026-10-30T11:00:00Z", usage(1, 0, 0, 1), false)]);
    let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    write!(f, "{}", assistant("msg_2", "2026-10-30T11:01:00Z", usage(5, 0, 0, 5), false)).unwrap();
    let mut tracker = Tracker::default();
    assert_eq!(tracker.refresh(&source, now, &models()).unwrap().tokens24h, None);
    writeln!(f).unwrap();
    assert_eq!(tracker.refresh(&source, now, &models()).unwrap().tokens24h, Some(12));

    // A line longer than a read step: skipped, and the day it may fall in is unknown.
    let mut long = assistant("msg_3", "2026-10-30T11:02:00Z", usage(7, 0, 0, 7), false);
    long["message"]["content"] = json!([{"type": "text", "text": "x".repeat(4096)}]);
    append(&path, &[long, assistant("msg_4", "2026-10-30T11:03:00Z", usage(2, 0, 0, 0), false)]);
    let mut stepped = Tracker { limits: Some((u64::MAX, 1024)), ..Tracker::default() };
    let mut last = None;
    for _ in 0..12 {
        last = Some(stepped.refresh(&source, now, &models()).unwrap());
    }
    let last = last.unwrap();
    assert_eq!(last.context_tokens, Some(2), "the line after the long one was read");
    assert_eq!(last.tokens24h, None, "the long line's tokens are unknown, not 0");
    // A day after it was lost (at the refresh's `now`), the day's counts are known again.
    let later = stepped.refresh(&source, now + DAY_MS, &models()).unwrap();
    assert_eq!(later.tokens24h, Some(0));
}

/// Review of #28015: a record that should count but cannot be read (not JSON, no time, no
/// token counts) makes the day's counts unknown while it is in the day, never 0 or now.
#[test]
fn a_record_that_cannot_be_read_is_unknown_not_zero() {
    let now = ms("2026-10-30T12:00:00Z");
    let reply = |at: &str| assistant(&format!("msg_{at}"), at, usage(1, 0, 0, 1), false);
    let mut untimed = reply("x");
    untimed.as_object_mut().unwrap().remove("timestamp");
    let mut countless = reply("2026-10-30T11:00:00Z");
    countless["message"]["usage"] = json!({"cache_read_input_tokens": 9});
    let mut untimed_synthetic = untimed.clone();
    untimed_synthetic["message"]["model"] = json!("<synthetic>");
    let mut old_countless = reply("2026-10-28T11:00:00Z");
    old_countless["message"]["usage"] = json!({});
    let cases: Vec<(&str, String, Option<u64>)> = vec![
        ("not JSON", "{\"type\":\"assistant\",\"message\":{\"usage\":".to_owned(), None),
        ("no time", untimed.to_string(), None),
        ("no token counts", countless.to_string(), None),
        // Older than the day: it cannot be in the day's counts, so they are known.
        ("no counts, days old", old_countless.to_string(), Some(2)),
        // Delta review of #28015: an untimed reply Claude Code made up carries no spend.
        ("untimed <synthetic>", untimed_synthetic.to_string(), Some(2)),
    ];
    for (what, bad, want) in cases {
        let home = tempfile::tempdir().unwrap();
        let (source, path) = claude(home.path());
        append(&path, &[reply("2026-10-30T10:00:00Z")]);
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(f, "{bad}").unwrap();
        let stats = Tracker::default().refresh(&source, now, &models()).unwrap();
        assert_eq!(stats.tokens24h, want, "{what}");
    }

    // Codex: a token report without its counts is unknown; a rate-limit update is not one.
    let home = tempfile::tempdir().unwrap();
    let mut env = BTreeMap::new();
    env.insert("CODEX_HOME".to_owned(), home.path().display().to_string());
    let source = Source {
        family: "codex".into(),
        agent_session_id: SID.into(),
        cwd: "/w".into(),
        created_at: now,
        argv: Some(vec!["codex-acp".into()]),
        env,
    };
    let path = home.path().join(format!("sessions/2026/10/30/rollout-x-{SID}.jsonl"));
    let rate = json!({"timestamp": "2026-10-30T11:00:00Z", "type": "event_msg",
        "payload": {"type": "token_count", "info": null, "rate_limits": {}}});
    append(&path, &[rate]);
    assert_eq!(Tracker::default().refresh(&source, now, &models()).unwrap().tokens24h, Some(0));
    // Delta review of #28015: one without a time, too, and a line naming spawn_agent that is
    // no spawn (a tool list), carry nothing to count.
    let untimed_rate = json!({"type": "event_msg",
        "payload": {"type": "token_count", "info": null, "rate_limits": {}}});
    let tools = json!({"type": "response_item", "payload": {"type": "additional_tools",
        "tools": [{"name": "spawn_agent"}]}});
    append(&path, &[untimed_rate, tools]);
    assert_eq!(Tracker::default().refresh(&source, now, &models()).unwrap().tokens24h, Some(0));
    let broken = json!({"timestamp": "2026-10-30T11:01:00Z", "type": "event_msg",
        "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 5}}}});
    append(&path, &[broken]);
    assert_eq!(Tracker::default().refresh(&source, now, &models()).unwrap().tokens24h, None);
}

#[test]
fn the_autocompact_cap_comes_from_the_flag_then_the_env_then_the_settings() {
    use Autocompact::{Capped, Uncapped, Unknown};
    let home = tempfile::tempdir().unwrap();
    let (mut source, _) = claude(home.path());
    let argv = |a: &[&str]| Some(a.iter().map(|s| s.to_string()).collect::<Vec<_>>());
    assert_eq!(autocompact(&source, None), (Capped, Some(200_000)));
    source.argv = argv(&["claude", "--autocompact=auto"]);
    assert_eq!(autocompact(&source, None), (Uncapped, None), "auto is the harness's own default");
    source.argv = argv(&["claude", "--autocompact", "lots"]);
    assert_eq!(autocompact(&source, None), (Unknown, None), "a value it cannot read");
    source.argv = argv(&["claude"]);
    assert_eq!(autocompact(&source, None), (Uncapped, None), "nothing caps it: no settings file");
    std::fs::write(home.path().join("settings.json"), r#"{"theme": "dark"}"#).unwrap();
    assert_eq!(autocompact(&source, None), (Uncapped, None), "nor its settings");
    std::fs::write(home.path().join("settings.json"), "{not json").unwrap();
    assert_eq!(autocompact(&source, None), (Unknown, None), "settings it cannot read");
    std::fs::write(home.path().join("settings.json"), r#"{"autoCompactWindow": 300000}"#).unwrap();
    assert_eq!(autocompact(&source, None), (Capped, Some(300_000)));
    source.env.insert("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE".into(), "40".into());
    assert_eq!(autocompact(&source, Some(1_000_000)), (Capped, Some(400_000)));
    assert_eq!(autocompact(&source, None), (Capped, None), "capped, of a window not known");
    source.env.insert("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE".into(), "most".into());
    assert_eq!(autocompact(&source, None), (Unknown, None));
    source.env.insert("CLAUDE_CODE_AUTO_COMPACT_WINDOW".into(), "1M".into());
    assert_eq!(autocompact(&source, None), (Capped, Some(1_000_000)));
    // Adopted, watched or revived: this daemon never started it, so its flags are not known.
    source.argv = None;
    assert_eq!(autocompact(&source, None), (Unknown, None));

    let mut codex =
        Source { family: "codex".into(), argv: argv(&["codex-acp"]), ..Source::default() };
    codex.env.insert("CODEX_HOME".into(), home.path().join("codex").display().to_string());
    assert_eq!(autocompact(&codex, None), (Uncapped, None), "no config.toml");
    std::fs::create_dir_all(home.path().join("codex")).unwrap();
    std::fs::write(home.path().join("codex/config.toml"), "model = \"gpt-6-astra\"\n").unwrap();
    assert_eq!(autocompact(&codex, None), (Uncapped, None));
    std::fs::write(
        home.path().join("codex/config.toml"),
        "model = \"gpt-6-astra\"\nmodel_auto_compact_token_limit = 180_000 # cap\n[x]\nmodel_auto_compact_token_limit = 1\n",
    )
    .unwrap();
    assert_eq!(autocompact(&codex, None), (Capped, Some(180_000)));
}

/// A first read that starts after the day began, or a backlog it left, cannot say the day's
/// counts: they are unknown (null), never the lower number read so far. Once the reads reach
/// the end and cover the day, they are known.
#[test]
fn counts_are_unknown_until_the_reads_cover_the_day() {
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let now = ms("2026-10-30T12:00:00Z");
    let calls: Vec<Value> = (0..40)
        .map(|i| {
            assistant(
                &format!("msg_{i}"),
                &format!("2026-10-30T11:{i:02}:00Z"),
                usage(1, 0, 0, 1),
                false,
            )
        })
        .collect();
    append(&path, &calls);
    let size = std::fs::metadata(&path).unwrap().len();
    // A first read cut to the newest bytes starts mid-day: it knows the context, not the day's counts.
    let mut cut = Tracker { limits: Some((size / 2, u64::MAX)), ..Tracker::default() };
    let stats = cut.refresh(&source, now, &models()).unwrap();
    assert_eq!(stats.context_tokens, Some(1));
    assert_eq!((stats.tokens24h, stats.compactions24h, stats.subagents24h), (None, None, None));
    assert_eq!((stats.subagents1h, stats.subagents_live, stats.cost_usd24h), (None, None, None));
    // A day later, what it read started before the day: known again.
    let later = cut.refresh(&source, now + DAY_MS, &models()).unwrap();
    assert_eq!(later.tokens24h, Some(0));

    // Reads of a quarter of the file at a time: unknown until the backlog is read.
    let mut stepped = Tracker { limits: Some((u64::MAX, size / 4 + 1)), ..Tracker::default() };
    let mut seen = Vec::new();
    for _ in 0..8 {
        seen.push(stepped.refresh(&source, now, &models()).unwrap().tokens24h);
    }
    // Unknown while a backlog is left, then the whole day, never a partial count.
    let known = seen.iter().position(Option::is_some).unwrap();
    assert!(known >= 3, "{seen:?}");
    assert!(seen[known..].iter().all(|t| *t == Some(80)), "{seen:?}");

    // A transcript it can no longer read leaves the counts unknown.
    std::fs::remove_file(&path).unwrap();
    assert_eq!(stepped.refresh(&source, now, &models()).unwrap().tokens24h, None);
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
    // An argv this daemon never ran: no launcher.
    let source = Source { family: "claude".into(), ..Source::default() };
    assert_eq!(Tracker::default().stats(&source, 0, None).launcher, None);
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

/// A measurement, not a check: reads a real chat's records twice and prints
/// what each read cost. `ACPMUX_USAGE_PROBE=<family>:<agent session id>:<cwd>`, then
/// `cargo test -p acpmux --lib usage_probe -- --ignored --nocapture`.
#[test]
#[ignore]
fn usage_probe() {
    let probe = std::env::var("ACPMUX_USAGE_PROBE").expect("ACPMUX_USAGE_PROBE");
    let mut parts = probe.splitn(3, ':');
    let source = Source {
        family: parts.next().unwrap().into(),
        agent_session_id: parts.next().unwrap().into(),
        cwd: parts.next().unwrap_or("/").into(),
        created_at: crate::store::now_ms(),
        argv: None,
        env: BTreeMap::new(),
    };
    let catalog: crate::catalog::Catalog =
        serde_json::from_str(include_str!("../catalog/models-v1.json")).unwrap();
    let models = Models::from_catalog(&catalog);
    let mut tracker = Tracker::default();
    for read in ["first", "incremental"] {
        let started = std::time::Instant::now();
        let stats = tracker.refresh(&source, crate::store::now_ms(), &models);
        println!("{read}: {:?} {}", started.elapsed(), serde_json::to_string(&stats).unwrap());
    }
}

/// Review of #28015: one decision (`classify`) for every record kind each parse reads, timed
/// or not. A record without a time is classified as the same record with one, but for a
/// count, which it cannot place in the day: `Counted` becomes `Lost`, nothing else changes.
#[test]
fn every_record_kind_is_classified_the_same_timed_or_not() {
    let at = "2026-10-30T11:00:00Z";
    let claude = Harness::Claude { main: true };
    let subagent = Harness::Claude { main: false };
    let mut tail = Tail::default();
    tail.recent.push_back("msg_seen".into());
    tail.last_total = Some(500);
    let reply = |id: &str, model: &str, usage: Value| {
        json!({"type": "assistant", "timestamp": at, "isSidechain": false,
            "message": {"id": id, "model": model, "usage": usage}})
    };
    let full = usage(1, 2, 3, 4);
    let token_count = |info: Value| json!({"timestamp": at, "type": "event_msg", "payload": {"type": "token_count", "info": info}});
    let report = |total: Value, last: Value| {
        token_count(json!({"total_token_usage": {"total_tokens": total}, "last_token_usage": last}))
    };
    let last = json!({"input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 2, "total_tokens": 12});
    let mut sidechain = reply("msg_side", "claude-opus-5-5", full.clone());
    sidechain["isSidechain"] = json!(true);
    // (what, harness, record, its class when timed)
    let cases: Vec<(&str, Harness, Value, &str)> = vec![
        ("claude reply", claude, reply("msg_new", "claude-opus-5-5", full.clone()), "tokens"),
        (
            "claude reply, no token counts",
            claude,
            reply("msg_n", "claude-opus-5-5", json!({"cache_read_input_tokens": 9})),
            "lost",
        ),
        (
            "claude reply, no usage",
            claude,
            json!({"type": "assistant", "timestamp": at, "message": {"id": "m", "model": "claude-opus-5-5"}}),
            "uncountable",
        ),
        ("claude <synthetic>", claude, reply("msg_s", "<synthetic>", full.clone()), "uncountable"),
        ("claude reply, no model", claude, reply("msg_e", "", full.clone()), "uncountable"),
        (
            "claude duplicate message.id",
            claude,
            reply("msg_seen", "claude-opus-5-5", full.clone()),
            "duplicate",
        ),
        (
            "claude duplicate, no token counts",
            claude,
            reply("msg_seen", "claude-opus-5-5", json!({})),
            "duplicate",
        ),
        ("claude sidechain reply", claude, sidechain, "tokens"),
        (
            "claude subagent's reply",
            subagent,
            reply("msg_sub", "claude-opus-5-5", full.clone()),
            "tokens",
        ),
        (
            "claude compaction",
            claude,
            json!({"type": "system", "subtype": "compact_boundary", "timestamp": at}),
            "compaction",
        ),
        (
            "claude subagent's compaction",
            subagent,
            json!({"type": "system", "subtype": "compact_boundary", "timestamp": at}),
            "uncountable",
        ),
        (
            "claude user line",
            claude,
            json!({"type": "user", "timestamp": at, "message": {"content": "assistant"}}),
            "uncountable",
        ),
        ("codex report", Harness::Codex, report(json!(600), last.clone()), "tokens"),
        (
            "codex rate-limit update (info null)",
            Harness::Codex,
            token_count(Value::Null),
            "uncountable",
        ),
        ("codex duplicate total", Harness::Codex, report(json!(500), last.clone()), "duplicate"),
        (
            "codex duplicate total, no last usage",
            Harness::Codex,
            report(json!(500), json!({})),
            "duplicate",
        ),
        (
            "codex report, no total",
            Harness::Codex,
            token_count(json!({"last_token_usage": last})),
            "lost",
        ),
        ("codex report, no last usage", Harness::Codex, report(json!(700), json!({})), "lost"),
        (
            "codex compaction",
            Harness::Codex,
            json!({"timestamp": at, "type": "compacted", "payload": {"message": "s"}}),
            "compaction",
        ),
        (
            "codex spawn_agent call",
            Harness::Codex,
            json!({"timestamp": at, "type": "response_item", "payload": {"type": "function_call", "name": "spawn_agent"}}),
            "spawn",
        ),
        (
            "codex spawn_agent custom call",
            Harness::Codex,
            json!({"timestamp": at, "type": "response_item", "payload": {"type": "custom_tool_call", "name": "spawn_agent"}}),
            "spawn",
        ),
        (
            "codex tool list naming spawn_agent",
            Harness::Codex,
            json!({"timestamp": at, "type": "response_item", "payload": {"type": "additional_tools", "tools": [{"name": "spawn_agent"}]}}),
            "uncountable",
        ),
        (
            // Review of #28015 at aec8d5f7 (1): a turn context goes through classify; untimed,
            // it names no model (the untimed run below checks that).
            "codex turn context",
            Harness::Codex,
            json!({"timestamp": at, "type": "turn_context", "payload": {"model": "gpt-6-astra"}}),
            "model",
        ),
        (
            "codex turn context, no model",
            Harness::Codex,
            json!({"timestamp": at, "type": "turn_context", "payload": {}}),
            "uncountable",
        ),
    ];
    let label = |class: &Class| match class {
        Class::Model { .. } => "model",
        Class::Uncountable => "uncountable",
        Class::Duplicate => "duplicate",
        Class::Lost { .. } => "lost",
        Class::Counted { counts: Counts::Compaction, .. } => "compaction",
        Class::Counted { counts: Counts::Spawn, .. } => "spawn",
        Class::Counted { counts: Counts::Tokens(_), .. } => "tokens",
    };
    for (what, harness, record, want) in cases {
        let timed = classify(harness, record.to_string().as_bytes(), &tail);
        assert_eq!(label(&timed), want, "{what}");
        let mut untimed = record.clone();
        untimed.as_object_mut().unwrap().remove("timestamp");
        let untimed = classify(harness, untimed.to_string().as_bytes(), &tail);
        // Without a time: what would count is lost (keeping what tells a repeat of it), a turn
        // context names no model, and the rest is as it was.
        let expected = match timed {
            Class::Counted { counts, .. } => Class::Lost { at: None, key: counts.key() },
            Class::Lost { key, .. } => Class::Lost { at: None, key },
            Class::Model { .. } => Class::Uncountable,
            other => other,
        };
        assert_eq!(untimed, expected, "{what}, without a time");
    }
    // Not JSON: lost, at the time it names when it names one.
    let cut = br#"{"type":"assistant","timestamp":"2026-10-30T11:00:00Z","message":{"usage":"#;
    assert_eq!(classify(claude, cut, &tail), Class::Lost { at: Some(ms(at)), key: Key::None });
    assert_eq!(
        classify(Harness::Codex, b"{\"type\":\"compacted\"", &tail),
        Class::Lost { at: None, key: Key::None }
    );
    // What a counted reply counts: the chat's own call is its context; a subagent's is not.
    let Class::Counted { counts: Counts::Tokens(t), .. } = classify(
        claude,
        reply("msg_x", "claude-opus-5-5", full.clone()).to_string().as_bytes(),
        &tail,
    ) else {
        panic!()
    };
    // usage(1, 2, 3, 4): input 1, cache write 2, cache read 3, output 4.
    assert_eq!((t.total, t.context, t.key), (10, Some(6), Key::Message("msg_x".into())));
    let Class::Counted { counts: Counts::Tokens(t), .. } =
        classify(subagent, reply("msg_y", "claude-opus-5-5", full).to_string().as_bytes(), &tail)
    else {
        panic!()
    };
    assert_eq!(t.context, None);
    // Codex: cached input is inside input_tokens; the context is all of it.
    let Class::Counted { counts: Counts::Tokens(t), .. } =
        classify(Harness::Codex, report(json!(600), last).to_string().as_bytes(), &tail)
    else {
        panic!()
    };
    assert_eq!((t.input, t.cache_read, t.total, t.context), (6, 4, 12, Some(10)));
    // Review of #28015 at aec8d5f7 (3): a report whose cached count is above its input is priced
    // as it says (input at 0, every cached token at the cache price), not clamped.
    let odd = json!({"input_tokens": 10, "cached_input_tokens": 50, "output_tokens": 10, "total_tokens": 20});
    let Class::Counted { counts: Counts::Tokens(t), .. } =
        classify(Harness::Codex, report(json!(800), odd).to_string().as_bytes(), &tail)
    else {
        panic!()
    };
    assert_eq!((t.input, t.cache_read, t.total), (0, 50, 20));
    let p = Prices { input: 2.0, output: 10.0, cache_read: 0.5, cache_write: 2.0 };
    assert_eq!(t.cost(&p), (50.0 * 0.5 + 10.0 * 10.0) / 1e6);
}

/// Review of #28015 at aec8d5f7 (1, 2, 6, and the escaped kind), on the tracker:
/// - an untimed turn context does not set the model later Codex calls are priced at;
/// - a message whose first line is lost is not counted from a later line of it;
/// - an untimed repeat of a call older than the day is its duplicate, not lost;
/// - a counted kind written escaped makes the day unknown, never 0.
#[test]
fn the_tracker_applies_every_classification() {
    let now = ms("2026-10-30T12:00:00Z");
    let codex = |home: &Path| {
        let mut env = BTreeMap::new();
        env.insert("CODEX_HOME".to_owned(), home.display().to_string());
        let source = Source {
            family: "codex".into(),
            agent_session_id: SID.into(),
            cwd: "/w".into(),
            created_at: now,
            argv: Some(vec!["codex-acp".into()]),
            env,
        };
        (source, home.join(format!("sessions/2026/10/30/rollout-x-{SID}.jsonl")))
    };
    let report = |at: &str, total: u64| {
        json!({"timestamp": at, "type": "event_msg", "payload": {"type": "token_count", "info": {
            "total_token_usage": {"total_tokens": total},
            "last_token_usage": {"input_tokens": 1_000_000, "output_tokens": 0, "total_tokens": 1_000_000}}}})
    };
    // (1) A timed turn context prices the call after it at gpt-6-astra ($2/M input); an untimed
    // one after it does not move the model to one without a price.
    let home = tempfile::tempdir().unwrap();
    let (source, path) = codex(home.path());
    append(
        &path,
        &[
            json!({"timestamp": "2026-10-30T10:00:00Z", "type": "turn_context", "payload": {"model": "gpt-6-astra"}}),
            json!({"type": "turn_context", "payload": {"model": "no-such-model"}}),
            report("2026-10-30T11:00:00Z", 1_000_000),
        ],
    );
    let stats = Tracker::default().refresh(&source, now, &models()).unwrap();
    assert_eq!((stats.tokens24h, stats.cost_usd24h), (Some(1_000_000), Some(2.0)));

    // (2) The first line of msg_1 has no output count: lost (the day unknown), and the full line
    // of msg_1 after it is that message's, not a second call.
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let mut partial = assistant("msg_1", "2026-10-30T11:00:00Z", usage(5, 0, 0, 5), false);
    partial["message"]["usage"].as_object_mut().unwrap().remove("output_tokens");
    append(&path, &[partial, assistant("msg_1", "2026-10-30T11:00:01Z", usage(5, 0, 0, 5), false)]);
    let mut tracker = Tracker::default();
    assert_eq!(tracker.refresh(&source, now, &models()).unwrap().tokens24h, None);
    // A day after the lost line, the day's count is known: msg_1 never counted in it.
    let later = tracker.refresh(&source, now + DAY_MS, &models()).unwrap();
    assert_eq!(later.tokens24h, Some(0));

    // (6) An untimed repeat of a call older than the day: its duplicate, so the day is known.
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let old = assistant("msg_old", "2026-10-29T11:00:00Z", usage(1, 0, 0, 1), false);
    let mut repeat = old.clone();
    repeat.as_object_mut().unwrap().remove("timestamp");
    append(&path, &[old, repeat]);
    let stats = Tracker::default().refresh(&source, now, &models()).unwrap();
    assert_eq!((stats.tokens24h, stats.context_tokens), (Some(0), Some(1)));

    // An escaped kind the byte pre-filter passes over: unknown, not 0. One old or not counted
    // (a user line with an escape) changes nothing.
    for (harness, line, want) in [
        (
            "claude",
            r#"{"type":"\u0061ssistant","timestamp":"2026-10-30T11:00:00Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            None,
        ),
        (
            "claude",
            r#"{"type":"\u0061ssistant","timestamp":"2026-10-28T11:00:00Z","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            Some(0),
        ),
        (
            "claude",
            r#"{"type":"user","timestamp":"2026-10-30T11:00:00Z","message":{"content":"\u001b[31mred"}}"#,
            Some(0),
        ),
        (
            "codex",
            r#"{"timestamp":"2026-10-30T11:00:00Z","type":"event_msg","payload":{"type":"token_\u0063ount","info":{"total_token_usage":{"total_tokens":10},"last_token_usage":{"input_tokens":8,"output_tokens":2}}}}"#,
            None,
        ),
        (
            "codex",
            r#"{"timestamp":"2026-10-30T11:00:00Z","type":"event_msg","payload":{"type":"agent_message","message":"\u00e9"}}"#,
            Some(0),
        ),
    ] {
        let home = tempfile::tempdir().unwrap();
        let (source, path) =
            if harness == "claude" { claude(home.path()) } else { codex(home.path()) };
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, format!("{line}\n")).unwrap();
        let stats = Tracker::default().refresh(&source, now, &models()).unwrap();
        assert_eq!(stats.tokens24h, want, "{line}");
    }
}

/// Review of #28015 at 800ce2b4: an untimed repeat of a record already counted (a Claude
/// message's other line, a Codex total said again) is a duplicate, not lost.
#[test]
fn an_untimed_repeat_of_a_counted_record_is_not_lost() {
    let now = ms("2026-10-30T12:00:00Z");
    let home = tempfile::tempdir().unwrap();
    let (source, path) = claude(home.path());
    let first = assistant("msg_1", "2026-10-30T11:00:00Z", usage(1, 0, 0, 1), false);
    let mut repeat = first.clone();
    repeat.as_object_mut().unwrap().remove("timestamp");
    append(&path, &[first, repeat]);
    assert_eq!(Tracker::default().refresh(&source, now, &models()).unwrap().tokens24h, Some(2));

    let home = tempfile::tempdir().unwrap();
    let mut env = BTreeMap::new();
    env.insert("CODEX_HOME".to_owned(), home.path().display().to_string());
    let source = Source {
        family: "codex".into(),
        agent_session_id: SID.into(),
        cwd: "/w".into(),
        created_at: now,
        argv: Some(vec!["codex-acp".into()]),
        env,
    };
    let path = home.path().join(format!("sessions/2026/10/30/rollout-x-{SID}.jsonl"));
    let report = json!({"timestamp": "2026-10-30T11:00:00Z", "type": "event_msg", "payload": {
        "type": "token_count", "info": {"total_token_usage": {"total_tokens": 10},
            "last_token_usage": {"input_tokens": 8, "output_tokens": 2, "total_tokens": 10}}}});
    let mut again = report.clone();
    again.as_object_mut().unwrap().remove("timestamp");
    append(&path, &[report, again]);
    assert_eq!(Tracker::default().refresh(&source, now, &models()).unwrap().tokens24h, Some(10));
}
