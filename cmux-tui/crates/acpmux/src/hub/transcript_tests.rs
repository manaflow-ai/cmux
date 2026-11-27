//! `TranscriptBuilder`: what a fresh agent session reads of a chat (a fork onto another harness,
//! a fork of an agent without `session/fork`, a refused resume). Every message the chat shows is
//! in it, word for word or, past the budget, by its opening words under a line that says so; the
//! first prompt is never lost (#50094: a pi chat forked onto Claude lost its codeword).

use super::*;

enum Event<'a> {
    User(&'a str),
    Agent(&'a str),
    Summary(&'a str),
}

fn build(events: &[Event<'_>], max_chars: usize) -> Option<String> {
    let mut builder = TranscriptBuilder::new(max_chars);
    for event in events {
        match event {
            Event::User(text) => builder.user(Some(text)),
            Event::Agent(text) => builder.agent_chunk(text),
            Event::Summary(text) => builder.compaction_summary(text),
        }
    }
    builder.finish()
}

#[test]
fn a_chat_that_fits_is_carried_word_for_word() {
    assert_eq!(build(&[], 100), None);
    let text = build(
        &[Event::User("hello"), Event::Agent("  a "), Event::Agent("b  "), Event::User("next")],
        1000,
    );
    assert_eq!(text.as_deref(), Some("user: hello\n\nassistant: a b\n\nuser: next"));
    assert_eq!(build(&[Event::Agent("answer")], 100).as_deref(), Some("assistant: answer"));
}

/// A chat far over the budget: its first prompt (the codeword) and its newest turns are word
/// for word, every message between is there by its opening words, and a line says which.
#[test]
fn a_long_chat_keeps_its_first_prompt_and_says_what_it_shortened() {
    let essay = "word ".repeat(2_000);
    let mut events = vec![Event::User("Remember codeword PELICAN-41."), Event::Agent("noted")];
    let prompts: Vec<String> = (0..40).map(|i| format!("question {i}: {essay}")).collect();
    for p in &prompts {
        events.push(Event::User(p));
        events.push(Event::Agent(&essay));
    }
    events.push(Event::User("LAST-PROMPT"));
    events.push(Event::Agent("LAST-REPLY"));
    let max = 60_000;
    let text = build(&events, max).unwrap();
    assert!(text.starts_with("user: Remember codeword PELICAN-41."), "{}", &text[..200]);
    assert!(text.ends_with("user: LAST-PROMPT\n\nassistant: LAST-REPLY"));
    assert!(text.contains("[acpmux shortened messages 2 to "), "{}", &text[..600]);
    assert!(text.contains("the chat itself still shows them in full"));
    // Every question the chat shows is there, by its opening words at least.
    for i in 0..40 {
        assert!(text.contains(&format!("user: question {i}: word word")), "question {i}");
    }
    assert!(text.chars().count() <= max + 400, "{}", text.chars().count());
}

/// After a compaction the summary stands for what came before it, but the first prompt stays.
#[test]
fn a_compacted_chat_keeps_its_first_prompt_and_the_summary() {
    let text = build(
        &[
            Event::User("FIRST"),
            Event::Agent("ignored"),
            Event::User("before"),
            Event::Summary("SUMMARY"),
            Event::User("after"),
            Event::Agent("  answer  "),
        ],
        1000,
    )
    .unwrap();
    assert_eq!(
        text,
        "user: FIRST\n\n<compaction_summary>\nSUMMARY\n</compaction_summary>\n\nuser: after\n\nassistant: answer"
    );
}

/// One message over the whole budget keeps its end, and says how much was cut.
#[test]
fn one_huge_reply_keeps_its_end() {
    let huge = format!("{}THE-END", "x".repeat(10_000));
    let text = build(&[Event::User("q"), Event::Agent(&huge)], 1_000).unwrap();
    assert!(text.starts_with("user: q"), "{text}");
    assert!(text.ends_with("THE-END"), "{text}");
    assert!(text.contains("omitted"), "{text}");
    assert!(text.chars().count() < 1_200, "{}", text.chars().count());
}

/// However long the log, the builder holds about its budget.
#[test]
fn the_builder_holds_its_budget_however_long_the_log() {
    let mut builder = TranscriptBuilder::new(10_000);
    let line = "y".repeat(500);
    for i in 0..20_000 {
        builder.user(Some(&format!("{i} {line}")));
        builder.agent_chunk(&line);
    }
    assert!(builder.recent_chars <= 10_000 + 600, "{}", builder.recent_chars);
    assert!(builder.shortened_chars <= 10_000 / 4, "{}", builder.shortened_chars);
    let text = builder.finish().unwrap();
    assert!(text.contains("are left out entirely"), "{}", &text[..400]);
    assert!(text.starts_with("user: 0 "));
}

/// [`Hub::missed_turns`] reads the copies of its kinds past the mark only; what it tells is
/// what a scan of the whole log past the mark, keeping its kinds, told, for every mark, on
/// a log on disk of many segments with tool updates and the mux's records between.
#[tokio::test]
async fn the_missed_turns_read_past_the_mark_tell_what_the_whole_scan_did() {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    cfg.store.segment_bytes = 64 * 1024;
    let store = crate::store::open(&cfg.store, dir.path()).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": "behind", "name": "behind",
        "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve("behind").unwrap();
    let chunk = |text: String| {
        json!({"params": {"update": {"sessionUpdate": "agent_message_chunk",
                                     "content": {"type": "text", "text": text}}}})
    };
    for n in 0..240 {
        hub.append(&session, "mux", "user_message", json!({"text": format!("ask {n}")}));
        hub.append(
            &session,
            "agent",
            "tool_call_update",
            json!({"params": {"n": n, "pad": "x".repeat(800)}}),
        );
        hub.append(&session, "agent", "agent_message_chunk", chunk(format!("reply {n} ")));
        hub.append(&session, "mux", "turn_result", json!({"turnSeq": n}));
        if n == 60 {
            let summary = json!({"params": {"update": {"text": "the first sixty"}}});
            hub.append(&session, "agent", "compaction_summary", summary);
        }
    }
    assert!(hub.store.wait_durable(std::time::Duration::from_secs(20)).unwrap());
    let end = session.seq.load(std::sync::atomic::Ordering::SeqCst);
    for after in [1, 2, 3, 17, 200, 243, 244, 300, end / 2, end - 5, end - 1, end] {
        for max_chars in [40, REPLAY_CHARS] {
            let mut want = TranscriptBuilder::new(max_chars);
            hub.store
                .scan(&session.id, after, &mut |e| {
                    if KINDS.contains(&e.kind.as_str()) {
                        want.read(&e);
                    }
                    true
                })
                .unwrap();
            let want = want.finish().map(|text| {
                json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored the turns this agent session did not see (it resumed from an older copy of itself); tool state was not restored\">\n{text}\n</restored_transcript>\n")})
            });
            session.meta.lock().unwrap().agent_behind_seq = Some(after);
            assert_eq!(hub.missed_turns(&session, max_chars), want, "past {after}, {max_chars}");
        }
    }
}
