//! A move whose history follows the chat (`hub/transfer_history.rs`,
//! `transfer-history-later-v1`): the freeze carries the chat's last turn alone, the chat runs on
//! the target at once, and its history arrives after as a session pack. The test is the client,
//! as `acpmux session move` is with `ACPMUX_MOVE_HISTORY_LATER` set (`cli/run/transfer.rs`).

use super::*;

/// Pages every file of `manifest` (a prepare or a history export) from `src` into the stage.
async fn page(src: &mut TestClient, dst: &mut TestClient, manifest: &Value, stage_id: &str) -> u64 {
    let mut sent = 0;
    for file in manifest["files"].as_array().unwrap() {
        let path = file["path"].as_str().unwrap();
        let mut offset = 0u64;
        loop {
            let read = json!({"transferId": manifest["prepareId"], "path": path, "offset": offset});
            let part = src.request("_acpmux/transfer_read", read).await.unwrap();
            let write = json!({"receiveId": stage_id, "path": path, "offset": offset, "data": part["data"]});
            dst.request("_acpmux/transfer_write", write).await.unwrap();
            let next = part["next"].as_u64().unwrap();
            sent += next - offset;
            offset = next;
            if part["eof"] == true {
                break;
            }
        }
    }
    sent
}

/// The history through `through` exported on `src` (less what `dst` says it has) and staged on
/// `dst`: `(export answer, stageId)`.
async fn stage_history(
    src: &mut TestClient,
    dst: &mut TestClient,
    id: &str,
    through: &Value,
) -> (Value, String) {
    let have =
        dst.request("_acpmux/transfer_history_have", json!({"sessionId": id})).await.unwrap();
    let ask = json!({"sessionId": id, "throughSeq": through, "have": have["have"]});
    let export = src.request("_acpmux/transfer_history_export", ask).await.unwrap();
    assert_eq!(export["afterSeq"], *through, "{export}");
    let staged = dst.request("_acpmux/transfer_stage", json!({"manifest": export})).await.unwrap();
    let stage_id = staged["stageId"].as_str().unwrap().to_owned();
    let sent = page(src, dst, &export, &stage_id).await;
    assert_eq!(sent, export["packed"]["bundleBytes"].as_u64().unwrap(), "{export}");
    let done =
        dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await.unwrap();
    assert_eq!(done["afterSeq"], *through, "{done}");
    (export, stage_id)
}

