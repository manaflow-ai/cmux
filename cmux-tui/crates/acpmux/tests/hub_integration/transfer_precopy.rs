//! Pre-copy for a chat move (`hub/transfer_precopy.rs`, `transfer-precopy-v1`): the history goes
//! to the target before the freeze, and the freeze moves only what followed. The test is the
//! client, as `acpmux session transfer` is (`cli/run/transfer.rs`).

use super::*;

#[path = "transfer_live.rs"]
mod transfer_live;

/// Two daemons on local stores, as daemons keep them, and a client of each.
async fn two_local() -> ([std::path::PathBuf; 2], TestClient, TestClient) {
    let dirs = ["a", "b"]
        .map(|n| std::env::temp_dir().join(format!("acpmux-pre-{n}-{}", uuid::Uuid::now_v7())));
    let (a, b) = (local_hub(&dirs[0]), local_hub(&dirs[1]));
    let (a, b) = (connect(&a).await, connect(&b).await);
    (dirs, a, b)
}

/// Prepares `id` on `src` and stages its prefix on `dst`: `(prepare answer, stageId)`.
async fn stage(src: &mut TestClient, dst: &mut TestClient, id: &str) -> (Value, String) {
    stage_from(src, dst, id, Value::Null).await
}

/// [`stage`] of a prepare from `base`, as `transfer_base` named it on `dst`.
async fn stage_from(
    src: &mut TestClient,
    dst: &mut TestClient,
    id: &str,
    base: Value,
) -> (Value, String) {
    let params = json!({"sessionId": id, "base": base});
    let prepared = src.request("_acpmux/transfer_prepare", params).await.unwrap();
    assert_eq!(prepared["schema"], "acpmux.transfer.prefix.v1", "{prepared}");
    let staged =
        dst.request("_acpmux/transfer_stage", json!({"manifest": prepared})).await.unwrap();
    let stage_id = staged["stageId"].as_str().unwrap().to_owned();
    // A prepare pages as a bundle does, with no epoch.
    for file in prepared["files"].as_array().unwrap() {
        let path = file["path"].as_str().unwrap();
        let mut offset = 0u64;
        loop {
            let read = json!({"transferId": prepared["prepareId"], "path": path, "offset": offset});
            let part = src.request("_acpmux/transfer_read", read).await.unwrap();
            let write = json!({"receiveId": stage_id, "path": path, "offset": offset, "data": part["data"]});
            dst.request("_acpmux/transfer_write", write).await.unwrap();
            offset = part["next"].as_u64().unwrap();
            if part["eof"] == true {
                break;
            }
        }
    }
    let done =
        dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await.unwrap();
    assert_eq!(done["afterSeq"], prepared["afterSeq"], "{done}");
    (prepared, stage_id)
}

/// The rest of a pre-copied move: begin past the prefix, receive with the stage, finish, commit.
async fn move_staged(
    src: &mut TestClient,
    dst: &mut TestClient,
    id: &str,
    prepared: &Value,
    stage_id: &str,
    interrupt: bool,
) -> Value {
    let begin = src
        .request(
            "_acpmux/transfer_begin",
            json!({"sessionId": id, "interrupt": interrupt, "prepareId": prepared["prepareId"],
                   "afterSeq": prepared["afterSeq"]}),
        )
        .await
        .unwrap();
    assert_eq!(begin["prefix"]["afterSeq"], prepared["afterSeq"], "{begin}");
    let receive = json!({"manifest": begin, "stageId": stage_id});
    let received = dst.request("_acpmux/transfer_receive", receive).await.unwrap();
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    copy_bundle(src, dst, &begin, &receive_id).await;
    let finish = json!({"receiveId": receive_id, "epoch": begin["epoch"]});
    let moved = dst.request("_acpmux/transfer_finish", finish).await.unwrap();
    assert_eq!(moved["sessionId"], id, "{moved}");
    let commit = json!({"sessionId": id, "transferId": begin["transferId"],
                        "to": {"sessionId": id}, "epoch": begin["epoch"]});
    src.request("_acpmux/transfer_commit", commit).await.unwrap();
    begin
}

