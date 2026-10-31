//! Prompt bookmarks (`_acpmux/bookmark_get`, `_acpmux/bookmark_set`): the thread minimap's marks
//! on a chat's own prompts, kept with the session so they survive a restart, a fork and a move,
//! and reach every pane attached to the chat.

use super::*;

const GET: &str = "_acpmux/bookmark_get";
const SET: &str = "_acpmux/bookmark_set";

/// The seqs of every record of `kind` in a session's log, oldest first.
async fn seqs(c: &mut TestClient, id: &str, kind: &str) -> Vec<u64> {
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
        .await
        .unwrap();
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == kind)
        .filter_map(|e| e["seq"].as_u64())
        .collect()
}

fn local_hub(dir: &std::path::Path) -> (Config, Arc<Hub>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, dir).unwrap());
    (cfg, hub)
}

#[tokio::test]
async fn a_bookmark_marks_only_a_prompt_or_answer_and_survives_a_daemon_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-bookmarks-{}", uuid::Uuid::now_v7()));
    let (cfg, hub) = local_hub(&dir);
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "marks").await;
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let prompts = seqs(&mut c, &id, "user_message").await;
    assert_eq!(prompts.len(), 2, "{prompts:?}");
    let reply = seqs(&mut c, &id, "turn_result").await[0];
    let other_record = (1..reply)
        .find(|seq| !prompts.contains(seq))
        .expect("a record that is neither a prompt nor an answer");

    let empty = c.request(GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(empty["bookmarks"], json!([]), "{empty}");

    // Only the chat's own prompts and answers can be marked.
    let not_a_prompt =
        c.request(SET, json!({"sessionId": id, "seq": other_record, "bookmarked": true})).await;
    assert!(not_a_prompt.as_ref().is_err_and(|e| e.contains("not a prompt")), "{not_a_prompt:?}");
    // An answer's Pin marks its turn's `turn_result`.
    let pinned =
        c.request(SET, json!({"sessionId": id, "seq": reply, "bookmarked": true})).await.unwrap();
    assert_eq!(pinned["bookmarks"], json!([reply]), "{pinned}");
    c.request(SET, json!({"sessionId": id, "seq": reply, "bookmarked": false})).await.unwrap();
    let past_the_end =
        c.request(SET, json!({"sessionId": id, "seq": 1_000_000, "bookmarked": true})).await;
    assert!(past_the_end.as_ref().is_err_and(|e| e.contains("not a prompt")), "{past_the_end:?}");
    let no_flag = c.request(SET, json!({"sessionId": id, "seq": prompts[0]})).await;
    assert!(no_flag.is_err(), "{no_flag:?}");

    // Another pane on the chat hears every change.
    let mut other = connect(&hub).await;
    other.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();

    let set = c
        .request(SET, json!({"sessionId": id, "seq": prompts[1], "bookmarked": true}))
        .await
        .unwrap();
    assert_eq!(set["bookmarks"], json!([prompts[1]]), "{set}");
    let heard = other
        .wait_for(method::MUX_EVENT, |p| p["sessionId"] == id.as_str() && p["kind"] == "bookmarks")
        .await;
    assert_eq!(heard["msg"]["bookmarks"], json!([prompts[1]]), "{heard}");
    let set = c
        .request(SET, json!({"sessionId": id, "seq": prompts[0], "bookmarked": true}))
        .await
        .unwrap();
    assert_eq!(set["bookmarks"], json!([prompts[0], prompts[1]]), "{set}");
    let cleared = c
        .request(SET, json!({"sessionId": id, "seq": prompts[1], "bookmarked": false}))
        .await
        .unwrap();
    assert_eq!(cleared["bookmarks"], json!([prompts[0]]), "{cleared}");

    hub.shutdown_all().await;
    drop(hub);
    let hub2 = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut c2 = connect(&hub2).await;
    let loaded = c2.request(GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(loaded["bookmarks"], json!([prompts[0]]), "{loaded}");
    hub2.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_fork_keeps_the_bookmarks_of_the_prompts_and_answers_it_copies() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "fork-marks").await;
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let prompts = seqs(&mut c, &id, "user_message").await;
    c.request(SET, json!({"sessionId": id, "seq": prompts[1], "bookmarked": true})).await.unwrap();
    let through = *seqs(&mut c, &id, "turn_result").await.last().unwrap();
    // The last answer's Pin is a mark on its `turn_result`.
    c.request(SET, json!({"sessionId": id, "seq": through, "bookmarked": true})).await.unwrap();

    let f = c
        .request("acp.session.fork", json!({"sessionId": id, "throughSeq": through}))
        .await
        .unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    // The fork numbers its copy of the history itself: the mark follows the prompt.
    let copied = seqs(&mut c, &fid, "user_message").await;
    assert_eq!(copied.len(), 2, "{copied:?}");
    let answer = *seqs(&mut c, &fid, "turn_result").await.last().unwrap();
    let forked = c.request(GET, json!({"sessionId": fid})).await.unwrap();
    assert_eq!(forked["bookmarks"], json!([copied[1], answer]), "{forked}");
    // The two chats mark on their own from here.
    c.request(SET, json!({"sessionId": fid, "seq": copied[0], "bookmarked": true})).await.unwrap();
    let parent = c.request(GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(parent["bookmarks"], json!([prompts[1], through]), "{parent}");
    drop(hub);
}

#[tokio::test]
async fn a_moved_chat_keeps_its_bookmarks_and_the_source_keeps_none() {
    let (_a, mut src) = setup(PermissionPolicy::ApproveAll).await;
    let (_b, mut dst) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut src, "moved-marks").await;
    src.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
    )
    .await
    .unwrap();
    let hi = seqs(&mut src, &id, "user_message").await[0];
    src.request(SET, json!({"sessionId": id, "seq": hi, "bookmarked": true})).await.unwrap();

    // The move keeps the log's seqs, so the mark still names the same prompt there.
    let begin = src.request("_acpmux/transfer_begin", json!({"sessionId": id})).await.unwrap();
    let received =
        dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await.unwrap();
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    super::super::transfer::copy_bundle(&mut src, &mut dst, &begin, &receive_id).await;
    dst.request("_acpmux/transfer_finish", json!({"receiveId": receive_id})).await.unwrap();
    src.request(
        "_acpmux/transfer_commit",
        json!({"sessionId": id, "transferId": begin["transferId"], "to": {"sessionId": id}}),
    )
    .await
    .unwrap();

    let there = dst.request(GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(there["bookmarks"], json!([hi]), "{there}");
    assert_eq!(seqs(&mut dst, &id, "user_message").await, [hi]);
    let here = src.request(GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(here["bookmarks"], json!([]), "the source keeps no bookmarks: {here}");
}

/// Sets from many panes at once: the last `bookmarks` record in the log (what every attached pane
/// and an attach replay end on) is always the chat's marks as acpmux keeps them.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn concurrent_sets_log_the_marks_in_the_order_they_change_them() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "racing-marks").await;
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let prompts = seqs(&mut c, &id, "user_message").await;
    for round in 0..10 {
        let mut writers = Vec::new();
        for w in 0..8usize {
            let mut wc = connect(&hub).await;
            let (id, prompts) = (id.clone(), prompts.clone());
            writers.push(tokio::spawn(async move {
                for n in 0..20usize {
                    let seq = prompts[(w + n) % prompts.len()];
                    let on = (w + n + round) % 2 == 0;
                    wc.request(SET, json!({"sessionId": id, "seq": seq, "bookmarked": on}))
                        .await
                        .unwrap();
                }
            }));
        }
        for writer in writers {
            writer.await.unwrap();
        }
        let kept = c.request(GET, json!({"sessionId": id})).await.unwrap();
        let page = c
            .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 50_000}))
            .await
            .unwrap();
        let events = page["events"].as_array().unwrap();
        let last = events.iter().rev().find(|e| e["kind"] == "bookmarks");
        if let Some(last) = last {
            assert_eq!(last["msg"]["bookmarks"], kept["bookmarks"], "round {round}: {kept}");
        }
    }
}
