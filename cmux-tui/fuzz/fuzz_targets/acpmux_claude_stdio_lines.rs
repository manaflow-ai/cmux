//! Claude Code stream-json stdout (`claude_stdio::Translator::inbound`,
//! `logged_line`), the way `agent.rs` reads it: one JSON value per line, a
//! line that is not JSON skipped, through one translator with a prompt
//! running, so the lines drive its turn, tool, task and workflow state.
//!
//! Invariant past "no panic": every message the translator emits writes a
//! line the hub reads back.
//!
//! The input never names a host path: a workflow launch's `transcriptDir`
//! (whose `journal.jsonl` the translator reads for the agent counts) is
//! always `TRANSCRIPT_DIR`, made once with a fixed journal, so a run reads
//! the same bytes on every machine and the journal read is still fuzzed.
#![no_main]

use std::sync::LazyLock;

use acpmux::claude_stdio::{Translator, logged_line};
use acpmux::rpc::{Message, method};
use libfuzzer_sys::fuzz_target;
use serde_json::{Value, json};

/// The most lines one input feeds, so one input stays far under the timeout.
const MAX_LINES: usize = 64;

static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .expect("a current-thread runtime")
});

/// The one transcript dir a fuzzed launch names: per process, so parallel
/// jobs never read another's half-written journal.
static TRANSCRIPT_DIR: LazyLock<String> = LazyLock::new(|| {
    let dir = std::env::temp_dir().join(format!("acpmux-fuzz-transcript-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a transcript dir");
    let journal = [
        json!({"type": "launched"}),
        json!({"type": "started", "agentId": "a0", "label": "n0", "phase": "Count"}),
        json!({"type": "started", "agentId": "a1", "label": "n1", "phase": "Count"}),
        json!({"type": "result", "agentId": "a0", "result": "1"}),
    ];
    let text: String = journal.iter().map(|line| format!("{line}\n")).collect();
    std::fs::write(dir.join("journal.jsonl"), text).expect("a journal");
    dir.to_str().expect("a UTF-8 temp dir").to_owned()
});

/// Points any `transcriptDir` of a launch result at `TRANSCRIPT_DIR`.
fn pin_transcript_dir(line: &mut Value) {
    if let Some(dir) = line.pointer_mut("/tool_use_result/transcriptDir") {
        *dir = Value::String(TRANSCRIPT_DIR.clone());
    }
}

fn check(messages: &[Message]) {
    for message in messages {
        let line = message.to_line();
        assert!(Message::parse(&line).is_ok(), "the translator wrote an unreadable line: {line}");
    }
}

fuzz_target!(|data: &[u8]| {
    RUNTIME.block_on(async {
        let translator = Translator::new("acp-fuzz".into(), "default", "haiku", "default");
        let prompt = Message::request(
            1,
            method::SESSION_PROMPT,
            json!({"sessionId": "acp-fuzz", "prompt": [{"type": "text", "text": "hi"}]}),
        );
        let _ = translator.outbound(&prompt).await;
        for raw in data.split(|b| *b == b'\n').take(MAX_LINES) {
            let Ok(mut line) = serde_json::from_slice::<Value>(raw) else { continue };
            pin_transcript_dir(&mut line);
            check(&[logged_line(&line)]);
            check(&translator.inbound(&line).await);
            let _ = translator.take_stdin_replies().await;
        }
        check(&translator.fail_pending("fuzz input ended").await);
    });
});
