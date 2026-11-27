//! Compaction points at ranges (`hub/compaction_outline.rs`, RFD 0075): a `compaction_summary`
//! is followed by a `compaction_outline` record naming the turns it covers, and
//! `_acpmux/history/read` (the `chat_history` MCP tool) reads an outline, a range's digest or one
//! record by seq from the chat's pack. The test is the client, as the MCP server is.

use super::*;

const READ: &str = "_acpmux/history/read";

/// The records of `id` of this kind, newest last.
async fn records(c: &mut TestClient, id: &str, kind: &str) -> Vec<Value> {
    records_after(c, id, kind, 0).await
}

/// The same, of the records after `after`, read page by page (a page is capped).
async fn records_after(c: &mut TestClient, id: &str, kind: &str, after: u64) -> Vec<Value> {
    records_cursor(c, id, kind, &mut after.clone()).await
}

/// The records of this kind after `*cursor`; the cursor moves to the last record read, so the
/// next call reads only what came since.
async fn records_cursor(c: &mut TestClient, id: &str, kind: &str, cursor: &mut u64) -> Vec<Value> {
    let mut found = Vec::new();
    loop {
        let page = c
            .request(
                method::MUX_EVENTS,
                json!({"sessionId": id, "afterSeq": *cursor, "limit": 5000}),
            )
            .await
            .unwrap();
        let events = page["events"].as_array().unwrap();
        found.extend(events.iter().filter(|e| e["kind"] == kind).cloned());
        match events.last().and_then(|e| e["seq"].as_u64()) {
            Some(last) => *cursor = last,
            None => break,
        }
        if page["hasMore"].as_bool() != Some(true) {
            break;
        }
    }
    found
}

/// Waits for the `compaction_outline` record number `n` (1 is the first) of `id`.
async fn outline_record(c: &mut TestClient, id: &str, n: usize) -> Value {
    outline_record_after(c, id, n, 0).await
}

