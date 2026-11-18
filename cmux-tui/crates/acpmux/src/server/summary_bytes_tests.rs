//! What one session row costs on the wire, and who reads each of its keys (the 2026-11-18 design
//! audit's class D: payloads carrying data no view reads). Leo's list holds 10,790 chats and
//! changes about 4 times a second,
//! each change sent to every watcher. A row sent every null, false and empty key it has (882 of a
//! lane's 3,046 bytes a row), and on each full connect the app read the whole list a second time
//! only to start a usage pass (31-38 MB at his size).
//!
//! Detectors: [`a_default_row_fits_its_byte_budget`] (a chat with nothing set),
//! [`every_summary_key_has_a_named_reader`] (a key no client reads fails here until it is named
//! or dropped) and [`a_usage_only_read_answers_no_rows`] (the app's usage trigger is no second
//! whole list). The bench prints the PR's table, the same command on base and head:
//! `cargo test -p acpmux --lib summary_bytes_bench -- --ignored --nocapture`.

use super::Origin;
use super::ack_latency_bench::Client;
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::sync::Arc;

/// Leo's list (2026-11-18).
const CHATS: usize = 10_790;
/// Live (not closed) chats per thousand, as one lane's list (38 of 1,379 on 2026-11-18).
const LIVE_PER_MILLE: usize = 28;

/// Who reads a key of a session row: `web` (webviews/src), `mac` (Packages/macOS), `ios`
/// (cmux-next-ios), `cli` (the acpmux CLI and TUI), `tui-core` (cmux-tui-core), `daemon` (acpmux
/// itself: the peer mirror, restores, the indicator).
type Readers = &'static [&'static str];

/// Whether a key holding null, false or `[]` is sent.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Sent {
    /// Always: a reader tells "absent" from its empty value, or merges a changed row into the
    /// one it holds (the pane's selected chat, `direct.ts` `this.summary = {...this.summary,
    /// ...session}`), so an omitted key would keep its old value there.
    Always,
    /// Only when it holds something: every reader takes absent as empty, and the pane does not
    /// read it from its merged row.
    WhenSet,
    /// Only when it holds something, as before this table: the pane reads it from its merged
    /// row, which keeps the last value it saw. Named so no key joins them unseen.
    SetOnly,
}

use Sent::{Always, SetOnly, WhenSet};

