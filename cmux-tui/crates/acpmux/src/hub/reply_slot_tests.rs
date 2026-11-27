//! The slot's fold against the daemon's full-log reply read (`subsessions.rs` `masked_reply`) and
//! a naive split of every reply, on random event streams; and the seed (read newest first,
//! stopping early) against the fold of the whole log.

use proptest::prelude::*;
use serde_json::json;

use super::{KEEP, ReplyFold, Seed};
use crate::store::EventRecord;

fn record(seq: u64, pick: u8, text: &str) -> EventRecord {
    let update = |kind: &str, meta: serde_json::Value| EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: kind.into(),
        msg: json!({
            "method": "session/update",
            "params": {"update": {"sessionUpdate": kind, "content": {"type": "text", "text": text}}, "_meta": meta},
        }),
        host_seq: None,
    };
    let mux = |kind: &str| EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: kind.into(),
        msg: json!({}),
        host_seq: None,
    };
    match pick % 12 {
        0..=3 => update("agent_message_chunk", json!({})),
        4 => update("tool_call", json!({})),
        5 => update("tool_call_update", json!({})),
        6 => update("agent_thought_chunk", json!({})),
        7 => update("plan", json!({})),
        8 => mux(if text.len() % 2 == 0 { "turn_started" } else { "user_message" }),
        // A subagent's words, a replayed chunk and a record of another kind change nothing.
        9 => update("agent_message_chunk", json!({"acpmux": {"subagent": "s1"}})),
        10 => update("agent_message_chunk.replay", json!({})),
        _ => mux("status"),
    }
}

/// Every reply of the stream, oldest first, untrimmed: the naive answer.
fn all_replies(events: &[EventRecord]) -> Vec<String> {
    let mut out = Vec::new();
    let mut fold = ReplyFold::default();
    // A KEEP-free fold: the same rules, every reply kept.
    let mut open = false;
    for e in events {
        match super::step(e) {
            super::Step::Ignore => {}
            super::Step::Close => open = false,
            super::Step::Chunk(t) => {
                if !open {
                    out.push(String::new());
                    open = true;
                }
                out.last_mut().unwrap().push_str(t);
            }
        }
        fold.apply(e);
    }
    out
}

fn stream() -> impl Strategy<Value = Vec<EventRecord>> {
    prop::collection::vec((any::<u8>(), "[a-c \\n]{0,6}"), 0..160).prop_map(|items| {
        items
            .iter()
            .enumerate()
            .map(|(i, (pick, text))| record(i as u64 + 1, *pick, text))
            .collect()
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn fold_matches_full_parse(events in stream()) {
        let mut fold = ReplyFold::default();
        for e in &events {
            fold.apply(e);
        }
        let upto = events.last().map_or(0, |e| e.seq);
        let oracle = crate::hub::subsessions::masked_reply(&events, upto, None);
        prop_assert_eq!(fold.last().map(crate::secret_scan::mask), oracle);

        let naive: Vec<String> = all_replies(&events)
            .into_iter()
            .map(|r| r.trim().to_owned())
            .filter(|r| !r.is_empty())
            .collect();
        for n in 1..=KEEP {
            // The fold keeps the last KEEP replies, blank ones too: its newest n with words are
            // the naive newest n with words, unless a blank one pushed one of them out.
            let kept: Vec<String> = all_replies(&events)
                .into_iter()
                .rev()
                .take(KEEP)
                .map(|r| r.trim().to_owned())
                .filter(|r| !r.is_empty())
                .take(n)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            prop_assert_eq!(fold.newest(n), kept.iter().map(String::as_str).collect::<Vec<_>>());
            prop_assert!(kept.iter().all(|r| naive.contains(r)));
        }
    }

    #[test]
    fn seed_matches_forward_fold(events in stream(), split in 0usize..160) {
        let mut forward = ReplyFold::default();
        for e in &events {
            forward.apply(e);
        }
        let mut seed = Seed::default();
        for e in events.iter().rev() {
            if !seed.push(e) {
                break;
            }
        }
        let seeded = seed.finish();
        prop_assert_eq!(&seeded, &forward);

        // A seed through a prefix, then the rest folded on: the live path after a seed.
        let cut = split.min(events.len());
        let mut seed = Seed::default();
        for e in events[..cut].iter().rev() {
            if !seed.push(e) {
                break;
            }
        }
        let mut live = seed.finish();
        for e in &events[cut..] {
            live.apply(e);
        }
        prop_assert_eq!(live, forward);
    }
}

#[test]
fn reply_is_capped_on_a_char_boundary() {
    let mut fold = ReplyFold::default();
    let big = "é".repeat(super::MAX_REPLY_BYTES);
    fold.apply(&record(1, 0, &big));
    let last = fold.last().unwrap();
    assert!(last.len() <= super::MAX_REPLY_BYTES);
}

/// `-n 8` of 256 KiB replies is 2 MiB, past the 1 MiB frame cap: the answer keeps the newest
/// that fit, and fits; control characters (6 bytes each as JSON) count at their JSON size.
#[test]
fn answer_fits_a_reply_page() {
    let big = "\u{1}".repeat(super::MAX_REPLY_BYTES);
    let replies: Vec<String> = (0..KEEP).map(|i| format!("{i}{big}")).collect();
    let out = super::within_budget(replies.clone(), super::ANSWER_BUDGET);
    let bytes = serde_json::to_string(&out).unwrap().len();
    assert!(bytes <= super::ANSWER_BUDGET, "{bytes} bytes");
    assert!(out.last().unwrap().starts_with(&format!("{}", KEEP - 1)), "newest kept");
    // Small replies all fit, unchanged.
    let small: Vec<String> = (0..KEEP).map(|i| format!("reply {i}")).collect();
    assert_eq!(super::within_budget(small.clone(), super::ANSWER_BUDGET), small);
}
