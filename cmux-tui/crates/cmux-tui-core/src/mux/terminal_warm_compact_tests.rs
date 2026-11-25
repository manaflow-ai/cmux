use super::*;
use serde_json::json;

fn line(value: Value) -> String {
    value.to_string()
}

fn user(at: &str) -> String {
    line(json!({"type":"user","timestamp":at,"message":{"role":"user","content":"hi"}}))
}

fn assistant(at: &str, id: &str, read: u64, write: u64, one_hour: bool) -> String {
    let (h1, m5) = if one_hour { (write, 0) } else { (0, write) };
    line(json!({
        "type":"assistant","timestamp":at,"uuid":format!("u-{id}-{at}"),
        "message":{"id":id,"role":"assistant","usage":{
            "input_tokens":3,"cache_read_input_tokens":read,"cache_creation_input_tokens":write,
            "cache_creation":{"ephemeral_1h_input_tokens":h1,"ephemeral_5m_input_tokens":m5},
            "output_tokens":50}}
    }))
}

fn ms(at: &str) -> u64 {
    parse_ms(at).unwrap()
}

#[test]
fn the_last_request_starts_at_the_line_before_its_first_assistant_line() {
    let text = [
        user("2026-11-25T10:00:00.000Z"),
        assistant("2026-11-25T10:00:20.000Z", "msg_1", 50_000, 2_000, true),
        user("2026-11-25T10:01:00.000Z"),
        assistant("2026-11-25T10:01:40.000Z", "msg_2", 80_000, 0, false),
        assistant("2026-11-25T10:01:45.000Z", "msg_2", 80_000, 0, false),
    ]
    .join("\n");
    let request = last_request(&text).unwrap();
    assert_eq!(request.key, "msg_2");
    assert_eq!(request.started_ms, ms("2026-11-25T10:01:00.000Z"));
    assert_eq!(request.context, 3 + 80_000);
    // The last request wrote neither tier: the hour tier an earlier one wrote still holds.
    assert_eq!(request.ttl_ms, ONE_HOUR_MS);
    assert_eq!(fire_at_ms(&request), request.started_ms + ONE_HOUR_MS - LONG_LEAD_MS);
}

#[test]
fn a_five_minute_cache_compacts_thirty_seconds_before_it_lapses() {
    let text = [
        user("2026-11-25T10:00:00.000Z"),
        assistant("2026-11-25T10:00:20.000Z", "msg_1", 90_000, 2_000, false),
    ]
    .join("\n");
    let request = last_request(&text).unwrap();
    assert_eq!(request.ttl_ms, FIVE_MINUTES_MS);
    assert_eq!(fire_at_ms(&request), ms("2026-11-25T10:04:30.000Z"));
}

#[test]
fn a_compaction_after_the_last_request_arms_nothing() {
    let text = [
        user("2026-11-25T10:00:00.000Z"),
        assistant("2026-11-25T10:00:20.000Z", "msg_1", 90_000, 2_000, true),
        line(json!({"type":"system","subtype":"compact_boundary","timestamp":"2026-11-25T10:03:00.000Z"})),
        user("2026-11-25T10:03:01.000Z"),
    ]
    .join("\n");
    assert_eq!(last_request(&text), None);
}

#[test]
fn sidechain_and_empty_usage_lines_are_not_the_last_request() {
    let mut synthetic = json!({"type":"assistant","timestamp":"2026-11-25T10:02:00.000Z",
        "message":{"id":"msg_x","usage":{"input_tokens":0,"output_tokens":0}}});
    let text = [
        user("2026-11-25T10:00:00.000Z"),
        assistant("2026-11-25T10:00:20.000Z", "msg_1", 90_000, 2_000, true),
        line({
            let mut side: Value =
                serde_json::from_str(&assistant("2026-11-25T10:01:00.000Z", "msg_s", 5, 5, true))
                    .unwrap();
            side["isSidechain"] = json!(true);
            side
        }),
        line(synthetic.take()),
        "not json".to_owned(),
    ]
    .join("\n");
    assert_eq!(last_request(&text).unwrap().key, "msg_1");
}

#[test]
fn the_chat_settings_decide_the_terminal_bar() {
    let none = |_: &str| None;
    assert_eq!(min_tokens(&json!({}), none), Some(DEFAULT_MIN_TOKENS));
    assert_eq!(min_tokens(&json!({"agents":{"cacheCompact":{"enabled":false}}}), none), None);
    assert_eq!(min_tokens(&json!({"agents.cacheCompact.enabled":false}), none), None);
    assert_eq!(
        min_tokens(&json!({"agents":{"cacheCompact":{"minContextTokens":80_000}}}), none),
        Some(80_000)
    );
    assert_eq!(
        min_tokens(&json!({"agents":{"cacheCompact":{"minContextTokens":1}}}), none),
        Some(MIN_TOKENS_RANGE.0)
    );
    let env = |var: &str| match var {
        ENV_ENABLED => Some("1".to_owned()),
        ENV_MIN_TOKENS => Some("120000".to_owned()),
        _ => None,
    };
    assert_eq!(
        min_tokens(&json!({"agents":{"cacheCompact":{"enabled":false}}}), env),
        Some(120_000)
    );
    let off = |var: &str| (var == ENV_ENABLED).then(|| "off".to_owned());
    assert_eq!(min_tokens(&json!({}), off), None);
}