/// Every record of the chat's log on `c`, paged: their seqs run up with none twice. Returns the
/// count of records and the `user_message` texts.
async fn whole_log(c: &mut TestClient, id: &str) -> (usize, Vec<String>) {
    let (mut seqs, mut said) = (Vec::<u64>::new(), Vec::new());
    loop {
        let after = seqs.last().copied().unwrap_or(0);
        let page = c
            .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": after, "limit": 5000}))
            .await
            .unwrap();
        let events = page["events"].as_array().unwrap();
        if events.is_empty() {
            break;
        }
        for e in events {
            seqs.push(e["seq"].as_u64().unwrap());
            if e["kind"] == "user_message" {
                said.push(e["msg"]["text"].as_str().unwrap_or_default().to_owned());
            }
        }
    }
    for pair in seqs.windows(2) {
        assert!(pair[1] > pair[0], "the log goes back or repeats at {pair:?}");
    }
    (seqs.len(), said)
}

async fn assert_whole_log(c: &mut TestClient, id: &str) {
    assert!(whole_log(c, id).await.0 > 0);
}

async fn wait_texts(c: &mut TestClient, id: &str, last: &str) -> Vec<String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !texts(c, id, "user_message").await.contains(&last.to_owned()) {
        assert!(tokio::time::Instant::now() < deadline, "{last:?} never ran");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    texts(c, id, "user_message").await
}

#[tokio::test]
async fn a_precopied_move_keeps_history_queue_and_draft_and_each_queued_prompt_runs_once() {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    src.request(method::SESSION_PROMPT, prompt(&id, "p-hi", "hi")).await.unwrap();
    let (prepared, stage_id) = stage(&mut src, &mut dst, &id).await;
    let listed = dst.request(method::MUX_INFO, json!({"sessionId": id})).await;
    assert!(listed.is_err(), "a staged prefix is no chat on the target: {listed:?}");

    // The chat runs on after its prepare: what it logs then moves with the freeze.
    src.request(method::SESSION_PROMPT, prompt(&id, "p-between", "between")).await.unwrap();
    src.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "unsent words"}))
        .await
        .unwrap();
    src.send(method::SESSION_PROMPT, prompt(&id, "p-turn", "until-cancel")).await;
    src.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    for (prompt_id, text) in [("p-a", "a"), ("p-b", "b")] {
        src.send(method::SESSION_PROMPT, prompt(&id, prompt_id, text)).await;
        src.wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
            p["promptId"] == prompt_id && p["queued"] == true
        })
        .await;
    }
    let begin = move_staged(&mut src, &mut dst, &id, &prepared, &stage_id, true).await;
    assert!(begin["prefix"]["afterSeq"].as_u64().unwrap() > 0, "{begin}");

    let ran = wait_texts(&mut dst, &id, "b").await;
    assert_eq!(ran.len(), 6, "history, the continuation, the queue once: {ran:?}");
    assert_eq!(ran[..3], ["hi", "between", "until-cancel"], "{ran:?}");
    assert!(ran[3].starts_with("This chat moved to another machine"), "{ran:?}");
    assert_eq!(ran[4..], ["a", "b"], "{ran:?}");
    assert_eq!(
        texts(&mut src, &id, "user_message").await,
        ["hi", "between", "until-cancel"],
        "the source ran nothing after the move began"
    );
    let draft = dst.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(draft["draft"], "unsent words", "{draft}");
    assert_whole_log(&mut dst, &id).await;
    let arrived = dst.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(arrived["transferBlocked"], false, "{arrived}");
    assert_eq!(arrived["moving"], false, "{arrived}");

    // And back, pre-copied again: the moved-away copy there gives way to the one that comes.
    let (prepared, stage_id) = stage(&mut dst, &mut src, &id).await;
    dst.request(method::SESSION_PROMPT, prompt(&id, "p-there", "there")).await.unwrap();
    move_staged(&mut dst, &mut src, &id, &prepared, &stage_id, false).await;
    src.request(method::SESSION_PROMPT, prompt(&id, "p-home", "home")).await.unwrap();
    let home = texts(&mut src, &id, "user_message").await;
    assert_eq!(home[home.len() - 2..], ["there", "home"], "{home:?}");
    assert_eq!(home.len(), 8, "{home:?}");
    assert_whole_log(&mut src, &id).await;
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// The size of the prepare's prefix file.
fn prefix_bytes(prepared: &Value) -> u64 {
    prepared["files"].as_array().unwrap().iter().map(|f| f["size"].as_u64().unwrap()).sum()
}

