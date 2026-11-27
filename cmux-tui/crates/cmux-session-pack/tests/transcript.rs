//! A Claude Code transcript gets turns, an outline and a digest from the shape of its lines, and
//! an acpmux log packs to the same chunks and turns as before transcripts had any.

use cmux_session_pack::{Manifest, Pack, Params, RangeId, Store, TURN_RULE, pack};
use std::fmt::Write as _;

struct Rng(u64);

impl Rng {
    fn below(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % n
    }
    /// Between `min` and `min + spread` letters and spaces.
    fn words(&mut self, min: u64, spread: u64) -> String {
        let n = min + self.below(spread.max(1));
        (0..n)
            .map(|_| match self.below(27) {
                26 => ' ',
                c => char::from(b'a' + c as u8),
            })
            .collect()
    }
}

/// An acpmux log: turns, prompts, tool calls with long results, replies, and the harness's raw
/// lines (one of them a Claude Code prompt line, which is a record's payload here, not a turn).
fn acpmux_log(turns: usize) -> Vec<u8> {
    let mut out = String::new();
    let mut r = Rng(0x2545_f491_4f6c_dd1d);
    let (mut seq, mut at) = (0u64, 1_795_000_000_000u64);
    let mut rec = |out: &mut String, dir: &str, kind: &str, msg: &str| {
        seq += 1;
        at += 37;
        writeln!(out, r#"{{"seq":{seq},"at":{at},"dir":"{dir}","kind":"{kind}","msg":{msg}}}"#)
            .unwrap();
    };
    for t in 0..turns {
        let prompt = r.words(20, 600);
        rec(&mut out, "mux", "turn_started", &format!(r#"{{"promptLine":"turn {t}"}}"#));
        rec(&mut out, "mux", "user_message", &format!(r#"{{"text":"{prompt}"}}"#));
        rec(
            &mut out,
            "in",
            "claude.user",
            &format!(
                r#"{{"line":{{"type":"user","message":{{"role":"user","content":"{prompt}"}},"timestamp":"2026-11-23T09:42:00.000Z"}}}}"#
            ),
        );
        for c in 0..r.below(4) {
            let result = r.words(0, 3000);
            rec(
                &mut out,
                "in",
                "tool_call",
                &format!(
                    r#"{{"params":{{"update":{{"rawInput":{{"command":"make {c}"}},"status":"in_progress","toolCallId":"t{t}.{c}"}}}}}}"#
                ),
            );
            rec(
                &mut out,
                "in",
                "tool_call_update",
                &format!(
                    r#"{{"params":{{"update":{{"content":[{{"content":{{"text":"{result}","type":"text"}},"type":"content"}}],"status":"completed","toolCallId":"t{t}.{c}"}}}}}}"#
                ),
            );
        }
        let reply = r.words(0, 400);
        rec(
            &mut out,
            "in",
            "agent_message_chunk",
            &format!(r#"{{"params":{{"update":{{"content":{{"text":"{reply}"}}}}}}}}"#),
        );
        rec(&mut out, "mux", "turn_result", r#"{"status":"ok","modelCalls":2}"#);
    }
    out.into_bytes()
}

/// A Claude Code transcript as Claude Code writes one, with every kind of user record it holds:
/// the log, the lines a turn starts at, and what each turn asked.
struct Transcript {
    bytes: Vec<u8>,
    starts: Vec<u64>,
    asked: Vec<String>,
    /// When each turn was asked, ms since 1970.
    at: Vec<u64>,
}

fn transcript(turns: usize) -> Transcript {
    let mut r = Rng(0x9e37_79b9_7f4a_7c15);
    let (mut lines, mut starts, mut asked) = (Vec::<String>::new(), Vec::new(), Vec::new());
    let mut ms = 1_795_426_920_000u64;
    let mut at_ms = Vec::new();
    let mut stamp = |step: u64| {
        ms += step;
        if step == 60_000 {
            at_ms.push(ms);
        }
        let (s, frac) = (ms / 1000, ms % 1000);
        let (day, sec) = (s / 86_400, s % 86_400);
        // 2026-11-23 is day 20_780 since 1970; the fixture stays within that month.
        format!(
            "2026-11-{:02}T{:02}:{:02}:{:02}.{frac:03}Z",
            23 + day - 20_780,
            sec / 3600,
            sec / 60 % 60,
            sec % 60
        )
    };
    let common = r#""parentUuid":"p","isSidechain":false,"userType":"external","cwd":"/w","sessionId":"s","version":"2.1.0","gitBranch":"main""#;
    lines.push(r#"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-23T09:41:59.000Z","sessionId":"s"}"#.into());
    for t in 0..turns {
        // A person's prompt: short, long enough to be a blob, or text blocks with an image.
        let text = match t % 3 {
            0 => format!("turn {t}: {}", r.words(5, 100)),
            1 => format!("turn {t}: {}", r.words(500, 2000)),
            _ => format!("turn {t}: {}", r.words(5, 50)),
        };
        let content = if t % 3 == 2 {
            format!(
                r#"[{{"type":"text","text":"{text}"}},{{"type":"image","source":{{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}}}]"#
            )
        } else {
            format!(r#""{text}""#)
        };
        starts.push(lines.len() as u64);
        let at = stamp(60_000);
        asked.push(text.clone());
        lines.push(format!(r#"{{{common},"promptId":"q{t}","type":"user","message":{{"role":"user","content":{content}}},"uuid":"u{t}","timestamp":"{at}","permissionMode":"default"}}"#));
        lines.push(format!(
            r#"{{"type":"last-prompt","lastPrompt":"{}","leafUuid":"u{t}","sessionId":"s"}}"#,
            &text[..text.len().min(40)]
        ));
        if t % 5 == 1 {
            let at = stamp(1);
            lines.push(format!(r#"{{{common},"type":"user","message":{{"role":"user","content":"<system-reminder>{}</system-reminder>"}},"isMeta":true,"uuid":"m{t}","timestamp":"{at}"}}"#, r.words(10, 800)));
        }
        lines.push(format!(r#"{{"type":"attachment","attachment":{{"type":"hook_success","content":"{}"}},"timestamp":"{}"}}"#, r.words(0, 200), stamp(1)));
        for c in 0..r.below(5) {
            let at = stamp(900);
            lines.push(format!(r#"{{{common},"message":{{"model":"claude","id":"msg{t}.{c}","type":"message","role":"assistant","content":[{{"type":"thinking","thinking":"{}","signature":"sig"}}]}},"type":"assistant","uuid":"a{t}.{c}","timestamp":"{at}"}}"#, r.words(0, 900)));
            lines.push(format!(r#"{{{common},"message":{{"model":"claude","id":"msg{t}.{c}","type":"message","role":"assistant","content":[{{"type":"tool_use","id":"tu{t}.{c}","name":"Bash","input":{{"command":"make {c}","description":"build"}}}}]}},"type":"assistant","uuid":"b{t}.{c}","timestamp":"{at}"}}"#));
            let out = r.words(0, 4000);
            lines.push(format!(r#"{{{common},"type":"user","message":{{"role":"user","content":[{{"tool_use_id":"tu{t}.{c}","type":"tool_result","content":"{out}","is_error":false}}]}},"uuid":"r{t}.{c}","timestamp":"{}","toolUseResult":{{"stdout":"{out}","stderr":"","interrupted":false}},"sourceToolAssistantUUID":"b{t}.{c}"}}"#, stamp(2000)));
        }
        if t % 7 == 3 {
            // A background task reports back: not a person's prompt.
            lines.push(format!(r#"{{{common},"type":"user","message":{{"role":"user","content":"<task-notification><task-id>b{t}</task-id><status>completed</status></task-notification>"}},"origin":{{"kind":"task-notification"}},"promptSource":"system","uuid":"n{t}","timestamp":"{}"}}"#, stamp(5)));
        }
        if t % 11 == 4 {
            lines.push(format!(r#"{{{common},"type":"user","message":{{"role":"user","content":[{{"type":"text","text":"[Request interrupted by user]"}}]}},"uuid":"i{t}","timestamp":"{}"}}"#, stamp(5)));
        }
        if t % 13 == 6 {
            // A subagent's prompt, written beside the parent's lines.
            lines.push(format!(r#"{{"parentUuid":null,"isSidechain":true,"userType":"external","type":"user","message":{{"role":"user","content":"look into {}"}},"uuid":"sc{t}","timestamp":"{}"}}"#, r.words(5, 40), stamp(5)));
        }
        if t % 17 == 9 {
            // A compaction: its boundary and the summary it put in place of the conversation.
            lines.push(format!(r#"{{{common},"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{{"trigger":"auto","preTokens":160000}},"timestamp":"{}"}}"#, stamp(5)));
            lines.push(format!(r#"{{{common},"type":"user","message":{{"role":"user","content":"This session is being continued from a previous conversation. {}"}},"isVisibleInTranscriptOnly":true,"isCompactSummary":true,"uuid":"c{t}","timestamp":"{}"}}"#, r.words(400, 3000), stamp(5)));
        }
        let at = stamp(700);
        lines.push(format!(r#"{{{common},"message":{{"model":"claude","id":"msgz{t}","type":"message","role":"assistant","content":[{{"type":"text","text":"done with turn {t}. {}"}}]}},"type":"assistant","uuid":"z{t}","timestamp":"{at}"}}"#, r.words(0, 600)));
        lines.push(format!(r#"{{{common},"type":"system","subtype":"stop_hook_summary","hookCount":1,"timestamp":"{}"}}"#, stamp(1)));
    }
    Transcript { bytes: (lines.join("\n") + "\n").into_bytes(), starts, asked, at: at_ms }
}

fn small() -> Params {
    Params { segment_bytes: 64 << 10, level: 3, ..Params::default() }
}

/// What of a manifest a pack of the same log must reproduce: everything but the chunk files'
/// sizes, which are the zstd build's.
fn shape(m: &Manifest) -> serde_json::Value {
    let mut v = serde_json::to_value(m).unwrap();
    for s in v["segments"].as_array_mut().unwrap() {
        s["stored"] = 0.into();
    }
    v
}

/// `name`'s manifest file in `store` replaced by `old`'s bytes.
fn put_manifest(store: &Store, name: &str, old: &[u8]) {
    std::fs::write(store.manifest_path(name), old).unwrap();
}

const ACPMUX_BEFORE: &str = include_str!("fixtures/acpmux-before-transcripts.manifest.json");
const CLAUDE_BEFORE: &str = include_str!("fixtures/claude-before-transcripts.manifest.json");

#[test]
fn an_acpmux_log_packs_to_the_chunks_and_turns_it_did_before_transcripts_had_turns() {
    // The fixtures are the manifests the build before this change wrote for these logs.
    let before = Manifest::parse(ACPMUX_BEFORE.as_bytes()).unwrap();
    assert_eq!(before.turn_rule, 0);
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("log.ndjson");
    std::fs::write(&file, acpmux_log(400)).unwrap();
    let store = Store::new(dir.path().join("store"));
    let (m, _) = pack(&store, "acpmux", std::slice::from_ref(&file), &small(), false).unwrap();
    assert_eq!(m.turn_rule, TURN_RULE);
    assert_eq!(m.chunk_ids().unwrap(), before.chunk_ids().unwrap());
    assert_eq!(m.marks().collect::<Vec<_>>(), before.marks().collect::<Vec<_>>());
    assert_eq!(m.marks().count(), 400);
    let mut now = shape(&m);
    now.as_object_mut().unwrap().remove("turnRule");
    let mut was: serde_json::Value = serde_json::from_str(ACPMUX_BEFORE).unwrap();
    for s in was["segments"].as_array_mut().unwrap() {
        s["stored"] = 0.into();
    }
    assert_eq!(now, was, "only the new field differs");

    // A store that holds the older manifest keeps every sealed segment and writes nothing new.
    put_manifest(&store, "acpmux", ACPMUX_BEFORE.as_bytes());
    assert_eq!(Manifest::load(&store, "acpmux").unwrap().unwrap(), before);
    let (again, stats) = pack(&store, "acpmux", &[file], &small(), false).unwrap();
    let sealed = before.segments.iter().filter(|s| s.sealed).count() as u64;
    assert_eq!((stats.kept_segments, stats.new_chunks), (sealed, 0), "{stats:?}");
    assert_eq!(again.segments, m.segments);
}

#[test]
fn a_transcript_packed_before_it_had_turns_finds_them_on_its_next_pack() {
    let t = transcript(120);
    let before = Manifest::parse(CLAUDE_BEFORE.as_bytes()).unwrap();
    assert_eq!((before.turn_rule, before.marks().count()), (0, 0));
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("s.jsonl");
    std::fs::write(&file, &t.bytes).unwrap();
    let store = Store::new(dir.path().join("store"));
    let (fresh, _) = pack(&store, "claude", std::slice::from_ref(&file), &small(), true).unwrap();
    assert_eq!(fresh.chunk_ids().unwrap(), before.chunk_ids().unwrap());

    put_manifest(&store, "claude", CLAUDE_BEFORE.as_bytes());
    let (m, stats) = pack(&store, "claude", &[file], &small(), false).unwrap();
    // Every segment is encoded again, to the chunks it already had.
    assert_eq!((stats.kept_segments, stats.new_chunks), (0, 0), "{stats:?}");
    assert_eq!(m.marks().collect::<Vec<_>>(), t.starts);
    assert_eq!(m, fresh);
}

#[test]
fn a_transcript_reads_back_and_has_an_outline_and_digests() {
    let t = transcript(120);
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("s.jsonl");
    std::fs::write(&file, &t.bytes).unwrap();
    let store = Store::new(dir.path().join("store"));
    let (m, _) = pack(&store, "c", &[file], &small(), false).unwrap();
    assert!(m.segments.len() > 10, "{} segments", m.segments.len());
    assert_eq!(m.marks().collect::<Vec<_>>(), t.starts);

    let p = Pack::open(&store, "c").unwrap();
    let mut back = Vec::new();
    p.cat(&mut back).unwrap();
    assert!(back == t.bytes, "the transcript does not read back");
    p.verify().unwrap();

    // One line a turn: its range, when it was asked, its records, the first 160 bytes asked.
    let outline = cmux_session_pack::digest::outline(&p).unwrap();
    let rows: Vec<Vec<&str>> = outline.lines().map(|l| l.split('\t').collect()).collect();
    assert_eq!(rows.len(), 120);
    for (i, row) in rows.iter().enumerate() {
        let first = t.starts[i];
        let last = t.starts.get(i + 1).copied().unwrap_or(m.lines) - 1;
        assert_eq!(row[0], format!("c@{first}-{last}"));
        assert_eq!(row[1], t.at[i].to_string());
        assert_eq!(row[2], (last - first + 1).to_string());
        let want: String = t.asked[i].split_whitespace().collect::<Vec<_>>().join(" ");
        assert_eq!(row[3], &want[..want.len().min(160)], "turn {i}");
    }
    // Long prompts are blobs, and still come back in the outline.
    assert!(t.asked.iter().filter(|a| a.len() >= 384).count() > 20);

    // A turn as text: the prompt, the tool calls and the start of each result, the reply.
    let turn = |i: usize| RangeId::parse(rows[i][0]).unwrap();
    let mut shown = 0;
    for i in 0..120 {
        let text = cmux_session_pack::digest::digest(&p, &turn(i), Default::default()).unwrap();
        let first = t.starts[i];
        assert!(text.contains(&format!("\nuser (line {first}): turn {i}: ")), "{text}");
        assert!(text.contains(&format!("assistant: done with turn {i}.")), "{text}");
        assert!(!text.contains("This session is being continued"), "{text}");
        assert!(!text.contains("look into"), "a subagent's prompt is not this turn's: {text}");
        if text.contains("tool Bash (line ") {
            assert!(text.contains(r#"{"command":"make 0","description":"build"}"#), "{text}");
            assert!(text.contains("  result (ok, "), "{text}");
            shown += 1;
        }
        // Each cut result names the one line that holds it whole.
        for note in text.lines().filter(|l| l.contains("more bytes: session-pack range")) {
            let id = note.rsplit(' ').next().unwrap().trim_end_matches(']');
            let r = RangeId::parse(id).unwrap();
            assert_eq!(r.first, r.last);
            let line = &p.read_lines(r.first..r.first + 1).unwrap()[0];
            assert!(line.windows(13).any(|w| w == br#""tool_result""#) || r.first == first);
        }
        if i % 17 == 9 {
            assert!(text.contains("(context compacted here; its summary, "), "{text}");
        }
        if i % 7 == 3 {
            assert!(text.contains("notice (line "), "{text}");
        }
        assert!(text.len() < 20_000, "{}", text.len());
    }
    assert!(shown > 50, "{shown} turns with tool calls");
    // The last turns are one range.
    assert_eq!(m.tail_turns(2), t.starts[118]);
}

#[test]
fn acpmux_turn_summaries_restore_prompt_blobs_at_the_extraction_boundary() {
    use cmux_session_pack::digest::{outline, turns, turns_window};

    for field in ["promptLine", "prompt"] {
        let prompts = ["x".repeat(383), "y".repeat(384), "z".repeat(385), "界".repeat(129)];
        let mut bytes = String::new();
        for (i, prompt) in prompts.iter().enumerate() {
            writeln!(bytes, r#"{{"seq":{i},"at":1795000000000,"dir":"mux","kind":"turn_started","msg":{{"{field}":"{prompt}"}}}}"#).unwrap();
        }
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("events.ndjson");
        std::fs::write(&file, bytes).unwrap();
        let store = Store::new(dir.path().join("store"));
        let (manifest, _) = pack(&store, "mux", &[file], &small(), false).unwrap();
        let pack = Pack::with_manifest(&store, manifest);
        let all = turns(&pack).unwrap();
        let text = outline(&pack).unwrap();
        assert_eq!(all.len(), prompts.len());
        for (i, prompt) in prompts.iter().enumerate() {
            let mut end = prompt.len().min(160);
            while !prompt.is_char_boundary(end) {
                end -= 1;
            }
            assert_eq!(all[i].ask, prompt[..end], "{field}, turn {i}");
            assert_eq!(turns_window(&pack, i, i + 1).unwrap(), all[i..i + 1]);
            assert!(text.lines().nth(i).unwrap().ends_with(&prompt[..end]));
        }
    }
}