/// Every key a session row carries, its readers (found by a search of each client for the key,
/// 2026-11-18), and whether it is sent empty. A new key is named here with its reader, or not
/// added.
const READERS: &[(&str, Readers, Sent)] = &[
    // These three tell `peer_text.rs` an object is a row whose text it masks for a peer.
    ("sessionId", &["web", "mac", "ios", "cli", "daemon"], Always),
    ("name", &["web", "mac", "ios", "cli"], Always),
    ("nameGiven", &["cli"], WhenSet),
    ("harness", &["web", "mac", "ios", "cli", "daemon"], Always),
    ("family", &["web", "mac", "ios", "cli"], Always),
    ("cwd", &["web", "mac", "ios", "cli"], Always),
    ("status", &["web", "mac", "ios", "cli"], Always),
    ("state", &["web", "mac", "ios", "cli"], Always),
    ("stuckReason", &["cli"], WhenSet),
    ("stuckSince", &["cli"], WhenSet),
    ("stuckError", &["cli"], WhenSet),
    // A clear goes out as null (`stalled_turn.rs`): an older pane's merge kept a left-out one.
    ("loopEpisode", &["web"], Always),
    ("harnessSandboxFailed", &["cli"], WhenSet),
    // `ls_table.rs` reads it absent as an older daemon's row and falls back to the timestamp.
    ("harnessSandboxFailing", &["cli"], Always),
    ("agentSessionId", &["web", "mac", "ios", "cli"], Always),
    ("retiredAgentSessionIds", &["web"], SetOnly),
    ("createdAt", &["web", "mac", "ios", "cli"], Always),
    ("updatedAt", &["web", "mac", "ios", "cli"], Always),
    ("lastSeq", &["web", "mac", "ios", "cli", "daemon"], Always),
    ("transcriptSeq", &["web"], Always),
    ("eventCount", &["cli", "tui-core"], Always),
    ("turnCount", &["web", "ios"], Always),
    ("parentId", &["web", "mac"], Always),
    ("forkSeq", &["web", "mac"], Always),
    ("spawnedBy", &["web", "mac", "ios"], Always),
    ("parent", &["web", "mac", "ios"], Always),
    ("root", &["web", "mac", "ios"], Always),
    ("createdBy", &["mac", "cli"], WhenSet),
    ("pullRequests", &["web", "mac", "ios"], Always),
    ("startedBy", &["web", "mac", "ios"], Always),
    ("shortName", &["web", "mac"], Always),
    ("depth", &["web", "mac", "ios"], Always),
    ("children", &["web", "mac", "ios"], Always),
    ("title", &["web", "mac", "ios", "cli"], Always),
    ("titleSource", &["mac", "cli"], WhenSet),
    ("lastPrompt", &["web", "mac", "ios"], Always),
    ("preview", &["web", "mac", "ios"], Always),
    ("lastMessage", &["web", "mac", "ios"], Always),
    ("queued", &["web", "mac", "ios"], Always),
    ("queuePaused", &["web", "ios"], Always),
    ("personHold", &["cli"], WhenSet),
    ("waitsForSlot", &["web"], SetOnly),
    // An update reads a row without it as an older acpmux's.
    ("starting", &["web", "mac", "ios", "daemon"], Always),
    ("moving", &["web", "mac"], Always),
    ("movedTo", &["mac", "cli"], WhenSet),
    ("watching", &["web", "mac", "ios"], Always),
    ("steering", &["web"], Always),
    ("backgroundsWork", &["web"], Always),
    ("turn", &["web", "mac", "ios"], Always),
    // The pane keeps its queue on a change without one (`direct.ts`).
    ("queue", &["web", "mac", "ios"], Always),
    ("pendingPermissions", &["web", "mac", "ios"], Always),
    ("waitingOn", &["web", "ios"], Always),
    ("waitingPrompt", &["web"], Always),
    ("inputSince", &["web", "ios"], Always),
    ("currentModeId", &["web", "ios"], Always),
    ("model", &["web", "mac", "ios"], Always),
    ("effort", &["web", "mac", "ios"], Always),
    ("policy", &["web", "mac", "ios"], Always),
    ("enforcement", &["web", "ios"], Always),
    ("rules", &["web", "mac", "ios"], Always),
    ("tags", &["web", "mac", "ios"], Always),
    ("stateSeq", &["web", "ios"], Always),
    ("unread", &["web", "mac", "ios"], Always),
    ("unreadTurns", &["web"], Always),
    ("seenSeq", &["web"], Always),
    ("lastReturn", &["web"], Always),
    ("lastTurn", &["web", "ios"], Always),
    ("retry", &["web", "mac", "ios"], Always),
    ("retryDeciding", &["web"], SetOnly),
    ("attached", &["web", "mac", "ios"], Always),
    ("shown", &["web", "mac", "ios"], Always),
    ("tools", &["web", "mac", "ios"], SetOnly),
    ("toolsMutable", &["web"], SetOnly),
    ("mcpServers", &["web", "mac", "ios"], Always),
    // The peer mirror decides them again for a row without them, as an older peer's.
    ("indicator", &["web", "mac", "ios", "daemon"], Always),
    ("lane", &["web", "mac", "ios", "daemon"], Always),
    ("lifecycleReceipt", &["web"], SetOnly),
    ("peer", &["web", "mac", "ios"], SetOnly),
    ("usageStats", &["web", "mac"], SetOnly),
    ("timeBreakdown", &["web"], SetOnly),
    ("qualifiedSessionId", &["web", "mac", "cli"], Always),
    ("sessionReceipt", &["cli"], Always),
    ("recoveredAfter", &["daemon"], WhenSet),
    ("gitBranch", &["web"], Always),
    ("coldArchive", &["web", "mac"], SetOnly),
    ("additionalDirectories", &["web", "mac"], SetOnly),
    ("subagentsWorkingSince", &["tui-core"], WhenSet),
    ("heldMessages", &["cli"], WhenSet),
    ("subsessionsWaiting", &["daemon"], Always),
    ("subsessionsWaitingSince", &["daemon"], WhenSet),
    ("subagentsRunning", &["mac"], Always),
    ("subagentNames", &["mac"], WhenSet),
    ("commandsRunning", &["mac"], Always),
    ("hostBuildDiffers", &["cli"], WhenSet),
    ("hostBuild", &["cli"], WhenSet),
    ("respawnPending", &["cli"], WhenSet),
    ("usageWarnings", &["mac", "cli"], WhenSet),
];

/// The bytes of a row of a chat with nothing set ([`default_row`]): 1,449 on base 0ecbcadd62.
const DEFAULT_ROW_BUDGET: usize = 1_150;

fn empty(value: &Value) -> bool {
    match value {
        Value::Null | Value::Bool(false) => true,
        Value::Array(items) => items.is_empty(),
        _ => false,
    }
}

fn readers(key: &str) -> Option<(Readers, Sent)> {
    READERS.iter().find(|(k, ..)| *k == key).map(|(_, readers, sent)| (*readers, *sent))
}

