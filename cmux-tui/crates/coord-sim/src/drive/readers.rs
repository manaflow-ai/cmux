//! The clients that read while the coordinators write, as the apps read.
//!
//! - A follower per session: one connection attached the way NEXT's chat pane attaches
//!   (`_acpmux/attach`, `eventStream: true`, `waitLogs: false`, a 400-record / 128 KiB page),
//!   kept for the whole run. It stamps every tag on every line the daemon pushes: that is the
//!   event's reader-visible time.
//! - Switching readers: each loops list -> open (detach the last chat, attach another) ->
//!   scroll (older pages, `_acpmux/events` `beforeSeq`, 2000 records / 1 MiB as the pane's
//!   `olderPage`) -> search (`_acpmux/session_search`), and records each call's latency.

use super::Ops;
use super::rpc::Conn;
use crate::agent::{Tag, find_tags, now_us};
use crate::rng::Rng;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const CALL: Duration = Duration::from_secs(60);
/// The kinds a follower asks for: the transcript, plus the agent updates a page leaves out, so
/// every update the stand-in agent sends reaches it.
const FOLLOW_KINDS: &[&str] = &[
    "transcript",
    "usage_update",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
];
const OPEN_PAGE_BYTES: u64 = 128 * 1024;
const OLDER_PAGE_BYTES: u64 = 1024 * 1024;
const OLDER_PAGE_RECORDS: u64 = 2000;
const SEARCHES: &[&str] = &["kernel lane", "merge patch", "graph", "delta order node"];

/// What a follower saw: each tag with its arrival time.
#[derive(Default)]
pub struct Seen {
    pub tags: Vec<(Tag, u64)>,
    pub lagged: u64,
    pub notes: u64,
    pub bytes: u64,
}

pub struct Follower {
    pub conn: Arc<Conn>,
    pub seen: Arc<Mutex<Seen>>,
}

fn attach_params(sid: &str, kinds: &[&str]) -> Value {
    json!({"sessionId": sid, "waitLogs": false, "limit": 400, "maxBytes": OPEN_PAGE_BYTES,
        "kinds": kinds, "eventStream": true, "visible": true})
}

/// The tags a live note delivers: only a stream frame (`_acpmux/event`, `session/update`) carries
/// an event. Other notes (a `_acpmux/session_changed` row quoting the newest reply preview, tool
/// title or plan step) repeat a tag the stream already gave, and are not counted.
pub fn stream_tags(line: &str) -> Vec<Tag> {
    let method = serde_json::from_str::<Value>(line)
        .ok()
        .and_then(|v| v.get("method").and_then(Value::as_str).map(str::to_owned));
    match method.as_deref() {
        Some("_acpmux/event" | "session/update") => find_tags(line),
        _ => Vec::new(),
    }
}

pub fn follow<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    socket: &Path,
    c: u32,
    sid: &str,
    ops: &Ops,
) -> Result<Follower, String> {
    let seen: Arc<Mutex<Seen>> = Arc::default();
    let sink = seen.clone();
    let conn = Conn::connect(
        s,
        socket,
        Box::new(move |line, at| {
            let tags = stream_tags(line);
            if let Ok(mut s) = sink.lock() {
                s.notes += 1;
                s.bytes += line.len() as u64;
                if line.contains("\"_acpmux/lagged\"") {
                    s.lagged += 1;
                }
                s.tags.extend(tags.into_iter().map(|t| (t, at)));
            }
        }),
    )?;
    let t = now_us();
    let r = conn.call("_acpmux/attach", attach_params(sid, FOLLOW_KINDS), CALL);
    ops.op("follow_attach", None, c, t, &r);
    r?;
    Ok(Follower { conn, seen })
}