/// A chat of over 50 MB starts on a second daemon from its last turn alone: the freeze carries
/// under a twentieth of the log, the chat takes a prompt there before its history is in, and the
/// history then arrives packed and the whole log reads as it did on the source. Prints the
/// freeze's time and bytes.
#[tokio::test]
async fn a_50_mb_chat_starts_on_a_second_daemon_from_its_tail_and_its_history_follows() {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // About 0.67 MB of log a prompt (`a_precopied_freeze_does_not_grow_with_the_history`).
    let prompts = 80usize;
    for n in 0..prompts {
        src.request(method::SESSION_PROMPT, prompt(&id, &format!("p-{n}"), "chunks: 2500"))
            .await
            .unwrap();
    }
    src.request(method::SESSION_PROMPT, prompt(&id, "p-last", "last")).await.unwrap();
    let (source_records, source_said) = whole_log(&mut src, &id).await;

    // Prepared with its history left behind: no line of the log is copied or staged.
    let ask = json!({"sessionId": id, "historyLater": {"keepTurns": 1}});
    let prepare_started = std::time::Instant::now();
    let prepared = src.request("_acpmux/transfer_prepare", ask).await.unwrap();
    let prepare_ms = prepare_started.elapsed().as_millis();
    assert_eq!(prepared["historyLater"], true, "{prepared}");
    let through = prepared["afterSeq"].clone();
    assert!(through.as_u64().unwrap() > 0, "{prepared}");
    let staged =
        dst.request("_acpmux/transfer_stage", json!({"manifest": prepared})).await.unwrap();
    let stage_id = staged["stageId"].as_str().unwrap().to_owned();
    page(&mut src, &mut dst, &prepared, &stage_id).await;
    let done =
        dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await.unwrap();
    assert_eq!((&done["afterSeq"], &done["records"]), (&through, &json!(0)), "{done}");

    // The freeze: begin to commit.
    let started = std::time::Instant::now();
    let begin = move_staged(&mut src, &mut dst, &id, &prepared, &stage_id, false).await;
    let freeze = started.elapsed();
    let carried: u64 =
        begin["files"].as_array().unwrap().iter().map(|f| f["size"].as_u64().unwrap()).sum();

    // The chat runs on the target from its tail, before its history is there.
    let (tail_records, tail_said) = whole_log(&mut dst, &id).await;
    assert_eq!(tail_said, ["last"], "the target holds the last turn alone");
    dst.request(method::SESSION_PROMPT, prompt(&id, "p-there", "there")).await.unwrap();
    // It does not move on while its history is awaited.
    let refused = dst.request("_acpmux/transfer_prepare", json!({"sessionId": id})).await;
    let refused = refused.unwrap_err();
    assert!(refused.contains("transfer.history_pending"), "{refused:?}");

    // The history follows, packed.
    let follow_started = std::time::Instant::now();
    let (export, history_stage) = stage_history(&mut src, &mut dst, &id, &through).await;
    let ask = json!({"sessionId": id, "stageId": history_stage});
    let arrived = dst.request("_acpmux/transfer_history", ask).await.unwrap();
    let follow_ms = follow_started.elapsed().as_millis();
    assert_eq!(arrived["throughSeq"], through, "{arrived}");
    let packed = &export["packed"];
    let raw = packed["rawBytes"].as_u64().unwrap();
    let bundle = packed["bundleBytes"].as_u64().unwrap();
    assert!(raw > 50 << 20, "the history is {raw} bytes, not over 50 MB");
    assert!(carried * 20 < raw, "the freeze carried {carried} bytes of a {raw} byte log");

    // The whole log reads on the target as it did on the source, then what it did there.
    let (records, said) = whole_log(&mut dst, &id).await;
    assert_eq!(arrived["records"].as_u64().unwrap() as usize + tail_records, source_records);
    assert!(records > source_records, "{records} records, {source_records} on the source");
    assert_eq!(said.len(), prompts + 2);
    assert_eq!(said[..=prompts], source_said[..]);
    assert_eq!(said.last().map(String::as_str), Some("there"));
    let first = dst
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 1}))
        .await
        .unwrap();
    assert_eq!(first["events"][0]["seq"], 1, "{first}");
    // Nothing is awaited now: the chat may move on.
    let again = dst.request("_acpmux/transfer_prepare", json!({"sessionId": id})).await.unwrap();
    assert!(again["afterSeq"].as_u64().unwrap() > through.as_u64().unwrap(), "{again}");

    // A target that holds the pack already is sent only what it lacks: here, nothing but the
    // manifest.
    let have =
        dst.request("_acpmux/transfer_history_have", json!({"sessionId": id})).await.unwrap();
    let ask = json!({"sessionId": id, "throughSeq": through, "have": have["have"]});
    let second = src.request("_acpmux/transfer_history_export", ask).await.unwrap();
    let second_bundle = second["packed"]["bundleBytes"].as_u64().unwrap();
    assert!(second_bundle * 20 < bundle, "a second export sent {second_bundle} of {bundle} bytes");

    eprintln!(
        "history-later move of a {:.1} MB log ({source_records} records): prepare {prepare_ms} ms \
         (no freeze); freeze {} ms (begin answered after {} ms), {carried} bytes carried ({:.2}% \
         of the log); history followed in {follow_ms} ms as {bundle} bytes ({:.1}x smaller, pack \
         {} ms); a second export to the same target: {second_bundle} bytes",
        raw as f64 / 1048576.0,
        freeze.as_millis(),
        begin["frozenMs"],
        carried as f64 * 100.0 / raw as f64,
        raw as f64 / bundle as f64,
        packed["ms"],
    );
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}