#[test]
fn only_an_empty_input_box_reads_empty() {
    let rule = "─".repeat(40);
    let empty = format!("● Done.\n\n{rule}\n❯ \n{rule}\n  ? for shortcuts\n");
    assert_eq!(input_box_text(&empty).as_deref(), Some(""));
    let draft = format!("● Done.\n\n{rule}\n❯ half a thought\n  and more\n{rule}\n");
    assert_eq!(input_box_text(&draft).as_deref(), Some("half a thought and more"));
    assert_eq!(input_box_text("$ ls\nfoo\n$ "), None);
}

#[test]
fn a_tail_read_drops_its_cut_first_line() {
    let dir = std::env::temp_dir().join(format!("twc-tail-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("t.jsonl");
    let filler = "x".repeat(TAIL_BYTES as usize);
    let text = [
        filler,
        user("2026-11-25T10:00:00.000Z"),
        assistant("2026-11-25T10:00:20.000Z", "msg_1", 90_000, 2_000, true),
    ]
    .join("\n");
    std::fs::write(&path, text).unwrap();
    let tail = read_tail(&path).unwrap();
    assert!(!tail.starts_with('x'));
    assert_eq!(last_request(&tail).unwrap().key, "msg_1");
    std::fs::remove_file(&path).unwrap();
    std::fs::remove_dir(&dir).unwrap();
}

/// The duress replay: over every transcript under `TWC_REPLAY_DIR` (Claude Code's
/// `~/.claude/projects`), each idle stretch after a request at or over the default bar that
/// outlived its cache (a cold wake: the next request rewrote the context), and whether this
/// module's timer ([`last_request`], [`fire_at_ms`]) would have compacted first.
/// `TWC_REPLAY_DIR=~/.claude/projects cargo test -p cmux-tui-core --lib replay_transcripts -- --ignored --nocapture`
#[test]
#[ignore]
fn replay_transcripts() {
    let Ok(root) = std::env::var("TWC_REPLAY_DIR") else { return };
    let since_ms =
        std::env::var("TWC_REPLAY_SINCE_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut files = Vec::new();
    let mut stack = vec![PathBuf::from(root)];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() && path.file_name().is_some_and(|n| n != "subagents") {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "jsonl") {
                files.push(path);
            }
        }
    }
    let (mut sessions, mut cold, mut caught, mut cold_written, mut caught_written) =
        (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut caught_context = 0u64;
    for file in files {
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        let lines: Vec<&str> = text.lines().collect();
        // Each request's last line, in order.
        let mut ends: Vec<(usize, String)> = Vec::new();
        for (index, line) in lines.iter().enumerate() {
            let Ok(entry) = serde_json::from_str::<Value>(line) else { continue };
            if entry.get("type").and_then(Value::as_str) != Some("assistant")
                || entry.get("isSidechain").and_then(Value::as_bool) == Some(true)
                || entry.pointer("/message/usage").is_none()
            {
                continue;
            }
            let id = entry.pointer("/message/id").and_then(Value::as_str).unwrap_or("").to_owned();
            match ends.last_mut() {
                Some((end, last)) if *last == id && !id.is_empty() => *end = index,
                _ => ends.push((index, id)),
            }
        }
        if ends.len() < 2 {
            continue;
        }
        sessions += 1;
        let window = |end: usize| lines[end.saturating_sub(600)..=end].join("\n");
        for pair in ends.windows(2) {
            let (Some(before), Some(after)) =
                (last_request(&window(pair[0].0)), last_request(&window(pair[1].0)))
            else {
                continue;
            };
            if before.started_ms < since_ms || before.context < DEFAULT_MIN_TOKENS {
                continue;
            }
            let written = serde_json::from_str::<Value>(lines[pair[1].0])
                .ok()
                .and_then(|e| e.pointer("/message/usage/cache_creation_input_tokens")?.as_u64())
                .unwrap_or(0);
            if after.started_ms <= before.started_ms + before.ttl_ms {
                continue;
            }
            cold += 1;
            cold_written += written;
            if after.started_ms > fire_at_ms(&before) {
                caught += 1;
                caught_written += written;
                caught_context += before.context;
            }
        }
    }
    println!(
        "replay: sessions {sessions}, cold wakes >= {DEFAULT_MIN_TOKENS} {cold} writing {cold_written}; \
         the timer fires before {caught} of them (writing {caught_written}, mean context {})",
        if caught > 0 { caught_context / caught } else { 0 }
    );
}

#[test]
fn a_later_five_minute_write_drops_the_hour_tier() {
    let text = [
        user("2026-11-25T10:00:00.000Z"),
        assistant("2026-11-25T10:00:20.000Z", "msg_1", 50_000, 2_000, true),
        user("2026-11-25T10:01:00.000Z"),
        assistant("2026-11-25T10:01:40.000Z", "msg_2", 80_000, 1_000, false),
    ]
    .join("\n");
    let request = last_request(&text).unwrap();
    assert_eq!(request.ttl_ms, FIVE_MINUTES_MS);
    assert_eq!(fire_at_ms(&request), ms("2026-11-25T10:05:30.000Z"));
}
