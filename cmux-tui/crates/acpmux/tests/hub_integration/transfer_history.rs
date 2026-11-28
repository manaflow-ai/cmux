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
    stage_history_for(src, dst, id, through, Value::Null).await
}

/// [`stage_history`] staged under `control` (`peer`, `web`, or Null for none), as a cmux
/// daemon's `agent-transfer-stage` stages it under its receive guard's control.
async fn stage_history_for(
    src: &mut TestClient,
    dst: &mut TestClient,
    id: &str,
    through: &Value,
    control: Value,
) -> (Value, String) {
    let have =
        dst.request("_acpmux/transfer_history_have", json!({"sessionId": id})).await.unwrap();
    let ask = json!({"sessionId": id, "throughSeq": through, "have": have["have"]});
    let export = src.request("_acpmux/transfer_history_export", ask).await.unwrap();
    assert_eq!(export["afterSeq"], *through, "{export}");
    let ask = json!({"manifest": export, "control": control});
    let staged = dst.request("_acpmux/transfer_stage", ask).await.unwrap();
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
    // Usable, not yet fully here: Session Info says what it still awaits.
    let info = dst.request("_acpmux/info", json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["historyFollowing"]["throughSeq"], through, "{info}");
    assert!(info["historyFollowing"]["sinceMs"].is_u64(), "{info}");

    // The history follows, packed.
    let follow_started = std::time::Instant::now();
    let (export, history_stage) = stage_history(&mut src, &mut dst, &id, &through).await;
    let ask = json!({"sessionId": id, "stageId": history_stage});
    let arrived = dst.request("_acpmux/transfer_history", ask).await.unwrap();
    let follow_ms = follow_started.elapsed().as_millis();
    assert_eq!(arrived["throughSeq"], through, "{arrived}");
    let info = dst.request("_acpmux/info", json!({"sessionId": id})).await.unwrap();
    assert!(info.get("historyFollowing").is_none(), "fully here: {info}");
    let packed = &export["packed"];
    let raw = packed["rawBytes"].as_u64().unwrap();
    let bundle = packed["bundleBytes"].as_u64().unwrap();
    assert!(raw > 50 << 20, "the history is {raw} bytes, not over 50 MB");
    assert!(carried * 20 < raw, "the freeze carried {carried} bytes of a {raw} byte log");

    // The whole log reads on the target as it did on the source, then what it did there.
    let (records, said) = whole_log(&mut dst, &id).await;
    // The tail on the target also holds the move's own records, so the two parts cover the
    // source's log and more.
    let history_records = arrived["records"].as_u64().unwrap() as usize;
    assert!(history_records < source_records, "{arrived}");
    assert!(
        history_records + tail_records >= source_records,
        "{arrived}, {tail_records} in the tail"
    );
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

/// The steps of one history-later move's freeze, in ms, and the log's size.
struct Freeze {
    prompts: usize,
    log_bytes: u64,
    /// The bytes the freeze carried: the files of the begin's bundle.
    carried: u64,
    prepare_ms: u128,
    begin_ms: u128,
    receive_ms: u128,
    finish_ms: u128,
    commit_ms: u128,
    export_ms: u128,
    /// The prepare's pack of the history, on its blocking thread, and the export's own work.
    pack_ms: Value,
    export_answer_ms: Value,
}

impl Freeze {
    fn total(&self) -> u128 {
        self.begin_ms + self.receive_ms + self.finish_ms + self.commit_ms
    }
}

/// A chat of `prompts` large turns moved with its history left to follow; each step from begin
/// to commit is timed, then the history is exported (as the client does after commit).
async fn timed_freeze(prompts: usize) -> Freeze {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for n in 0..prompts {
        src.request(method::SESSION_PROMPT, prompt(&id, &format!("p-{n}"), "chunks: 2500"))
            .await
            .unwrap();
    }
    src.request(method::SESSION_PROMPT, prompt(&id, "p-last", "last")).await.unwrap();
    let ask = json!({"sessionId": id, "historyLater": {"keepTurns": 1}});
    let at = std::time::Instant::now();
    let prepared = src.request("_acpmux/transfer_prepare", ask).await.unwrap();
    let prepare_ms = at.elapsed().as_millis();
    let through = prepared["afterSeq"].clone();
    let staged =
        dst.request("_acpmux/transfer_stage", json!({"manifest": prepared})).await.unwrap();
    let stage_id = staged["stageId"].as_str().unwrap().to_owned();
    page(&mut src, &mut dst, &prepared, &stage_id).await;
    dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await.unwrap();

    let at = std::time::Instant::now();
    let begin_ask = json!({"sessionId": id, "interrupt": false, "prepareId": prepared["prepareId"],
                           "afterSeq": prepared["afterSeq"]});
    let begin = src.request("_acpmux/transfer_begin", begin_ask).await.unwrap();
    let begin_ms = at.elapsed().as_millis();
    let carried: u64 =
        begin["files"].as_array().unwrap().iter().map(|f| f["size"].as_u64().unwrap()).sum();
    let at = std::time::Instant::now();
    let receive = json!({"manifest": begin, "stageId": stage_id});
    let received = dst.request("_acpmux/transfer_receive", receive).await.unwrap();
    let receive_id = received["receiveId"].as_str().unwrap().to_owned();
    copy_bundle(&mut src, &mut dst, &begin, &receive_id).await;
    let receive_ms = at.elapsed().as_millis();
    let at = std::time::Instant::now();
    let finish = json!({"receiveId": receive_id, "epoch": begin["epoch"]});
    dst.request("_acpmux/transfer_finish", finish).await.unwrap();
    let finish_ms = at.elapsed().as_millis();
    let at = std::time::Instant::now();
    let commit = json!({"sessionId": id, "transferId": begin["transferId"],
                        "to": {"sessionId": id}, "epoch": begin["epoch"]});
    src.request("_acpmux/transfer_commit", commit).await.unwrap();
    let commit_ms = at.elapsed().as_millis();

    let at = std::time::Instant::now();
    let (export, _) = stage_history(&mut src, &mut dst, &id, &through).await;
    let export_ms = at.elapsed().as_millis();
    let log_bytes = export["packed"]["rawBytes"].as_u64().unwrap();
    let pack_ms = export["packed"]["prepackMs"].clone();
    let export_answer_ms = export["packed"]["ms"].clone();
    // The export bundled the prepare's pack: it did not pack the log again.
    assert!(pack_ms.is_u64(), "the export packed again: {export}");
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
    Freeze {
        prompts,
        log_bytes,
        carried,
        prepare_ms,
        begin_ms,
        receive_ms,
        finish_ms,
        commit_ms,
        export_ms,
        pack_ms,
        export_answer_ms,
    }
}

/// The freeze (begin to commit) of a history-later move does not grow with the log: a log 20
/// times larger carries about as many bytes through the freeze. Prints both freezes' times.
///
/// It asserts what the freeze carried, not how long it took: the times are those of a test
/// binary whose other tests (the 50 MB move beside it among them) load the same machine, and a
/// bound on them failed once under that load (1775 ms for a 66 MB log against 55 ms for 3.3 MB)
/// and passed at the same code (24 ms against 16 ms). What the freeze carries is what would make
/// it grow.
#[tokio::test]
async fn the_freeze_of_a_history_later_move_does_not_grow_with_the_log() {
    let small = timed_freeze(4).await;
    let large = timed_freeze(80).await;
    for f in [&small, &large] {
        eprintln!(
            "freeze of a {:.1} MB log ({} prompts), {} bytes carried: begin {} ms, receive {} ms, finish {} ms, \
             commit {} ms, total {} ms; prepare {} ms (its background pack {} ms); after the \
             commit, history export {} ms, export through its stage {} ms",
            f.log_bytes as f64 / 1048576.0,
            f.prompts,
            f.carried,
            f.begin_ms,
            f.receive_ms,
            f.finish_ms,
            f.commit_ms,
            f.total(),
            f.prepare_ms,
            f.pack_ms,
            f.export_answer_ms,
            f.export_ms,
        );
    }
    assert!(large.log_bytes > 20 * small.log_bytes, "the large log is not much larger");
    // The last turn alone, whatever the log behind it: the same few KB for both.
    assert!(
        large.carried <= small.carried * 2 && large.carried * 20 < large.log_bytes,
        "the freeze grew with the log: {} bytes carried of {} bytes, {} of {} bytes",
        small.carried,
        small.log_bytes,
        large.carried,
        large.log_bytes,
    );
}

/// A history staged under a guard's control arrives rewritten for it, as the guarded receive
/// rewrites the tail (`transfer_guard.rs` `guarded_record`): every turn of the history that
/// followed runs under the target's control, not the source's.
#[tokio::test]
async fn a_history_staged_under_a_guard_arrives_rewritten_for_it() {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for n in 0..3 {
        src.request(method::SESSION_PROMPT, prompt(&id, &format!("p-{n}"), "hi")).await.unwrap();
    }
    src.request(method::SESSION_PROMPT, prompt(&id, "p-last", "last")).await.unwrap();
    let ask = json!({"sessionId": id, "historyLater": {"keepTurns": 1}});
    let prepared = src.request("_acpmux/transfer_prepare", ask).await.unwrap();
    let through = prepared["afterSeq"].clone();
    let staged =
        dst.request("_acpmux/transfer_stage", json!({"manifest": prepared})).await.unwrap();
    let stage_id = staged["stageId"].as_str().unwrap().to_owned();
    page(&mut src, &mut dst, &prepared, &stage_id).await;
    dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await.unwrap();
    move_staged(&mut src, &mut dst, &id, &prepared, &stage_id, false).await;

    let (_, history) = stage_history_for(&mut src, &mut dst, &id, &through, json!("web")).await;
    let arrived = dst
        .request("_acpmux/transfer_history", json!({"sessionId": id, "stageId": history}))
        .await
        .unwrap();
    assert_eq!(arrived["throughSeq"], through, "{arrived}");

    let through = through.as_u64().unwrap();
    let page = dst
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
        .await
        .unwrap();
    let started: Vec<&Value> = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["seq"].as_u64().unwrap() <= through && e["kind"] == "turn_started")
        .collect();
    assert_eq!(started.len(), 3, "{page}");
    for e in started {
        assert_eq!(
            (&e["msg"]["control"], &e["msg"]["trustGate"]),
            (&json!("web"), &json!(true)),
            "{e}"
        );
    }
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}
