//! `conversation-changed` makes the app list the conversations again
//! (`home-inbox`): a list reads again only the conversations that changed
//! since the last one (audit 2026-11-18 section 15).
use super::*;
use cmux_conversation::Part;

fn people() -> Vec<Participant> {
    serde_json::from_value(json!([
        {"id": LOCAL_USER, "kind": "human", "display_name": "Me"},
        {"id": "agent_chief", "kind": "agent", "display_name": "Chief"}
    ]))
    .unwrap()
}

fn send(key: &str) -> Op {
    Op::MessageSend {
        client_msg_id: key.into(),
        parts: vec![Part::Text { text: format!("hi {key}"), runs: None }],
        reply_to: None,
        answers: Vec::new(),
        answers_pending: Vec::new(),
        thread_root: None,
    }
}

fn reads() -> usize {
    SUMMARY_READS.with(|reads| reads.replace(0))
}

/// Detector: after one conversation of 200 changes, a list reads that one
/// again, and its summaries equal those of a list built from nothing.
#[test]
fn a_list_after_one_change_reads_only_that_conversation() {
    let mut store = ConversationStore::open(None).unwrap();
    let ids: Vec<String> = (0..200)
        .map(|n| {
            store
                .create(&format!("create-{n}"), LOCAL_USER, &format!("c{n}"), &people())
                .unwrap()
                .summary
                .id
        })
        .collect();
    reads();
    store.list().unwrap();
    assert_eq!(reads(), 200, "the first list reads every conversation");
    store.list().unwrap();
    assert_eq!(reads(), 0, "nothing changed");
    store.apply_op(&ids[17], "send-1", LOCAL_USER, &send("send-1")).unwrap();
    let listed = store.list().unwrap();
    assert_eq!(reads(), 1, "one conversation changed");
    assert_eq!(listed[0].id, ids[17], "the changed one is newest");
    assert_eq!(listed[0].last_message.as_ref().unwrap().client_msg_id, "send-1");
    store.summaries.clear();
    assert_eq!(store.list().unwrap(), listed, "the same summaries as a list from nothing");
}

/// Bench at Leo's scale: a list after one conversation changed, with the
/// cache (after) and with it cleared before each list, which is every
/// conversation read as before (before). Run on the fleet:
/// `cargo test -p cmux-tui-core --release conversation_list_bench -- --ignored --nocapture`
/// (`CMUX_BENCH_CONVERSATIONS` sets the count, default 10,790).
#[test]
#[ignore = "bench"]
fn conversation_list_bench() {
    let count: usize = std::env::var("CMUX_BENCH_CONVERSATIONS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(10_790);
    let mut store = ConversationStore::open(None).unwrap();
    let ids: Vec<String> = (0..count)
        .map(|n| {
            let id = store
                .create(&format!("create-{n}"), LOCAL_USER, &format!("c{n}"), &people())
                .unwrap()
                .summary
                .id;
            store
                .apply_op(&id, &format!("seed-{n}"), LOCAL_USER, &send(&format!("seed-{n}")))
                .unwrap();
            id
        })
        .collect();
    store.list().unwrap();
    let rounds = 20;
    let mut line = |label: &str, clear: bool| {
        reads();
        let mut total = std::time::Duration::ZERO;
        for round in 0..rounds {
            let id = &ids[(round * 97) % ids.len()];
            store
                .apply_op(
                    id,
                    &format!("{label}-{round}"),
                    LOCAL_USER,
                    &send(&format!("{label}-{round}")),
                )
                .unwrap();
            if clear {
                store.summaries.clear();
            }
            let started = std::time::Instant::now();
            store.list().unwrap();
            total += started.elapsed();
        }
        let read = reads() as f64 / rounds as f64;
        // load_head is four statements and the last message one more, plus the one stamp query.
        println!(
            "| {label} | {count} | {read:.1} | {:.0} | {:.2} |",
            1.0 + read * 5.0,
            total.as_secs_f64() * 1000.0 / rounds as f64
        );
    };
    println!(
        "| Home local list | Conversations | Conversations read/event | SQL statements/event | ms/event |"
    );
    println!("|---|---:|---:|---:|---:|");
    line("before", true);
    line("after", false);
}