async fn outline_record_after(c: &mut TestClient, id: &str, n: usize, after: u64) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(900);
    let (mut cursor, mut seen) = (after, Vec::new());
    loop {
        seen.extend(records_cursor(c, id, "compaction_outline", &mut cursor).await);
        if let Some(r) = seen.get(n - 1) {
            return r.clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "no compaction_outline record came");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn say(c: &mut TestClient, id: &str, text: &str) {
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    c.request(method::SESSION_PROMPT, prompt(id, &format!("say-{n}"), text)).await.unwrap();
}

#[tokio::test]
async fn a_compaction_summary_is_followed_by_the_outline_of_the_turns_it_covers_and_each_reads_back()
 {
    let (dirs, mut c, _other) = two_local().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    say(&mut c, &id, "alpha: first question").await;
    say(&mut c, &id, "tool-turn: 2000").await;
    say(&mut c, &id, "chunks: 40").await;
    say(&mut c, &id, "compact-summary: the summary text").await;
    say(&mut c, &id, "beta: after the compaction").await;

    let outline = outline_record(&mut c, &id, 1).await;
    let msg = &outline["msg"];
    assert_eq!(outline["dir"], "mux");
    assert_eq!(msg["session"], id.as_str());
    let turns = msg["turns"].as_array().unwrap();
    // The summary's own turn is the last the summary covers; the beta turn is after it.
    assert_eq!(turns.len(), 4, "{msg}");
    let asks: Vec<&str> = turns.iter().map(|t| t["ask"].as_str().unwrap()).collect();
    assert_eq!(
        asks,
        [
            "alpha: first question",
            "tool-turn: 2000",
            "chunks: 40",
            "compact-summary: the summary text"
        ]
    );
    let last_line = msg["lastLine"].as_u64().unwrap();
    for t in turns {
        let range = t["range"].as_str().unwrap();
        let (name, lines) = range.rsplit_once('@').unwrap();
        let (first, last) = lines.split_once('-').unwrap();
        assert_eq!(name, id);
        let (first, last): (u64, u64) = (first.parse().unwrap(), last.parse().unwrap());
        assert_eq!(t["records"].as_u64().unwrap(), last - first + 1, "{t}");
        assert!(t["at"].as_u64().unwrap() > 0, "{t}");
        assert!(last <= last_line);
        // Every named range reads back, and is the turn that was asked.
        let digest = c.request(READ, json!({"sessionId": id, "range": range})).await.unwrap();
        let text = digest["text"].as_str().unwrap();
        assert!(text.contains(t["ask"].as_str().unwrap()), "{range}: {text}");
        assert!(text.len() <= 32 * 1024 + 200, "{} bytes", text.len());
    }

    // The tool call's result is cut to 600 bytes in the digest, naming the seq that has it whole.
    let tool_range = turns[1]["range"].as_str().unwrap();
    let digest = c.request(READ, json!({"sessionId": id, "range": tool_range})).await.unwrap();
    let text = digest["text"].as_str().unwrap();
    assert!(text.contains("echo hi"), "{text}");
    assert!(text.contains(&"r".repeat(600)) && !text.contains(&"r".repeat(601)), "{text}");
    assert!(text.contains("result (completed, 2000 bytes)"), "{text}");
    let seq: u64 = text
        .lines()
        .find(|l| l.contains("more bytes: session-pack seq"))
        .and_then(|l| l.trim_end_matches(']').rsplit(' ').next())
        .and_then(|n| n.parse().ok())
        .unwrap_or_else(|| panic!("no seq to fetch the rest: {text}"));
    let whole = c.request(READ, json!({"sessionId": id, "seq": seq})).await.unwrap();
    assert_eq!(whole["mode"], "record");
    let record: Value = serde_json::from_str(whole["text"].as_str().unwrap()).unwrap();
    assert_eq!(record["seq"], seq);
    assert!(whole["text"].as_str().unwrap().contains(&"r".repeat(2000)));
    assert_eq!(whole["nextOffset"], Value::Null);

    // The outline: all turns the pack holds (the beta turn too once packed fresh), or only the
    // ones the compaction covered.
    let covered = c.request(READ, json!({"sessionId": id, "compacted": true})).await.unwrap();
    assert_eq!(covered["turns"].as_array().unwrap().len(), 4, "{covered}");
    assert_eq!(covered["turns"], msg["turns"]);
    let all = c.request(READ, json!({"sessionId": id, "fresh": true})).await.unwrap();
    let all_turns = all["turns"].as_array().unwrap();
    assert_eq!(all_turns.len(), 5, "{all}");
    assert_eq!(all_turns[4]["ask"], "beta: after the compaction");
    assert!(all["text"].as_str().unwrap().contains(&format!("{id}@")));
    // A limit and a page before: the newest turn alone, then the one before it.
    let newest = c.request(READ, json!({"sessionId": id, "limit": 1})).await.unwrap();
    assert_eq!(newest["turns"][0]["ask"], "beta: after the compaction");
    assert_eq!(newest["olderTurns"], 4);
    let first_line = newest["turns"][0]["range"].as_str().unwrap();
    let first_line: u64 =
        first_line.rsplit_once('@').unwrap().1.split('-').next().unwrap().parse().unwrap();
    let older =
        c.request(READ, json!({"sessionId": id, "limit": 1, "before": first_line})).await.unwrap();
    assert_eq!(older["turns"][0]["ask"], "compact-summary: the summary text");

    // A record newer than the pack is read from the log; a record that is not there is refused.
    let seqs: Vec<u64> = records(&mut c, &id, "user_message")
        .await
        .iter()
        .map(|e| e["seq"].as_u64().unwrap())
        .collect();
    let beta = c.request(READ, json!({"sessionId": id, "seq": seqs[4]})).await.unwrap();
    assert!(beta["text"].as_str().unwrap().contains("beta: after the compaction"));
    let missing = c.request(READ, json!({"sessionId": id, "seq": 99_999_999u64})).await;
    assert!(missing.is_err(), "{missing:?}");
    // Another chat's range is refused.
    let other = c.request(READ, json!({"sessionId": id, "range": "other-chat@0-3"})).await;
    assert!(other.is_err(), "{other:?}");

    // The record is read by every reader of the log, drawn by none: the transcript fold takes
    // it as it takes any mux record it does not list.
    assert!(!records(&mut c, &id, "compaction_outline").await.is_empty());
    for d in dirs {
        let _ = std::fs::remove_dir_all(d);
    }
}

#[tokio::test]
async fn a_second_compaction_outlines_the_turns_since_through_its_own_summary() {
    let (dirs, mut c, _other) = two_local().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    say(&mut c, &id, "one").await;
    say(&mut c, &id, "compact-summary: first").await;
    let first = outline_record(&mut c, &id, 1).await;
    say(&mut c, &id, "two").await;
    say(&mut c, &id, "compact-summary: second").await;
    let second = outline_record(&mut c, &id, 2).await;
    assert_eq!(first["msg"]["turns"].as_array().unwrap().len(), 2);
    assert_eq!(second["msg"]["turns"].as_array().unwrap().len(), 4);
    assert!(second["msg"]["summarySeq"].as_u64() > first["msg"]["summarySeq"].as_u64());
    let covered = c.request(READ, json!({"sessionId": id, "compacted": true})).await.unwrap();
    assert_eq!(covered["turns"].as_array().unwrap().len(), 4, "{covered}");
    for d in dirs {
        let _ = std::fs::remove_dir_all(d);
    }
}

/// The bytes of the log's files under `dir` (the pack store is left out).
fn log_bytes(dir: &std::path::Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    entries
        .filter_map(Result::ok)
        .map(|e| match e.metadata() {
            Ok(m) if m.is_dir() && e.file_name() != "history-pack" => log_bytes(&e.path()),
            Ok(m) if m.is_file() && e.path().to_string_lossy().contains("events") => m.len(),
            _ => 0,
        })
        .sum()
}

/// A chat over 50 MB: each read is a few to tens of milliseconds on an idle machine. A
/// measurement (`--ignored --nocapture` prints the numbers): its limit is wall-clock time, and
/// the outline is made at the lowest CPU priority, so on a loaded machine both run long.
#[tokio::test]
#[ignore = "a measurement: wall-clock read times on a 50 MB chat"]
async fn a_50_mb_chat_reads_its_outline_a_digest_and_a_record_in_milliseconds() {
    let (dirs, mut c, _other) = two_local().await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // About 0.67 MB of log a prompt (`a_50_mb_chat_starts_on_a_second_daemon_from_its_tail`).
    for n in 0..80 {
        c.request(method::SESSION_PROMPT, prompt(&id, &format!("p-{n}"), "chunks: 2500"))
            .await
            .unwrap();
    }
    let started = std::time::Instant::now();
    say(&mut c, &id, "compact-summary: the summary").await;
    let turn_ms = started.elapsed().as_millis();
    let outline = outline_record(&mut c, &id, 1).await;
    let record_ms = started.elapsed().as_millis();
    let turns = outline["msg"]["turns"].as_array().unwrap();
    assert_eq!(turns.len(), 81, "{}", outline["msg"]);

    let mut timed = Vec::new();
    let mut time = |what: &str, ms: u128| timed.push(format!("{what} {ms} ms"));
    let t = std::time::Instant::now();
    let first = c.request(READ, json!({"sessionId": id})).await.unwrap();
    time("outline (first call)", t.elapsed().as_millis());
    assert!(first["text"].as_str().unwrap().len() < 64 * 1024);
    let mut worst = 0u128;
    for (what, params) in [
        ("outline", json!({"sessionId": id})),
        ("outline limit 200", json!({"sessionId": id, "limit": 200})),
        ("outline compacted", json!({"sessionId": id, "compacted": true})),
        ("digest of a turn", json!({"sessionId": id, "range": turns[40]["range"]})),
        ("digest of the last turn", json!({"sessionId": id, "range": turns[80]["range"]})),
    ] {
        let t = std::time::Instant::now();
        let a = c.request(READ, params).await.unwrap();
        let ms = t.elapsed().as_millis();
        time(what, ms);
        worst = worst.max(ms);
        assert!(a["text"].as_str().unwrap().len() <= 64 * 1024, "{what}");
    }
    let one = records(&mut c, &id, "user_message").await[40]["seq"].as_u64().unwrap();
    let t = std::time::Instant::now();
    let a = c.request(READ, json!({"sessionId": id, "seq": one})).await.unwrap();
    time("record by seq", t.elapsed().as_millis());
    worst = worst.max(t.elapsed().as_millis());
    assert!(a["text"].as_str().unwrap().contains("chunks: 2500"));
    let raw = log_bytes(&dirs[0]);
    eprintln!(
        "50 MB chat ({raw} bytes of log on disk): the compaction prompt returned in {turn_ms} ms, \
         the outline record was in the log {record_ms} ms after it started; reads: {}",
        timed.join(", ")
    );
    assert!(worst < 100, "a read took {worst} ms: {timed:?}");
    for d in dirs {
        let _ = std::fs::remove_dir_all(d);
    }
}
