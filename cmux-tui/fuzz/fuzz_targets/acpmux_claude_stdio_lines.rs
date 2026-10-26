//! Claude Code stream-json stdout (`claude_stdio::Translator::inbound`,
//! `logged_line`), the way `agent.rs` reads it: one JSON value per line, a
//! line that is not JSON skipped, through one translator with a prompt
//! running, so the lines drive its turn, tool, task and workflow state.
//!
//! Invariant past "no panic": every message the translator emits writes a
//! line the hub reads back.
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
            let Ok(line) = serde_json::from_slice::<Value>(raw) else { continue };
            check(&[logged_line(&line)]);
            check(&translator.inbound(&line).await);
            let _ = translator.take_stdin_replies().await;
        }
        check(&translator.fail_pending("fuzz input ended").await);
    });
});