fn memory_hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    crate::hub::Hub::new(config, store)
}

/// A closed chat with nothing set: no title, prompt, lineage, turn or tag.
fn default_row() -> Value {
    let hub = memory_hub();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "01a17082-0490-7a21-acbb-57ab336c4e57",
        "name": "claude-1", "harness": "claude", "cwd": "/home/cmux/Projects/leo-workspace",
        "status": "closed", "createdAt": 1_793_305_423_848u64, "updatedAt": 1_793_305_423_848u64,
    }))
    .unwrap();
    let session = hub.insert_test_session(meta);
    hub.session_list_summary(&session)
}

/// Chat `i` of [`CHATS`], shaped as one lane's (2026-11-18): about 3% live, 28% started by
/// another chat, 2% with a pull request, each with a title, a prompt, a reply and its last turn.
fn chat(i: usize) -> Value {
    let live = i % 1000 < LIVE_PER_MILLE;
    let id = format!("01a1{i:04x}-0490-7a21-acbb-57ab336c4e57");
    let mut meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": format!("codex-{i}"),
        "harness": if i % 3 == 0 { "claude" } else { "codex" },
        "family": if i % 3 == 0 { "claude" } else { "codex" },
        "cwd": "/home/cmux/Projects/leo-workspace",
        "agentSessionId": format!("019a{i:04x}-5af8-79a2-b224-82c697a12687"),
        "status": if live { "idle" } else { "closed" },
        "createdAt": 1_793_000_000_000u64 + i as u64, "updatedAt": 1_793_300_000_000u64 + i as u64,
        "lastSeq": 400, "transcriptSeq": 380, "eventCount": 400, "turnCount": 3,
        "title": format!("Fix the session row's wire size, part {i} of the list audit for Leo"),
        "titleSource": "generated",
        "lastPrompt": "x".repeat(208), "preview": "y".repeat(241), "unread": i % 7 == 0,
        "permissionPolicy": "allow",
        "gitBranch": "lane/summary-slim-wire",
        "lastTurn": {"endedAt": 1_793_305_423_848u64, "promptId": format!("01a1894d-af4d-78e2-82bd-{i:012x}"),
            "status": "completed", "stopReason": "end_turn", "turnId": format!("01a1894d-af4d-7fa2-b52d-{i:012x}")},
    });
    if i % 100 < 28 {
        let parent = format!("01a1{:04x}-0490-7a21-acbb-57ab336c4e57", i - i % 100 + 50);
        meta["lineage"] = json!({"parent": parent, "root": parent, "depth": 1});
        meta["tags"] = json!({"lane.reportsTo": {"value": parent}});
    }
    if i % 50 == 0 {
        meta["pullRequests"] =
            json!([format!("https://github.com/manaflow-ai/cmux/pull/{}", 40_000 + i)]);
    }
    meta
}

fn chats_hub(n: usize) -> Arc<crate::hub::Hub> {
    let hub = memory_hub();
    for i in 0..n {
        hub.insert_test_session(serde_json::from_value(chat(i)).unwrap());
    }
    hub
}

/// The rows of [`chat`]'s first 100.
fn rich_rows() -> Vec<Value> {
    let hub = chats_hub(100);
    hub.sessions().iter().map(|s| hub.session_list_summary(s)).collect()
}

/// The bytes of one `_acpmux/session_changed` of `row` as a list watcher hears it (`deliver`).
fn notice_bytes(row: &Value) -> usize {
    let params = json!({"sessionId": row["sessionId"], "session": row, "kind": "status",
        "recordKind": "status", "seq": 401, "listSeq": 90_000});
    Message::notification(method::MUX_SESSION_CHANGED, params).to_line().len()
}

/// Every reply of `m {params}` and the pages after it, as the app follows them
/// (`AgentTurnStateFeed.pageRequest`, `usageRequest(cursor:)`): their bytes and rows.
async fn followed(client: &Client, m: &str, params: Value) -> (usize, usize) {
    let (mut bytes, mut rows) = (0, 0);
    let (mut reply, mut size) = client.call(m, params.clone()).await;
    for _ in 0..1_000 {
        assert!(reply.get("error").is_none(), "{m}: {}", reply["error"]);
        bytes += size;
        rows += reply["result"]["sessions"].as_array().map_or(0, Vec::len);
        let Some(cursor) = reply["result"]["nextCursor"].as_str().map(str::to_owned) else {
            return (bytes, rows);
        };
        let mut next = params.clone();
        if let Some(next) = next.as_object_mut() {
            next.remove("enabled");
            next.insert("cursor".into(), Value::String(cursor));
        }
        (reply, size) = client.call(method::MUX_SESSIONS, next).await;
    }
    panic!("{m}: past 1,000 pages");
}

