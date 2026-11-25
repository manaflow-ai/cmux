//! Live migration of a chat move (`hub/transfer_live.rs`, `transfer-live-v1`): the history is
//! copied in rounds while the chat runs, resumed from what the target holds, compressed, and the
//! freeze moves only what the last round left. The test is the client, as `acpmux session move`
//! is (`cli/run/transfer_live.rs`).
//!
//! 2026-11-22: a move of a 7.26 GB chat over a ~96 KB/s relay froze it for the whole copy (708 MB
//! in 47 min, about 6 h to go). `a_live_move_freezes_for_the_tail_only_over_a_slow_link` is the
//! before and after, on a link the test slows to a set rate.

use super::*;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use std::collections::HashMap;

/// A link of `rate` bytes a second (`None`: as fast as the machine): each write waits for its
/// bytes to cross it.
#[derive(Clone, Copy)]
struct Link {
    rate: Option<f64>,
    zstd: bool,
}

/// What a copy sent: bytes as the files hold them, and as they went.
#[derive(Default, Debug, Clone, Copy)]
struct Sent {
    raw: u64,
    wire: u64,
}

/// Pages `manifest`'s files from `src` (`transfer_id`) into `receive_id` on `dst`, each from
/// its offset in `from`, over `link`; stops after `budget` raw bytes when it is given (a client
/// that went away midway).
#[allow(clippy::too_many_arguments)]
async fn page(
    src: &mut TestClient,
    dst: &mut TestClient,
    manifest: &Value,
    transfer_id: &Value,
    receive_id: &str,
    epoch: Option<u64>,
    from: &HashMap<String, u64>,
    link: Link,
    budget: Option<u64>,
) -> Sent {
    let mut sent = Sent::default();
    for file in manifest["files"].as_array().unwrap() {
        let path = file["path"].as_str().unwrap();
        let size = file["size"].as_u64().unwrap();
        let mut offset = from.get(path).copied().unwrap_or(0);
        if offset == size && size > 0 {
            continue;
        }
        loop {
            if budget.is_some_and(|b| sent.raw >= b) {
                return sent;
            }
            let limit = budget.map_or(4u64 << 20, |b| (b - sent.raw).min(4 << 20));
            let mut read = json!({"transferId": transfer_id, "path": path, "offset": offset,
                                  "limit": limit});
            if let Some(epoch) = epoch {
                read["epoch"] = json!(epoch);
            }
            let part = src.request("_acpmux/transfer_read", read).await.unwrap();
            let data = part["data"].as_str().unwrap();
            let mut write = json!({"receiveId": receive_id, "path": path, "offset": offset});
            let wire = if link.zstd {
                let raw = BASE64.decode(data).unwrap();
                let packed = BASE64.encode(zstd::bulk::compress(&raw, 3).unwrap());
                write["encoding"] = json!("zstd");
                let len = packed.len();
                write["data"] = json!(packed);
                len
            } else {
                write["data"] = json!(data);
                data.len()
            };
            if let Some(epoch) = epoch {
                write["epoch"] = json!(epoch);
            }
            dst.request("_acpmux/transfer_write", write).await.unwrap();
            if let Some(rate) = link.rate {
                tokio::time::sleep(Duration::from_secs_f64(wire as f64 / rate)).await;
            }
            let next = part["next"].as_u64().unwrap();
            sent.raw += next - offset;
            sent.wire += wire as u64;
            offset = next;
            if part["eof"] == true {
                break;
            }
        }
    }
    sent
}

/// Where pages start for what the target says it holds (`have`), checked against the source's
/// digest of the same bytes of `transfer_id`.
async fn held(src: &mut TestClient, transfer_id: &Value, answer: &Value) -> HashMap<String, u64> {
    let mut from = HashMap::new();
    for h in answer["have"].as_array().into_iter().flatten() {
        let path = h["path"].as_str().unwrap();
        let ask = json!({"transferId": transfer_id, "path": path, "length": h["bytes"]});
        let theirs = src.request("_acpmux/transfer_digest", ask).await.unwrap();
        let same = theirs["sha256"] == h["sha256"];
        from.insert(path.to_owned(), if same { h["bytes"].as_u64().unwrap() } else { 0 });
    }
    from
}