/// One switching reader until `stop`.
pub fn switcher<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    socket: &Path,
    reader: u32,
    sessions: Vec<(u32, String)>,
    ops: Ops,
    stop: Arc<AtomicBool>,
    seed: u64,
) -> std::thread::ScopedJoinHandle<'s, ()> {
    let socket = socket.to_path_buf();
    s.spawn(move || {
        let live = Arc::new(AtomicU64::new(0));
        let counter = live.clone();
        let Ok(conn) = Conn::connect(
            s,
            &socket,
            Box::new(move |_, _| {
                counter.fetch_add(1, Ordering::Relaxed);
            }),
        ) else {
            return;
        };
        let mut rng = Rng::new(seed).fork(reader as u64);
        let mut shown: Option<(u32, String)> = None;
        while !stop.load(Ordering::Relaxed) {
            // The session list, page by page (the pane's first read, and again after changes).
            let mut cursor: Option<String> = None;
            for _ in 0..50 {
                let mut p = json!({"limit": 200});
                if let Some(c) = &cursor {
                    p["cursor"] = json!(c);
                }
                let t = now_us();
                let r = conn.call("_acpmux/sessions", p, CALL);
                ops.op("list", Some(reader), u32::MAX, t, &r);
                cursor = r.ok().and_then(|r| {
                    r.v.pointer("/result/nextCursor").and_then(Value::as_str).map(String::from)
                });
                if cursor.is_none() {
                    break;
                }
            }
            let pick = rng.below(sessions.len() as u64) as usize;
            let Some((c, sid)) = sessions.get(pick).cloned() else { break };
            if let Some((pc, psid)) = shown.take() {
                let t = now_us();
                let r = conn.call("_acpmux/detach", json!({"sessionId": psid}), CALL);
                ops.op("detach", Some(reader), pc, t, &r);
            }
            let t = now_us();
            let r = conn.call("_acpmux/attach", attach_params(&sid, &["transcript"]), CALL);
            ops.op("open", Some(reader), c, t, &r);
            let mut first = r.ok().and_then(|r| min_seq(&r.v));
            shown = Some((c, sid.clone()));
            // Scroll up a few pages.
            for _ in 0..(1 + rng.below(4)) {
                let Some(before) = first.filter(|s| *s > 1) else { break };
                let t = now_us();
                let r = conn.call(
                    "_acpmux/events",
                    json!({"sessionId": sid, "beforeSeq": before, "limit": OLDER_PAGE_RECORDS,
                        "maxBytes": OLDER_PAGE_BYTES, "kinds": ["transcript"]}),
                    CALL,
                );
                ops.op("scroll", Some(reader), c, t, &r);
                first = r.ok().and_then(|r| min_seq(&r.v));
            }
            let q =
                SEARCHES.get(rng.below(SEARCHES.len() as u64) as usize).copied().unwrap_or("lane");
            let t = now_us();
            let r = conn.call(
                "_acpmux/session_search",
                json!({"sessionId": sid, "query": q, "limit": 50}),
                CALL,
            );
            ops.op("search", Some(reader), c, t, &r);
            std::thread::sleep(Duration::from_millis(200 + rng.below(400)));
        }
        ops.raw(
            json!({"op": "reader_live_notes", "reader": reader, "n": live.load(Ordering::Relaxed)}),
        );
        conn.close();
    })
}

fn min_seq(v: &Value) -> Option<u64> {
    v.pointer("/result/events")?
        .as_array()?
        .iter()
        .filter_map(|e| e.get("seq").and_then(Value::as_u64))
        .min()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_row_notice_quoting_a_tag_is_not_a_second_delivery() {
        let tag = crate::agent::tag(3, 7, 0, 1_000);
        let event = json!({"jsonrpc": "2.0", "method": "_acpmux/event", "params": {"record": {"msg":
            {"method": "session/update", "params": {"update": {"sessionUpdate": "tool_call", "title": tag}}}}}});
        let row = json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": {"row":
            {"preview": tag, "toolTitle": tag, "planStep": tag}}});
        let n: usize =
            [event.to_string(), row.to_string()].iter().map(|l| stream_tags(l).len()).sum();
        assert_eq!(n, 1);
    }
}