/// The app's usage trigger (`AgentTurnStateFeed.usageRequest`).
fn usage_trigger() -> Value {
    json!({"usage": true, "usageOnly": true})
}

/// A row of a chat with nothing set stays under its budget, and sends no empty key every reader
/// takes absent as empty.
#[test]
fn a_default_row_fits_its_byte_budget() {
    let row = default_row();
    let bytes = serde_json::to_string(&row).unwrap().len();
    let sent_empty: Vec<&String> = row
        .as_object()
        .unwrap()
        .iter()
        .filter(|(key, value)| empty(value) && readers(key).is_none_or(|(_, sent)| sent == WhenSet))
        .map(|(key, _)| key)
        .collect();
    assert!(sent_empty.is_empty(), "empty keys no reader needs sent: {sent_empty:?}");
    assert!(bytes <= DEFAULT_ROW_BUDGET, "a default row is {bytes} bytes: {row}");
}

/// Every key of a session row (the protocol's `SessionSummary` and what the daemon adds to it)
/// is in [`READERS`] with a reader, and only a key the pane does not read from its merged row is
/// sent only when set.
#[test]
fn every_summary_key_has_a_named_reader() {
    let spec: Value =
        serde_json::from_str(include_str!("../../spec/acpmux-protocol.json")).unwrap();
    let mut keys: BTreeSet<String> = spec["types"]["SessionSummary"]["properties"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    let default = default_row();
    keys.extend(default.as_object().unwrap().keys().cloned());
    for row in rich_rows() {
        keys.extend(row.as_object().unwrap().keys().cloned());
    }
    let unnamed: Vec<&String> = keys.iter().filter(|key| readers(key).is_none()).collect();
    assert!(
        unnamed.is_empty(),
        "keys with no named reader (name one or drop the key): {unnamed:?}"
    );
    for (key, readers, sent) in READERS {
        assert!(!readers.is_empty(), "{key}: no reader");
        assert!(
            *sent != Always || default.get(*key).is_some(),
            "{key}: always sent, but a default row has none"
        );
        // The pane merges a changed row into its selected chat's: an omitted key it reads would
        // keep its old value there.
        assert!(
            *sent != WhenSet || !readers.contains(&"web"),
            "{key}: the pane reads it from a merged row, so it is sent empty"
        );
    }
}

/// The app's usage trigger runs the pass and answers no rows: the rows the pass changed reach
/// every watcher as `session_changed`, and the watch's own list carries the rest.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_usage_only_read_answers_no_rows() {
    let hub = chats_hub(50);
    let client = Client::on(&hub, Origin::Local).await;
    hub.usage_pass_due_for_test();
    let (passes, _) = hub.usage_passes_for_test();
    let (bytes, rows) = followed(&client, method::MUX_SESSIONS, usage_trigger()).await;
    assert_eq!(rows, 0, "the trigger answers no rows ({bytes} bytes)");
    assert!(bytes < 512, "the trigger's reply is {bytes} bytes");
    // The pass runs whether or not the reply waited for it.
    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        while hub.usage_passes_for_test().0 == passes {
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the trigger runs a usage pass");
}

/// The PR's table: bytes a row, a whole list and a `session_changed` at [`CHATS`] chats, and what
/// one app connect is sent (its watch and its usage trigger).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: run with --ignored --nocapture"]
async fn summary_bytes_bench() {
    let hub = chats_hub(CHATS);
    let rows: Vec<Value> = hub.sessions().iter().map(|s| hub.session_list_summary(s)).collect();
    let row_bytes: usize = rows.iter().map(|row| serde_json::to_string(row).unwrap().len()).sum();
    let live: Vec<&Value> = rows.iter().filter(|row| row["status"] != "closed").collect();
    let notice: usize = live.iter().map(|row| notice_bytes(row)).sum::<usize>() / live.len().max(1);
    let client = Client::on(&hub, Origin::Local).await;
    let (watch, watched) = followed(&client, method::MUX_WATCH, json!({"enabled": true})).await;
    let (usage, usage_rows) = followed(&client, method::MUX_SESSIONS, usage_trigger()).await;
    let default = serde_json::to_string(&default_row()).unwrap().len();
    eprintln!(
        "SUMMARY-BYTES chats={} live={} bytes_per_row={} whole_list={} session_changed={} default_row={}",
        rows.len(),
        live.len(),
        row_bytes / rows.len(),
        row_bytes,
        notice,
        default
    );
    eprintln!(
        "SUMMARY-BYTES app_connect watch={watch} ({watched} rows) usage={usage} ({usage_rows} rows) total={}",
        watch + usage
    );
}
