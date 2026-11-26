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

/// A terminal for the firing tests: Claude Code's input box, a clock, and the bytes written.
struct Fake {
    now_ms: std::cell::Cell<u64>,
    idle: std::cell::Cell<bool>,
    input: std::cell::Cell<Option<u64>>,
    draft: std::cell::RefCell<String>,
    request: LastRequest,
    written: std::cell::RefCell<Vec<u8>>,
}

const T0: u64 = 1_800_000_000_000;

impl Fake {
    fn new() -> Self {
        Fake {
            now_ms: T0.into(),
            idle: true.into(),
            input: Some(7).into(),
            draft: String::new().into(),
            request: LastRequest {
                key: "msg_1".into(),
                started_ms: T0 - FIVE_MINUTES_MS + LEAD_MS,
                context: 90_000,
                ttl_ms: FIVE_MINUTES_MS,
            },
            written: Vec::new().into(),
        }
    }
}

impl Target for &Fake {
    fn now_ms(&self) -> u64 {
        self.now_ms.get()
    }
    fn min_tokens(&self) -> Option<u64> {
        Some(DEFAULT_MIN_TOKENS)
    }
    fn idle(&self) -> bool {
        self.idle.get()
    }
    fn last_input(&self) -> Option<u64> {
        self.input.get()
    }
    fn screen(&self) -> Option<String> {
        let rule = "─".repeat(40);
        Some(format!("● Done.\n\n{rule}\n❯ {}\n{rule}\n  ? for shortcuts\n", self.draft.borrow()))
    }
    fn last_request(&self) -> Option<LastRequest> {
        Some(self.request.clone())
    }
    /// Typed bytes land in the box as a terminal would echo them; Return clears it.
    fn write(&self, bytes: &[u8]) -> bool {
        self.written.borrow_mut().extend_from_slice(bytes);
        let mut draft = self.draft.borrow_mut();
        for byte in bytes {
            match byte {
                b'\r' => draft.clear(),
                0x7f => {
                    draft.pop();
                }
                _ => draft.push(*byte as char),
            }
        }
        true
    }
}

/// An entry armed the way `arm` arms it for `fake`'s request, due at `due`.
fn armed_for(fake: &Fake, due: Instant) -> Armed {
    Armed {
        due,
        stage: Stage::Type,
        expires_ms: fake.request.started_ms + fake.request.ttl_ms,
        session: Some("s".into()),
        transcript: PathBuf::new(),
        request: fake.request.key.clone(),
        input: fake.input.get(),
    }
}

fn terminal(n: usize) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{n:032x}")).unwrap()
}

fn written(fake: &Fake) -> String {
    String::from_utf8_lossy(&fake.written.borrow()).into_owned()
}

#[test]
fn an_on_time_fire_types_compact_then_its_return_after_the_gap() {
    let fake = Fake::new();
    let start = Instant::now();
    let mut timer = Timer::default();
    timer.turn_ended(&terminal(1), Some(armed_for(&fake, start)));
    timer.fire_due(start, |_, _| Some(&fake));
    assert_eq!(written(&fake), "/compact");
    let submit_at = timer.next_due().unwrap();
    assert!(submit_at >= start + SUBMIT_GAP);
    // Not yet due: nothing more.
    timer.fire_due(start, |_, _| Some(&fake));
    assert_eq!(written(&fake), "/compact");
    timer.fire_due(submit_at, |_, _| Some(&fake));
    assert_eq!(written(&fake), "/compact\r");
    assert!(timer.next_due().is_none());
    assert!(timer.already_compacted(&terminal(1), "msg_1"));
}

#[test]
fn a_late_dispatch_never_types_into_a_cold_cache() {
    // The timer thread got to the entry late (a burst, a clock jump, a sleep): the cache has
    // less than the typing margin left, or has lapsed.
    for late_ms in [LEAD_MS - TYPE_MARGIN_MS + 1, LEAD_MS, LEAD_MS + 60_000] {
        let fake = Fake::new();
        fake.now_ms.set(T0 + late_ms);
        let start = Instant::now();
        let mut timer = Timer::default();
        timer.turn_ended(&terminal(1), Some(armed_for(&fake, start)));
        timer.fire_due(start, |_, _| Some(&fake));
        assert_eq!(written(&fake), "", "late by {late_ms} ms");
        assert!(timer.next_due().is_none());
    }
}