/// One pre-copy round: prepare on `src`, a resumed stage on `dst`, pages from what it holds.
/// Returns the prepare, the stage id, what the stage said it held, and what was sent.
async fn round(
    src: &mut TestClient,
    dst: &mut TestClient,
    id: &str,
    link: Link,
    budget: Option<u64>,
) -> (Value, String, HashMap<String, u64>, Sent) {
    let prepared = src.request("_acpmux/transfer_prepare", json!({"sessionId": id})).await.unwrap();
    let stage = dst
        .request("_acpmux/transfer_stage", json!({"manifest": prepared, "resume": true}))
        .await
        .unwrap();
    let stage_id = stage["stageId"].as_str().unwrap().to_owned();
    let from = held(src, &prepared["prepareId"], &stage).await;
    let sent =
        page(src, dst, &prepared, &prepared["prepareId"], &stage_id, None, &from, link, budget)
            .await;
    (prepared, stage_id, from, sent)
}

fn prepares_of(id: &str) -> usize {
    let transfers = acpmux::config::home().join("transfers");
    std::fs::read_dir(transfers)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("pre-"))
        .filter(|e| {
            std::fs::read_to_string(e.path().join("prefix.json")).is_ok_and(|t| t.contains(id))
        })
        .count()
}

/// A pre-copy whose client went away halfway resumes from what the target holds, not from
/// zero; a later round sends only what the chat logged since; one prepare per chat is kept; the
/// freeze then moves only the tail, and every prompt runs once on the target.
#[tokio::test]
async fn a_stopped_precopy_resumes_where_the_target_stopped_and_later_rounds_send_only_the_delta() {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for n in 0..6 {
        src.request(method::SESSION_PROMPT, prompt(&id, &format!("p-{n}"), "chunks: 2500"))
            .await
            .unwrap();
    }
    let link = Link { rate: None, zstd: true };
    // Round one stops halfway: the client went away.
    let (first, _, from, sent) = round(&mut src, &mut dst, &id, link, Some(1 << 20)).await;
    assert!(from.is_empty(), "a first stage holds nothing: {from:?}");
    let total = first["files"].as_array().unwrap().iter().map(|f| f["size"].as_u64().unwrap());
    let total: u64 = total.sum();
    assert!(total > 2 * sent.raw, "the first round stopped before the end: {sent:?} of {total}");
    assert!(sent.wire * 4 < sent.raw, "pages go compressed: {sent:?}");

    // The chat runs on; the move is begun again.
    src.request(method::SESSION_PROMPT, prompt(&id, "p-mid", "mid")).await.unwrap();
    let (second, stage_id, from, sent2) = round(&mut src, &mut dst, &id, link, None).await;
    // What the stage held of the log is taken up; a small file the chat rewrote in place since
    // (its digest differs) is sent again whole.
    let resumed_at: u64 = from.values().sum();
    assert!(
        resumed_at <= sent.raw && resumed_at * 10 > sent.raw * 9,
        "the stage resumed at what it held: {from:?} of {sent:?}"
    );
    let total2: u64 =
        second["files"].as_array().unwrap().iter().map(|f| f["size"].as_u64().unwrap()).sum();
    assert_eq!(sent2.raw, total2 - resumed_at, "the second round sent only the rest: {from:?}");
    assert_eq!(prepares_of(&id), 1, "a new prepare drops the chat's earlier ones");

    // Another round: only what the chat logged since its last prepare.
    src.request(method::SESSION_PROMPT, prompt(&id, "p-late", "late")).await.unwrap();
    let (third, stage3, _, sent3) = round(&mut src, &mut dst, &id, link, None).await;
    assert_eq!(stage3, stage_id, "the same stage, taken up again");
    assert!(sent3.raw * 10 < total2, "round three sent only the delta: {sent3:?} of {total2}");
    let done =
        dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage3})).await.unwrap();
    assert_eq!(done["afterSeq"], third["afterSeq"], "{done}");

    src.request(method::SESSION_PROMPT, prompt(&id, "p-last", "last")).await.unwrap();
    move_staged(&mut src, &mut dst, &id, &third, &stage3, false).await;
    let (_, ran) = whole_log(&mut dst, &id).await;
    let want: Vec<String> = (0..6)
        .map(|_| "chunks: 2500".to_owned())
        .chain(["mid", "late", "last"].map(str::to_owned))
        .collect();
    assert_eq!(ran, want, "every prompt ran once, in order, on the target");
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// A resumed stage whose bytes the source no longer holds as they are (the source's digest
/// differs) is written again from zero, and still finishes whole.
#[tokio::test]
async fn a_resumed_stage_the_source_does_not_match_is_written_again_from_zero() {
    let (dirs, mut src, mut dst) = two_local().await;
    let s =
        src.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    src.request(method::SESSION_PROMPT, prompt(&id, "p-0", "chunks: 2500")).await.unwrap();
    let link = Link { rate: None, zstd: false };
    let _ = round(&mut src, &mut dst, &id, link, Some(64 << 10)).await;
    let prepared = src.request("_acpmux/transfer_prepare", json!({"sessionId": id})).await.unwrap();
    let stage = dst
        .request("_acpmux/transfer_stage", json!({"manifest": prepared, "resume": true}))
        .await
        .unwrap();
    assert_eq!(stage["resumed"], true, "{stage}");
    // As if the source's bytes differed: start at zero, which the stage takes.
    let stage_id = stage["stageId"].as_str().unwrap().to_owned();
    let none = HashMap::new();
    page(&mut src, &mut dst, &prepared, &prepared["prepareId"], &stage_id, None, &none, link, None)
        .await;
    let done =
        dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id})).await.unwrap();
    assert_eq!(done["afterSeq"], prepared["afterSeq"], "{done}");
    move_staged(&mut src, &mut dst, &id, &prepared, &stage_id, false).await;
    assert_eq!(whole_log(&mut dst, &id).await.1, vec!["chunks: 2500".to_owned()]);
    for dir in dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// Before and after, on a link slowed to `ACPMUX_LIVE_BENCH_RATE` bytes a second (default