#[tokio::test]
async fn a_chat_that_comes_back_pre_copies_only_what_it_did_away() {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    src.request(method::SESSION_PROMPT, prompt(&id, "p-big", "chunks: 400")).await.unwrap();
    let base = dst.request("_acpmux/transfer_base", json!({"sessionId": id})).await.unwrap();
    assert_eq!(base["base"], Value::Null, "the target never held it: {base}");
    let (prepared, stage_id) = stage(&mut src, &mut dst, &id).await;
    let full = prefix_bytes(&prepared);
    let begin = move_staged(&mut src, &mut dst, &id, &prepared, &stage_id, false).await;

    // Back: the source holds the copy that move shipped, and the target has done one turn since.
    dst.request(method::SESSION_PROMPT, prompt(&id, "p-there", "there")).await.unwrap();
    let base = src.request("_acpmux/transfer_base", json!({"sessionId": id})).await.unwrap();
    assert_eq!(base["base"]["transferId"], begin["transferId"], "{base}");
    let (prepared, stage_id) = stage_from(&mut dst, &mut src, &id, base["base"].clone()).await;
    assert_eq!(prepared["base"]["transferId"], begin["transferId"], "{prepared}");
    let delta = prefix_bytes(&prepared);
    assert!(delta * 4 < full, "only what it did away: {delta} of {full} bytes");
    let begin = move_staged(&mut dst, &mut src, &id, &prepared, &stage_id, false).await;
    src.request(method::SESSION_PROMPT, prompt(&id, "p-home", "home")).await.unwrap();
    assert_eq!(texts(&mut src, &id, "user_message").await, ["chunks: 400", "there", "home"]);
    let (records, _) = whole_log(&mut src, &id).await;

    // And out again from that base; a base of another move is not taken, and a stage of a
    // prefix from a base this daemon does not hold is refused.
    let wrong = json!({"sessionId": id, "base": {"transferId": "other"}});
    let full_again = src.request("_acpmux/transfer_prepare", wrong).await.unwrap();
    assert_eq!(full_again["base"], Value::Null, "{full_again}");
    let base = dst.request("_acpmux/transfer_base", json!({"sessionId": id})).await.unwrap();
    assert_eq!(base["base"]["transferId"], begin["transferId"], "{base}");
    let params = json!({"sessionId": id, "base": base["base"]});
    let based = src.request("_acpmux/transfer_prepare", params).await.unwrap();
    let mut forged = based.clone();
    forged["base"]["digest"] = json!("0".repeat(64));
    let refused = dst.request("_acpmux/transfer_stage", json!({"manifest": forged})).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("transfer.unbased")), "{refused:?}");
    let (prepared, stage_id) = stage_from(&mut src, &mut dst, &id, base["base"].clone()).await;
    move_staged(&mut src, &mut dst, &id, &prepared, &stage_id, false).await;
    let (moved, said) = whole_log(&mut dst, &id).await;
    assert_eq!(said, ["chunks: 400", "there", "home"]);
    assert!(moved > records, "the move's own records follow: {moved} after {records}");
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[tokio::test]
async fn a_diverged_prefix_is_refused_and_given_back_and_a_full_move_then_works() {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    src.request(method::SESSION_PROMPT, prompt(&id, "p-hi", "hi")).await.unwrap();
    let (prepared, stage_id) = stage(&mut src, &mut dst, &id).await;
    src.request(method::SESSION_PROMPT, prompt(&id, "p-more", "more")).await.unwrap();

    // A prefix the source's log does not hold as prepared (here: another end) is refused, and
    // the chat is not left frozen.
    let after = prepared["afterSeq"].as_u64().unwrap();
    for (prepare_id, after_seq) in
        [(prepared["prepareId"].clone(), after - 1), (json!("pre-gone"), after)]
    {
        let refused = src
            .request(
                "_acpmux/transfer_begin",
                json!({"sessionId": id, "prepareId": prepare_id, "afterSeq": after_seq}),
            )
            .await;
        assert!(refused.as_ref().is_err_and(|e| e.contains("transfer.diverged")), "{refused:?}");
        let info = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
        assert_eq!(info["moving"], false, "a refused begin gives the chat back: {info}");
    }
    src.request(method::SESSION_PROMPT, prompt(&id, "p-still", "still")).await.unwrap();

    // A delta bundle never goes to a target without its stage, nor with another's.
    let begin = src
        .request(
            "_acpmux/transfer_begin",
            json!({"sessionId": id, "prepareId": prepared["prepareId"], "afterSeq": after}),
        )
        .await
        .unwrap();
    let alone = dst.request("_acpmux/transfer_receive", json!({"manifest": begin})).await;
    assert!(alone.as_ref().is_err_and(|e| e.contains("transfer.unstaged")), "{alone:?}");
    let wrong = json!({"manifest": begin, "stageId": uuid::Uuid::now_v7().to_string()});
    let wrong = dst.request("_acpmux/transfer_receive", wrong).await;
    assert!(wrong.as_ref().is_err_and(|e| e.contains("transfer.unstaged")), "{wrong:?}");
    let abort =
        json!({"sessionId": id, "transferId": begin["transferId"], "epoch": begin["epoch"]});
    src.request("_acpmux/transfer_abort", abort).await.unwrap();
    let _ = stage_id;

    // A full move, as before pre-copy, takes it whole.
    let committed = move_whole(&mut src, &mut dst, &id, json!({"sessionId": id})).await;
    assert_eq!(committed["committed"], true, "{committed}");
    assert_eq!(texts(&mut dst, &id, "user_message").await, ["hi", "more", "still"]);
    assert_whole_log(&mut dst, &id).await;
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// The freeze (begin to commit) of a pre-copied move is about flat in the chat's history: a small
/// chat and one of about 20 MB. Prints the times; asserts what moved.
#[tokio::test]
async fn a_precopied_freeze_does_not_grow_with_the_history() {
    // History as an agent's chat has it: many small records (a reply streamed in chunks), about
    // 20 MB of log for the big one.
    let mut report = Vec::new();
    for (label, prompts) in [("small", 1usize), ("20MB", 30)] {
        for precopy in [false, true] {
            let (dirs, mut src, mut dst) = two_local().await;
            let s = src
                .request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []}))
                .await
                .unwrap();
            let id = s["sessionId"].as_str().unwrap().to_owned();
            for n in 0..prompts {
                src.request(method::SESSION_PROMPT, prompt(&id, &format!("p-{n}"), "chunks: 2500"))
                    .await
                    .unwrap();
            }
            let staged = if precopy { Some(stage(&mut src, &mut dst, &id).await) } else { None };
            src.request(method::SESSION_PROMPT, prompt(&id, "p-last", "last")).await.unwrap();
            let started = std::time::Instant::now();
            match &staged {
                Some((prepared, stage_id)) => {
                    move_staged(&mut src, &mut dst, &id, prepared, stage_id, false).await;
                }
                None => {
                    move_whole(&mut src, &mut dst, &id, json!({"sessionId": id})).await;
                }
            }
            let freeze = started.elapsed();
            let (records, ran) = whole_log(&mut dst, &id).await;
            assert_eq!(ran.len(), prompts + 1, "{label}");
            assert_eq!(ran.last().map(String::as_str), Some("last"), "{label}");
            report.push(format!(
                "{label:>6} precopy={precopy:<5} records={records:>5} freeze={:>4} ms",
                freeze.as_millis()
            ));
            for dir in dirs {
                let _ = std::fs::remove_dir_all(dir);
            }
        }
    }
    eprintln!("freeze, begin to commit:\n{}", report.join("\n"));
}