#[test]
fn a_cache_lapsing_in_the_gap_takes_back_its_compact() {
    let fake = Fake::new();
    let start = Instant::now();
    let mut timer = Timer::default();
    timer.turn_ended(&terminal(1), Some(armed_for(&fake, start)));
    timer.fire_due(start, |_, _| Some(&fake));
    // The Return's dispatch comes late, inside the submit margin.
    fake.now_ms.set(T0 + LEAD_MS - SUBMIT_MARGIN_MS + 1);
    timer.fire_due(timer.next_due().unwrap(), |_, _| Some(&fake));
    assert!(!written(&fake).contains('\r'));
    assert_eq!(fake.draft.borrow().as_str(), "", "its own /compact is erased");
    assert!(!timer.already_compacted(&terminal(1), "msg_1"));
}

#[test]
fn a_burst_of_due_terminals_all_type_in_one_pass_and_none_compacts_cold() {
    // 200 five-minute timers due together: more than the 30 s lead at 250 ms each.
    let fakes: Vec<Fake> = (0..200).map(|_| Fake::new()).collect();
    let start = Instant::now();
    let mut timer = Timer::default();
    for (n, fake) in fakes.iter().enumerate() {
        timer.turn_ended(&terminal(n), Some(armed_for(fake, start)));
    }
    let index = |t: &TerminalPublicId| (0..fakes.len()).find(|n| &terminal(*n) == t).unwrap();
    let began = Instant::now();
    timer.fire_due(start, |t, _| Some(&fakes[index(t)]));
    assert!(began.elapsed() < SUBMIT_GAP, "one pass never waits on a gap");
    assert!(fakes.iter().all(|fake| written(fake) == "/compact"));
    // Each Return waits its own full gap after its own `/compact`.
    let last_submit = timer.armed.values().map(|entry| entry.due).max().unwrap();
    assert!(timer.armed.values().all(|entry| entry.stage == Stage::Submit));
    timer.fire_due(last_submit, |t, _| Some(&fakes[index(t)]));
    assert!(fakes.iter().all(|fake| written(fake) == "/compact\r"));
}

#[test]
fn a_draft_or_new_input_or_a_busy_agent_stops_it() {
    // A half-typed prompt in the box: nothing is typed.
    let fake = Fake::new();
    *fake.draft.borrow_mut() = "half a thought".into();
    let start = Instant::now();
    let mut timer = Timer::default();
    timer.turn_ended(&terminal(1), Some(armed_for(&fake, start)));
    timer.fire_due(start, |_, _| Some(&fake));
    assert_eq!(written(&fake), "");

    // Someone typed in the gap: no Return, and their input is left alone.
    let fake = Fake::new();
    let mut timer = Timer::default();
    timer.turn_ended(&terminal(1), Some(armed_for(&fake, start)));
    timer.fire_due(start, |_, _| Some(&fake));
    fake.input.set(Some(8));
    fake.draft.borrow_mut().push('x');
    timer.fire_due(timer.next_due().unwrap(), |_, _| Some(&fake));
    assert_eq!(written(&fake), "/compact");
    assert_eq!(fake.draft.borrow().as_str(), "/compactx");

    // The agent left idle in the gap: no Return, its own /compact erased.
    let fake = Fake::new();
    let mut timer = Timer::default();
    timer.turn_ended(&terminal(1), Some(armed_for(&fake, start)));
    timer.fire_due(start, |_, _| Some(&fake));
    fake.idle.set(false);
    timer.fire_due(timer.next_due().unwrap(), |_, _| Some(&fake));
    assert!(!written(&fake).contains('\r'));
    assert_eq!(fake.draft.borrow().as_str(), "");
}

#[test]
fn the_compacted_record_follows_the_terminal() {
    let fake = Fake::new();
    let start = Instant::now();
    let mut timer = Timer::default();
    let mut compact = |timer: &mut Timer, n: usize| {
        timer.turn_ended(&terminal(n), Some(armed_for(&fake, start)));
        timer.fire_due(start, |_, _| Some(&fake));
        timer.fire_due(timer.next_due().unwrap(), |_, _| Some(&fake));
        assert!(timer.already_compacted(&terminal(n), "msg_1"));
    };
    // A turn or session start or end, or the terminal's removal, forgets it.
    compact(&mut timer, 1);
    timer.forget(&terminal(1));
    assert!(timer.compacted.is_empty() && timer.armed.is_empty());
    // A later request supersedes it.
    compact(&mut timer, 2);
    let mut later = armed_for(&fake, start + Duration::from_secs(60));
    later.request = "msg_2".into();
    timer.turn_ended(&terminal(2), Some(later));
    assert!(timer.compacted.is_empty());
    assert_eq!(timer.armed.len(), 1);
    // The same request re-armed (a duplicate Stop) keeps it, so it never compacts twice.
    timer.forget(&terminal(2));
    compact(&mut timer, 3);
    timer.turn_ended(&terminal(3), Some(armed_for(&fake, start)));
    assert!(timer.already_compacted(&terminal(3), "msg_1"));
}