/// 1 MB/s, the direct lane link the 2026-11-22 incident measured): the freeze (begin to commit)
/// of a whole move, and of a live one (compressed rounds while the chat runs, then the tail).
/// `ACPMUX_LIVE_BENCH_PROMPTS` sizes the history (30: about 20 MB). Prints the numbers; asserts
/// the live freeze is a small share of the whole one and bounded.
#[tokio::test]
async fn a_live_move_freezes_for_the_tail_only_over_a_slow_link() {
    // Each daemon step of the move, timed (`hub/transfer_live.rs` `MoveSteps`).
    let _ = tracing_subscriber::fmt()
        .with_env_filter("acpmux::move_steps=debug")
        .with_writer(std::io::stderr)
        .try_init();
    let prompts: usize =
        std::env::var("ACPMUX_LIVE_BENCH_PROMPTS").ok().and_then(|v| v.parse().ok()).unwrap_or(30);
    let rate: f64 = std::env::var("ACPMUX_LIVE_BENCH_RATE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1_000_000.0);
    let mut rows = Vec::new();
    let mut freezes = HashMap::new();
    for mode in ["whole", "live"] {
        let (dirs, mut src, mut dst) = two_local().await;
        let s = src
            .request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []}))
            .await
            .unwrap();
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let filling = std::time::Instant::now();
        for n in 0..prompts {
            src.request(method::SESSION_PROMPT, prompt(&id, &format!("p-{n}"), "chunks: 2500"))
                .await
                .unwrap();
        }
        eprintln!("{mode}: {prompts} prompts in {} ms", filling.elapsed().as_millis());
        let history =
            src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap()["historyBytes"]
                .as_u64()
                .unwrap_or(0);
        let mut precopy = Sent::default();
        let mut precopy_ms = 0u128;
        let staged = if mode == "live" {
            let link = Link { rate: Some(rate), zstd: true };
            let started = std::time::Instant::now();
            let mut last = None;
            for n in 0..3 {
                // The chat keeps taking turns while it is copied.
                src.request(method::SESSION_PROMPT, prompt(&id, &format!("q-{n}"), "chunks: 50"))
                    .await
                    .unwrap();
                let took = std::time::Instant::now();
                let (prepared, stage_id, _, sent) =
                    round(&mut src, &mut dst, &id, link, None).await;
                eprintln!(
                    "live round {n}: {:.1} MB raw in {} ms",
                    sent.raw as f64 / 1e6,
                    took.elapsed().as_millis()
                );
                precopy.raw += sent.raw;
                precopy.wire += sent.wire;
                let small = sent.raw <= 8 << 20 && n > 0;
                last = Some((prepared, stage_id));
                if small {
                    break;
                }
            }
            let (prepared, stage_id) = last.unwrap();
            let took = std::time::Instant::now();
            dst.request("_acpmux/transfer_stage_finish", json!({"stageId": stage_id}))
                .await
                .unwrap();
            eprintln!("live stage_finish: {} ms", took.elapsed().as_millis());
            precopy_ms = started.elapsed().as_millis();
            Some((prepared, stage_id))
        } else {
            None
        };
        src.request(method::SESSION_PROMPT, prompt(&id, "p-last", "last")).await.unwrap();
        let link = Link { rate: Some(rate), zstd: mode == "live" };
        // The freeze: begin to commit, its bundle over the link.
        let started = std::time::Instant::now();
        let mut begin = json!({"sessionId": id});
        if let Some((prepared, _)) = &staged {
            begin["prepareId"] = prepared["prepareId"].clone();
            begin["afterSeq"] = prepared["afterSeq"].clone();
        }
        let begun = src.request("_acpmux/transfer_begin", begin).await.unwrap();
        let mut phases = vec![("begin", started.elapsed())];
        let mut receive = json!({"manifest": begun});
        if let Some((_, stage_id)) = &staged {
            receive["stageId"] = json!(stage_id);
        }
        let received = dst.request("_acpmux/transfer_receive", receive).await.unwrap();
        let receive_id = received["receiveId"].as_str().unwrap().to_owned();
        phases.push(("receive", started.elapsed()));
        let from = held(&mut src, &begun["transferId"], &received).await;
        phases.push(("digest", started.elapsed()));
        let epoch = begun["epoch"].as_u64();
        let froze = page(
            &mut src,
            &mut dst,
            &begun,
            &begun["transferId"],
            &receive_id,
            epoch,
            &from,
            link,
            None,
        )
        .await;
        phases.push(("pages", started.elapsed()));
        dst.request(
            "_acpmux/transfer_finish",
            json!({"receiveId": receive_id, "epoch": begun["epoch"]}),
        )
        .await
        .unwrap();
        phases.push(("finish", started.elapsed()));
        src.request(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begun["transferId"], "to": {"sessionId": id},
                   "epoch": begun["epoch"]}),
        )
        .await
        .unwrap();
        let freeze = started.elapsed();
        phases.push(("commit", freeze));
        let mut at = Duration::ZERO;
        let steps: Vec<String> = phases
            .iter()
            .map(|(name, end)| {
                let took = *end - at;
                at = *end;
                format!("{name} {} ms", took.as_millis())
            })
            .collect();
        eprintln!("{mode} freeze: {}", steps.join(", "));
        let (_, ran) = whole_log(&mut dst, &id).await;
        assert_eq!(ran.last().map(String::as_str), Some("last"), "{mode}");
        freezes.insert(mode, freeze);
        rows.push(format!(
            "| {mode} | {:.1} MB | {:.1} MB / {:.1} MB in {} ms | {:.2} MB / {:.2} MB | {} ms |",
            history as f64 / 1e6,
            precopy.raw as f64 / 1e6,
            precopy.wire as f64 / 1e6,
            precopy_ms,
            froze.raw as f64 / 1e6,
            froze.wire as f64 / 1e6,
            freeze.as_millis()
        ));
        for dir in dirs {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
    eprintln!(
        "link {:.0} KB/s, {prompts} prompts\n| move | history | pre-copy (raw / wire, time; chat live) | inside the freeze (raw / wire) | freeze |\n|---|---|---|---|---|\n{}",
        rate / 1e3,
        rows.join("\n")
    );
    let (whole, live) = (freezes["whole"], freezes["live"]);
    assert!(live * 5 < whole, "the live freeze {live:?} is a small share of the whole {whole:?}");
    assert!(live < Duration::from_secs(5), "the live freeze stays short: {live:?}");
}
