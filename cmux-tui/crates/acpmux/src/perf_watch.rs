//! The live perf commentator (Leo, 2026-11-18: "a debug toggle specifically for CMUX next ... just
//! some sort of watcher that doesn't really affect anything ... It's like a sort of commentator on
//! like what like sort of weird and wacky things are going on in the app").
//!
//! Off by default. While off every hook is one relaxed atomic load ([`on`]) and nothing else: no
//! lock, no clock read, no allocation. `_acpmux/perf {op:"on"}` (the chat Inspector's Perf tab,
//! `cmux debug perf on`, `acpmux perf on`) turns it on until `off` or the daemon exits.
//!
//! While on it keeps, for the last [`WINDOW_MS`]:
//! - spans: the moments people feel (new chat to first token, workspace switch to a settled
//!   transcript, page load, a slow request), each with its parts as a waterfall. The daemon
//!   times its own requests; the chat page reports the parts only it sees (`report`);
//! - the data meter: bytes per channel and label (daemon IPC to this Mac's app and CLIs, the peer
//!   link and the web origin for Cloud and remote, chat logs read from disk), ranked as hot zones;
//! - notes: plain-language comments when something is off against [`BUDGETS`] (a span over
//!   budget, a reply far larger than its view, a whole chat log read for one send, a list that
//!   re-rendered 14 times in 200 ms, a main-thread stall), each said at most once per
//!   [`NOTE_QUIET_MS`] per kind and subject, at most [`NOTES_PER_MINUTE`] a minute in all.
//!
//! Everything it records is one event stream: `_acpmux/perf {op:"read", after, waitMs}` long-polls
//! it (`cmux debug perf --follow --json`), and `$ACPMUX_HOME/perf-watch.jsonl` gets each event as a
//! line while on, so an agent can tail it (rotated once past [`FILE_CAP`]). `op:"snapshot"` is the
//! last minute in one object: the Inspector's "Copy diagnosis".
//!
//! It only observes: no hook changes what it measures, and no hook waits on it (the lock is held
//! for a few map updates, never across I/O other than the append of one short line).

use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::no_panic::LockExt;

/// How far back the stream, the meter's ranking and a snapshot reach.
pub const WINDOW_MS: u64 = 60_000;
/// Events kept at most (the oldest go first past it).
const EVENTS_CAP: usize = 4_000;
/// Meter keys kept at most: a label can come from a client's name.
const METER_KEYS: usize = 512;
/// One note per kind and subject in this long.
pub const NOTE_QUIET_MS: u64 = 30_000;
/// Notes said at most per minute, in all; past it they are counted as quieted.
pub const NOTES_PER_MINUTE: usize = 20;
/// The tail file is rotated to `.1` once past this.
const FILE_CAP: u64 = 16 << 20;
/// A meter summary goes in the stream at most this often (with the next event; no timer).
const METER_EVERY_MS: u64 = 1_000;
/// Chats whose recent log reads are remembered, at most.
const SCAN_KEYS: usize = 256;
/// A whole read this short (a first page, a head check) does not count toward re-reads.
const MIN_REREAD_RECORDS: u64 = 200;
/// The longest a `read` waits for a new event.
pub const MAX_WAIT_MS: u64 = 30_000;

/// What each span and check is expected to stay under, and where the number comes from. The
/// commentator says "higher than expected" past these and stays quiet under them.
pub const BUDGETS: &[Budget] = &[
    Budget {
        key: "chat.first_token",
        limit: 3_000.0,
        unit: "ms",
        what: "new chat to first token",
        source: "perf.ts agentLatency first_token_ms on a warm local Claude chat (warm-chat capture)",
    },
    Budget {
        key: "chat.send_paint",
        limit: 16.0,
        unit: "ms",
        what: "Enter to the frame that paints the sent message and the reserved assistant turn",
        source: "Leo, 2026-11-25: \"when you press enter, the stuff should just start playing. we dont need to wait/get blocked by anything on rendering.\" One frame at 60 Hz (perfReporter.ts sendSpan)",
    },
    Budget {
        key: "chat.send_first_token",
        limit: 3_000.0,
        unit: "ms",
        what: "Enter to first token",
        source: "the same as chat.first_token, per send (perfReporter.ts sendSpan detail.firstTokenMs)",
    },
    Budget {
        key: "chat.switch_paint",
        limit: 16.0,
        unit: "ms",
        what: "chat switch to the frame that paints its transcript",
        source: "one frame at 60 Hz (perfReporter.ts chatSwitchSpan)",
    },
    Budget {
        key: "workspace.switch",
        limit: 100.0,
        unit: "ms",
        what: "workspace switch to a settled transcript",
        source: "perf-lead.md row 4: switch input to idle 59.7 ms measured, < 16 ms to commit",
    },
    Budget {
        key: "page.load",
        limit: 800.0,
        unit: "ms",
        what: "chat page load to first paint",
        source: "newtab bench visible_ms and the relaunch-reconnect bench's connect marks",
    },
    Budget {
        key: "request",
        limit: 250.0,
        unit: "ms",
        what: "one daemon request, arrival to reply",
        source: "ack_latency_bench: a prompt ack behind a 30 MB list reply",
    },
    Budget {
        key: "request.read",
        limit: 50.0,
        unit: "ms",
        what: "a cheap read (status, the session list)",
        source: "outbound.rs read lane: a few ms at link speed",
    },
    Budget {
        key: "reply.bytes",
        limit: 256.0 * 1024.0,
        unit: "bytes",
        what: "one reply or notification",
        source: "outbound.rs BULK_WINDOW (256 KiB) and wire_size.rs",
    },
    Budget {
        key: "channel.bytes_per_minute",
        limit: 32.0 * 1024.0 * 1024.0,
        unit: "bytes",
        what: "one label of one channel in a minute",
        source: "list_bytes.rs: 31 MB lists sent 7 times a minute (2026-11-11)",
    },
    Budget {
        key: "chat_log.records",
        limit: 2_000.0,
        unit: "records",
        what: "records read from one chat log in one pass",
        source: "resend_scale_bench and #46010 (7,338 records read 3x per send)",
    },
    Budget {
        key: "chat_log.reads_per_second",
        limit: 2.0,
        unit: "reads",
        what: "whole reads of one chat's log within a second",
        source: "#46010: three keyed scans per resend",
    },
    Budget {
        key: "renders",
        limit: 10.0,
        unit: "renders",
        what: "renders of one component in 200 ms",
        source: "perfRender.ts useCountedRender; a streamed chunk renders only its row",
    },
    Budget {
        key: "frame",
        limit: 50.0,
        unit: "ms",
        what: "one frame (main-thread stall)",
        source: "flickerLog.ts long-frame; < 10 ms p95 action budget (perf-lead.md)",
    },
    Budget {
        key: "layout_shift",
        limit: 0.05,
        unit: "score",
        what: "layout shift after first paint",
        source: "Chrome's CLS 'good' bar is 0.1; a settled transcript should not move",
    },
];

/// One expected bound ([`BUDGETS`]).
pub struct Budget {
    pub key: &'static str,
    pub limit: f64,
    pub unit: &'static str,
    pub what: &'static str,
    pub source: &'static str,
}

/// The limit of `key` in [`BUDGETS`] (0 for an unknown key, which then never warns).
pub fn budget(key: &str) -> f64 {
    BUDGETS.iter().find(|b| b.key == key).map_or(0.0, |b| b.limit)
}

/// The channels the meter counts.
pub mod channel {
    /// Daemon IPC with this Mac's app pages and CLIs (the local unix socket).
    pub const IPC: &str = "daemon-ipc";
    /// Another machine's acpmux over the peer link (Cloud machines, a remote Mac).
    pub const PEER: &str = "peer-link";
    /// The web origin (the remote dashboard, a phone).
    pub const WEB: &str = "web";
    /// Chat logs read from disk.
    pub const DISK: &str = "disk-read";
    /// What a chat page says it received over its bridge (`report`).
    pub const BRIDGE: &str = "webview-bridge";
}

static ON: AtomicBool = AtomicBool::new(false);

/// Whether the watch records: the only cost every hook pays while it is off.
#[inline]
pub fn on() -> bool {
    ON.load(Ordering::Relaxed)
}

/// Bytes on one channel and label in per-second buckets over [`WINDOW_MS`].
struct Meter {
    total: u64,
    count: u64,
    largest: u64,
    /// `buckets[s % 60]` holds second `s`'s bytes when `stamps[s % 60] == s`.
    buckets: [u64; 60],
    stamps: [u64; 60],
}

impl Meter {
    fn new() -> Self {
        Self { total: 0, count: 0, largest: 0, buckets: [0; 60], stamps: [u64::MAX; 60] }
    }

    fn add(&mut self, bytes: u64, second: u64) {
        self.total = self.total.saturating_add(bytes);
        self.count += 1;
        self.largest = self.largest.max(bytes);
        let slot = (second % 60) as usize;
        let (Some(stamp), Some(bucket)) = (self.stamps.get_mut(slot), self.buckets.get_mut(slot))
        else {
            return;
        };
        if *stamp != second {
            *stamp = second;
            *bucket = 0;
        }
        *bucket = bucket.saturating_add(bytes);
    }

    /// Bytes in the last minute up to `second`.
    fn minute(&self, second: u64) -> u64 {
        self.stamps
            .iter()
            .zip(self.buckets.iter())
            .filter(|&(&stamp, _)| stamp != u64::MAX && second.saturating_sub(stamp) < 60)
            .map(|(_, &bucket)| bucket)
            .sum()
    }
}

struct Inner {
    /// When the watch turned on (ms since 1970), 0 while off.
    since_ms: u64,
    seq: u64,
    events: VecDeque<(u64, u64, Value)>,
    meter: HashMap<(&'static str, String), Meter>,
    /// When each note key was last said.
    said: HashMap<String, u64>,
    /// When the notes of the last minute were said.
    notes: VecDeque<u64>,
    quieted: u64,
    /// The recent whole reads of each chat's log.
    scans: HashMap<String, VecDeque<u64>>,
    last_meter_ms: u64,
    file: Option<(PathBuf, std::fs::File, u64)>,
}

impl Inner {
    fn new() -> Self {
        Self {
            since_ms: 0,
            seq: 0,
            events: VecDeque::new(),
            meter: HashMap::new(),
            said: HashMap::new(),
            notes: VecDeque::new(),
            quieted: 0,
            scans: HashMap::new(),
            last_meter_ms: 0,
            file: None,
        }
    }
}

/// The watch's state; [`global`] is this daemon's. Tests make their own.
pub struct Watch {
    inner: Mutex<Option<Inner>>,
    notify: tokio::sync::Notify,
    /// A test's own clock, in ms, that only it moves ([`Watch::advance`]): kept on the instance,
    /// so no test's time reaches another's watch (cmux#41350). `None`: the wall clock.
    #[cfg(test)]
    test_now: Option<std::sync::atomic::AtomicU64>,
}

impl Watch {
    pub const fn new() -> Self {
        Self {
            inner: Mutex::new(None),
            notify: tokio::sync::Notify::const_new(),
            #[cfg(test)]
            test_now: None,
        }
    }

    /// A watch whose clock reads `start_ms` until [`Watch::advance`] moves it.
    #[cfg(test)]
    pub(crate) const fn with_clock(start_ms: u64) -> Self {
        Self {
            inner: Mutex::new(None),
            notify: tokio::sync::Notify::const_new(),
            test_now: Some(std::sync::atomic::AtomicU64::new(start_ms)),
        }
    }

    /// Moves a [`Watch::with_clock`] watch's clock on by `ms`.
    #[cfg(test)]
    pub(crate) fn advance(&self, ms: u64) {
        if let Some(now) = &self.test_now {
            now.fetch_add(ms, std::sync::atomic::Ordering::Relaxed);
        }
    }

    fn now(&self) -> u64 {
        #[cfg(test)]
        if let Some(now) = &self.test_now {
            return now.load(std::sync::atomic::Ordering::Relaxed);
        }
        crate::store::now_ms()
    }

    /// Turns the watch on (fresh: no earlier events) with its tail file at `file`, or off.
    pub fn set(&self, enable: bool, file: Option<PathBuf>) -> Value {
        let mut guard = self.inner.lock_or_recover();
        if enable {
            if guard.is_none() {
                let mut inner = Inner::new();
                inner.since_ms = self.now();
                inner.file = file.and_then(|path| {
                    let opened = open_private(&path).ok()?;
                    Some((path, opened, 0))
                });
                *guard = Some(inner);
            }
        } else {
            *guard = None;
        }
        // Under the lock: an `on` and an `off` racing cannot leave the flag on with no state.
        if std::ptr::eq(self, global()) {
            ON.store(enable, Ordering::Relaxed);
        }
        drop(guard);
        self.notify.notify_waiters();
        self.status()
    }

    pub fn status(&self) -> Value {
        let guard = self.inner.lock_or_recover();
        match guard.as_ref() {
            None => json!({"on": false}),
            Some(inner) => json!({
                "on": true,
                "since": inner.since_ms,
                "seq": inner.seq,
                "file": inner.file.as_ref().map(|(path, _, _)| path.display().to_string()),
            }),
        }
    }

    /// Adds `bytes` to `channel`'s `label`; checks the label's minute against its budget.
    pub fn bytes(&self, channel: &'static str, label: &str, bytes: u64) {
        let now = self.now();
        let mut guard = self.inner.lock_or_recover();
        let Some(inner) = guard.as_mut() else { return };
        let second = now / 1000;
        let key = (channel, label.to_owned());
        if !room_for(inner, &key, second) {
            return;
        }
        let meter = inner.meter.entry(key).or_insert_with(Meter::new);
        meter.add(bytes, second);
        let minute = meter.minute(second);
        let single = budget("reply.bytes");
        if channel != channel::DISK && bytes as f64 > single {
            let text = format!(
                "{label} was {} in one message on {channel}, higher than expected (under {})",
                size(bytes),
                size(single as u64)
            );
            self.say(
                inner,
                now,
                &format!("big-message {channel} {label}"),
                text,
                json!({
                    "channel": channel, "label": label, "bytes": bytes, "budget": single,
                }),
            );
        }
        let per_minute = budget("channel.bytes_per_minute");
        if minute as f64 > per_minute {
            let text = format!(
                "hot zone: {label} moved {} on {channel} in the last minute (expected under {})",
                size(minute),
                size(per_minute as u64)
            );
            self.say(inner, now, &format!("hot-zone {channel} {label}"), text, json!({
                "channel": channel, "label": label, "bytesPerMinute": minute, "budget": per_minute,
            }));
        }
        self.meter_event(inner, now);
    }

    /// A finished span: `name` took `total_ms`, in `parts` (name, start ms, length ms) from its
    /// start. `budget_key` names its [`BUDGETS`] row (None: never judged).
    pub fn span(
        &self,
        name: &str,
        budget_key: Option<&str>,
        total_ms: f64,
        parts: &[(String, f64, f64)],
        detail: Value,
    ) {
        let now = self.now();
        let mut guard = self.inner.lock_or_recover();
        let Some(inner) = guard.as_mut() else { return };
        let limit = budget_key.map(budget).unwrap_or(0.0);
        let over = limit > 0.0 && total_ms > limit;
        let parts_json: Vec<Value> = parts
            .iter()
            .map(|(part, start, len)| json!({"name": part, "startMs": round(*start), "ms": round(*len)}))
            .collect();
        self.push(
            inner,
            now,
            json!({
                "kind": "span",
                "name": name,
                "ms": round(total_ms),
                "budgetMs": (limit > 0.0).then_some(limit),
                "over": over,
                "parts": parts_json,
                "detail": detail,
            }),
        );
        if over {
            let slowest = parts
                .iter()
                .max_by(|a, b| a.2.total_cmp(&b.2))
                .map(|(part, _, len)| format!("; slowest part: {part} {}", ms(*len)))
                .unwrap_or_default();
            let what = budget_key
                .and_then(|key| BUDGETS.iter().find(|b| b.key == key))
                .map_or(name, |b| b.what);
            let text = format!(
                "{what} took {}, higher than expected (under {}){slowest}",
                ms(total_ms),
                ms(limit)
            );
            self.say(
                inner,
                now,
                &format!("span {name}"),
                text,
                json!({
                    "span": name, "ms": round(total_ms), "budgetMs": limit,
                }),
            );
        }
        self.meter_event(inner, now);
    }

    /// A page's "send" span: a note (subject "send") when its first token came later than
    /// `chat.send_first_token`, or the transcript shifted under the reader over it.
    fn send_note(&self, page: &str, detail: &Value) {
        let first = detail.get("firstTokenMs").and_then(Value::as_f64);
        let shifts = detail.get("shifts").and_then(Value::as_u64).unwrap_or(0);
        let limit = budget("chat.send_first_token");
        let slow = first.filter(|ms| limit > 0.0 && *ms > limit);
        if slow.is_none() && shifts == 0 {
            return;
        }
        let transport = detail.get("transport").and_then(Value::as_str).unwrap_or("local");
        let mut said = Vec::new();
        if let Some(first) = slow {
            said.push(format!(
                "its first token came {} after Enter (under {})",
                ms(first),
                ms(limit)
            ));
        }
        if shifts > 0 {
            let what: Vec<&str> = detail
                .get("shiftWhat")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .take(3)
                .collect();
            let on =
                if what.is_empty() { String::new() } else { format!(" ({})", what.join(", ")) };
            said.push(format!("the transcript shifted {shifts} time(s) under it{on}"));
        }
        let text = format!("A {transport} send: {}", said.join("; "));
        let now = self.now();
        let mut guard = self.inner.lock_or_recover();
        let Some(inner) = guard.as_mut() else { return };
        self.say(
            inner,
            now,
            "send",
            text,
            json!({
                "subject": "send", "page": page, "firstTokenMs": first, "budgetMs": limit,
                "shifts": shifts, "transport": transport,
            }),
        );
    }

    /// One daemon request, `method`, answered `elapsed` after it arrived.
    pub fn request(&self, method: &str, origin: &str, elapsed: Duration, cheap_read: bool) {
        let total = elapsed.as_secs_f64() * 1000.0;
        // A new chat's daemon part, always: the chat page's new-chat span has it as a part.
        if method == crate::rpc::method::SESSION_NEW {
            self.span(
                "daemon session/new",
                None,
                total,
                &[("session/new".to_owned(), 0.0, total)],
                json!({"method": method, "origin": origin}),
            );
            return;
        }
        let key = if cheap_read { "request.read" } else { "request" };
        // A request under budget is no event: a busy daemon answers hundreds a second.
        if total <= budget(key) {
            return;
        }
        // A wait is long on purpose: `_acpmux/wait`, a prompt's whole turn, a long-poll read.
        if is_long_by_design(method) {
            return;
        }
        self.span(
            &format!("request {method}"),
            Some(key),
            total,
            &[("handle".to_owned(), 0.0, total)],
            json!({"method": method, "origin": origin}),
        );
    }

    /// A pass over a chat's log read `records` records and `bytes` bytes; `whole` when it read
    /// from the start.
    pub fn log_read(&self, chat: &str, records: u64, bytes: u64, whole: bool, elapsed: Duration) {
        let now = self.now();
        let mut guard = self.inner.lock_or_recover();
        let Some(inner) = guard.as_mut() else { return };
        let second = now / 1000;
        let key = (channel::DISK, "chat log".to_owned());
        if room_for(inner, &key, second) {
            inner.meter.entry(key).or_insert_with(Meter::new).add(bytes, second);
        }
        let short = short_id(chat);
        let limit = budget("chat_log.records");
        if whole && records as f64 > limit {
            let text = format!(
                "read the whole chat log of {short}: {} records, {} in {}",
                thousands(records),
                size(bytes),
                ms(elapsed.as_secs_f64() * 1000.0)
            );
            self.say(
                inner,
                now,
                &format!("whole-log {chat}"),
                text,
                json!({
                    "chat": chat, "records": records, "bytes": bytes, "budget": limit,
                }),
            );
        }
        // A short read from the start (the first page, a head check) is no re-read of the log.
        if whole && records >= MIN_REREAD_RECORDS {
            if !inner.scans.contains_key(chat) && inner.scans.len() >= SCAN_KEYS {
                inner
                    .scans
                    .retain(|_, at| at.back().is_some_and(|t| now.saturating_sub(*t) < 1000));
            }
            if inner.scans.contains_key(chat) || inner.scans.len() < SCAN_KEYS {
                let times = inner.scans.entry(chat.to_owned()).or_default();
                times.push_back(now);
                while times.front().is_some_and(|t| now.saturating_sub(*t) >= 1000) {
                    times.pop_front();
                }
                let reads = times.len();
                if reads as f64 > budget("chat_log.reads_per_second") {
                    let text = format!(
                        "read chat {short}'s whole log {reads} times within a second (one pass should do)"
                    );
                    self.say(
                        inner,
                        now,
                        &format!("re-read {chat}"),
                        text,
                        json!({
                            "chat": chat, "reads": reads, "records": records,
                        }),
                    );
                }
            }
        }
        self.meter_event(inner, now);
    }

    /// What a chat page measured (`_acpmux/perf {op:"report"}`): `spans` (the same shape as
    /// [`Self::span`]'s event), `renders` ({component: count} over `windowMs`), `frames` (long
    /// frames in ms), `layoutShifts` ([{score, afterPaint}]) and `bytes` ([{label, bytes}] the page
    /// received over its bridge).
    pub fn report(&self, page: &str, report: &Value) {
        for span in report.get("spans").and_then(Value::as_array).into_iter().flatten() {
            let Some(name) = span.get("name").and_then(Value::as_str) else { continue };
            let total = span.get("ms").and_then(Value::as_f64).unwrap_or(0.0);
            let parts: Vec<(String, f64, f64)> = span
                .get("parts")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|part| {
                    Some((
                        part.get("name")?.as_str()?.chars().take(80).collect(),
                        part.get("startMs").and_then(Value::as_f64).unwrap_or(0.0),
                        part.get("ms")?.as_f64()?,
                    ))
                })
                .take(32)
                .collect();
            let budget_key =
                span.get("budget").and_then(Value::as_str).filter(|key| budget(key) > 0.0);
            let name: String = name.chars().take(80).collect();
            let inner_detail = span.get("detail").cloned().unwrap_or(Value::Null);
            if name == "send" {
                self.send_note(page, &inner_detail);
            }
            let detail = json!({"page": page, "detail": inner_detail});
            self.span(&name, budget_key, total, &parts, detail);
        }
        let window = report.get("windowMs").and_then(Value::as_f64).unwrap_or(200.0).max(1.0);
        if let Some(renders) = report.get("renders").and_then(Value::as_object) {
            let now = self.now();
            let mut guard = self.inner.lock_or_recover();
            if let Some(inner) = guard.as_mut() {
                // Scaled to 200 ms windows: the budget's unit.
                let limit = budget("renders") * (window / 200.0).max(1.0);
                for (component, count) in renders.iter().take(64) {
                    let count = count.as_u64().unwrap_or(0);
                    if count as f64 > limit {
                        let text =
                            format!("{component} re-rendered {count} times in {}", ms(window));
                        self.say(inner, now, &format!("renders {page} {component}"), text, json!({
                            "page": page, "component": component, "renders": count, "windowMs": window,
                        }));
                    }
                }
            }
        }
        let frames: Vec<f64> = report
            .get("frames")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_f64)
            .collect();
        if let Some(worst) = frames.iter().copied().max_by(f64::total_cmp) {
            let now = self.now();
            let mut guard = self.inner.lock_or_recover();
            if let Some(inner) = guard.as_mut() {
                let limit = budget("frame");
                if worst > limit {
                    let count = frames.iter().filter(|f| **f > limit).count();
                    let text = format!(
                        "main thread stalled {} on a chat page ({count} frame{} over {})",
                        ms(worst),
                        if count == 1 { "" } else { "s" },
                        ms(limit)
                    );
                    self.say(
                        inner,
                        now,
                        &format!("stall {page}"),
                        text,
                        json!({
                            "page": page, "worstMs": round(worst), "over": count,
                        }),
                    );
                }
            }
        }
        for shift in report.get("layoutShifts").and_then(Value::as_array).into_iter().flatten() {
            let score = shift.get("score").and_then(Value::as_f64).unwrap_or(0.0);
            let after_paint = shift.get("afterPaint").and_then(Value::as_bool).unwrap_or(false);
            if !after_paint || score <= budget("layout_shift") {
                continue;
            }
            let now = self.now();
            let mut guard = self.inner.lock_or_recover();
            if let Some(inner) = guard.as_mut() {
                let what = shift.get("what").and_then(Value::as_str).unwrap_or("the page");
                let text = format!("layout shifted after paint ({what}, score {score:.2})");
                self.say(
                    inner,
                    now,
                    &format!("shift {page} {what}"),
                    text,
                    json!({
                        "page": page, "score": score, "what": what,
                    }),
                );
            }
        }
        for entry in report.get("bytes").and_then(Value::as_array).into_iter().flatten().take(64) {
            let (Some(label), Some(bytes)) = (
                entry.get("label").and_then(Value::as_str),
                entry.get("bytes").and_then(Value::as_u64),
            ) else {
                continue;
            };
            let label: String = label.chars().take(80).collect();
            self.bytes(channel::BRIDGE, &label, bytes);
        }
    }

    /// Says `text` unless `key` was said in the last [`NOTE_QUIET_MS`] or the minute's
    /// [`NOTES_PER_MINUTE`] are spent.
    fn say(&self, inner: &mut Inner, now: u64, key: &str, text: String, detail: Value) {
        if inner.said.get(key).is_some_and(|at| now.saturating_sub(*at) < NOTE_QUIET_MS) {
            return;
        }
        while inner.notes.front().is_some_and(|at| now.saturating_sub(*at) >= 60_000) {
            inner.notes.pop_front();
        }
        if inner.notes.len() >= NOTES_PER_MINUTE {
            inner.quieted += 1;
            return;
        }
        if inner.said.len() >= 1024 {
            inner.said.retain(|_, at| now.saturating_sub(*at) < NOTE_QUIET_MS);
        }
        inner.said.insert(key.to_owned(), now);
        inner.notes.push_back(now);
        let quieted = std::mem::take(&mut inner.quieted);
        self.push(
            inner,
            now,
            json!({
                "kind": "note",
                "text": text,
                "key": key,
                "quietedBefore": quieted,
                "detail": detail,
            }),
        );
    }

    /// A `meter` event (the top hot zones) when the last is older than [`METER_EVERY_MS`].
    fn meter_event(&self, inner: &mut Inner, now: u64) {
        if now.saturating_sub(inner.last_meter_ms) < METER_EVERY_MS {
            return;
        }
        inner.last_meter_ms = now;
        let top = top_zones(inner, now, 10);
        self.push(inner, now, json!({"kind": "meter", "top": top}));
    }

    fn push(&self, inner: &mut Inner, now: u64, mut event: Value) {
        inner.seq += 1;
        if let Some(object) = event.as_object_mut() {
            object.insert("seq".into(), json!(inner.seq));
            object.insert("at".into(), json!(now));
        }
        if let Some((path, file, written)) = inner.file.as_mut() {
            let line = format!("{event}\n");
            if *written + line.len() as u64 > FILE_CAP {
                let old = path.with_extension("jsonl.1");
                let _ = std::fs::rename(&*path, old);
                if let Ok(fresh) = open_private(&*path) {
                    *file = fresh;
                    *written = 0;
                }
            }
            if file.write_all(line.as_bytes()).is_ok() {
                *written += line.len() as u64;
            }
        }
        inner.events.push_back((inner.seq, now, event));
        while inner.events.len() > EVENTS_CAP
            || inner.events.front().is_some_and(|(_, at, _)| now.saturating_sub(*at) > WINDOW_MS)
        {
            inner.events.pop_front();
        }
        self.notify.notify_waiters();
    }

    /// Events after `after`, at most `limit`, and the newest seq.
    pub fn read(&self, after: u64, limit: usize) -> Value {
        let guard = self.inner.lock_or_recover();
        let Some(inner) = guard.as_ref() else {
            return json!({"on": false, "events": [], "seq": 0});
        };
        let events: Vec<&Value> = inner
            .events
            .iter()
            .filter(|(seq, _, _)| *seq > after)
            .take(limit)
            .map(|(_, _, event)| event)
            .collect();
        json!({"on": true, "events": events, "seq": inner.seq})
    }

    /// [`Self::read`], waiting up to `wait` for an event after `after` when there is none yet.
    pub async fn read_wait(&self, after: u64, limit: usize, wait: Duration) -> Value {
        let deadline = Instant::now() + wait.min(Duration::from_millis(MAX_WAIT_MS));
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            let read = self.read(after, limit);
            let has = read
                .get("events")
                .and_then(Value::as_array)
                .is_some_and(|events| !events.is_empty());
            if has || read.get("on") == Some(&Value::Bool(false)) {
                return read;
            }
            if tokio::time::timeout_at(deadline.into(), notified).await.is_err() {
                return read;
            }
        }
    }

    /// The last minute in one object: every event, the ranked meter and the budgets.
    pub fn snapshot(&self) -> Value {
        let now = self.now();
        let guard = self.inner.lock_or_recover();
        let budgets: Vec<Value> = BUDGETS
            .iter()
            .map(|b| json!({"key": b.key, "limit": b.limit, "unit": b.unit, "what": b.what, "source": b.source}))
            .collect();
        let Some(inner) = guard.as_ref() else {
            return json!({"on": false, "budgets": budgets});
        };
        let events: Vec<&Value> = inner.events.iter().map(|(_, _, event)| event).collect();
        json!({
            "on": true,
            "since": inner.since_ms,
            "at": now,
            "windowMs": WINDOW_MS,
            "seq": inner.seq,
            "events": events,
            "meter": top_zones(inner, now, 50),
            "budgets": budgets,
        })
    }
}

impl Default for Watch {
    fn default() -> Self {
        Self::new()
    }
}

/// The meter's labels by their last minute's bytes, largest first.
fn top_zones(inner: &Inner, now: u64, limit: usize) -> Vec<Value> {
    let second = now / 1000;
    let mut rows: Vec<(u64, &(&'static str, String), &Meter)> = inner
        .meter
        .iter()
        .map(|(key, meter)| (meter.minute(second), key, meter))
        .filter(|(minute, _, _)| *minute > 0)
        .collect();
    rows.sort_by_key(|row| std::cmp::Reverse(row.0));
    rows.into_iter()
        .take(limit)
        .map(|(minute, (channel, label), meter)| {
            json!({
                "channel": channel,
                "label": label,
                "bytesPerMinute": minute,
                "bytes": meter.total,
                "count": meter.count,
                "largest": meter.largest,
            })
        })
        .collect()
}

/// Whether `key` has a meter slot: it has one, or there is room, or a label idle for the last
/// minute gives its slot up (a label can come from a client's name; new ones must not be shut out).
fn room_for(inner: &mut Inner, key: &(&'static str, String), second: u64) -> bool {
    if inner.meter.contains_key(key) || inner.meter.len() < METER_KEYS {
        return true;
    }
    inner.meter.retain(|_, meter| meter.minute(second) > 0);
    inner.meter.len() < METER_KEYS
}

/// Requests whose answer waits on purpose: never judged against the request budget.
fn is_long_by_design(method: &str) -> bool {
    use crate::rpc::method;
    matches!(
        method,
        method::SESSION_PROMPT
            | method::SESSION_NEW
            | method::SESSION_LOAD
            | method::SESSION_RESUME
            | method::MUX_ATTACH
            | method::MUX_WAIT
            | method::MUX_MAIL_WAIT
            | METHOD
    ) || method.contains("wait")
}

/// The tail file, readable by its owner only: it names chats and clients.
fn open_private(path: &std::path::Path) -> std::io::Result<std::fs::File> {
    // Through `home_fs`: the tail file is under the home the daemon holds.
    crate::home_fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
}

fn round(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

fn ms(value: f64) -> String {
    if value >= 1000.0 { format!("{:.1} s", value / 1000.0) } else { format!("{value:.0} ms") }
}

fn size(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    let b = bytes as f64;
    if b >= KB * KB * KB {
        format!("{:.1} GB", b / KB / KB / KB)
    } else if b >= KB * KB {
        format!("{:.1} MB", b / KB / KB)
    } else if b >= KB {
        format!("{:.0} KB", b / KB)
    } else {
        format!("{bytes} B")
    }
}

fn thousands(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn short_id(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

static GLOBAL: Watch = Watch::new();

/// This daemon's watch.
pub fn global() -> &'static Watch {
    &GLOBAL
}

/// The tail file: `$ACPMUX_HOME/perf-watch.jsonl`.
pub fn file_path() -> PathBuf {
    crate::config::home().join("perf-watch.jsonl")
}

/// [`Watch::bytes`] on [`global`]; `label` is made only while on.
#[inline]
pub fn bytes(channel: &'static str, label: impl FnOnce() -> String, bytes: usize) {
    if on() {
        GLOBAL.bytes(channel, &label(), bytes as u64);
    }
}

/// The channel a connection of `origin` sends on.
pub fn channel_of(origin: crate::server::Origin) -> &'static str {
    match origin {
        crate::server::Origin::Peer => channel::PEER,
        crate::server::Origin::Web => channel::WEB,
        _ => channel::IPC,
    }
}

/// When a request arrived, while on.
#[inline]
pub fn request_started() -> Option<Instant> {
    on().then(Instant::now)
}

/// [`Watch::request`] on [`global`] for a request that arrived at `started`.
pub fn request_done(started: Option<Instant>, method: &str, origin: crate::server::Origin) {
    if let Some(started) = started
        && on()
    {
        let cheap = crate::server::is_cheap_read(method);
        GLOBAL.request(method, &format!("{origin:?}"), started.elapsed(), cheap);
    }
}

/// One pass over a chat's log: made only while on, reported to [`Watch::log_read`] when it is
/// dropped, so every early return of a scan reports it too.
pub struct LogPass {
    started: Instant,
    chat: String,
    whole: bool,
    records: u64,
    bytes: u64,
}

impl LogPass {
    /// A pass over `chat`'s log; `whole` when it reads from the first record.
    #[inline]
    pub fn start(chat: &str, whole: bool) -> Option<Self> {
        on().then(|| Self {
            started: Instant::now(),
            chat: chat.to_owned(),
            whole,
            records: 0,
            bytes: 0,
        })
    }

    /// One line of `len` bytes read.
    #[inline]
    pub fn line(pass: &mut Option<Self>, len: usize) {
        if let Some(pass) = pass {
            pass.records += 1;
            pass.bytes += len as u64;
        }
    }
}

impl Drop for LogPass {
    fn drop(&mut self) {
        GLOBAL.log_read(&self.chat, self.records, self.bytes, self.whole, self.started.elapsed());
    }
}

/// `_acpmux/perf`: `{op: "on"|"off"|"status"|"read"|"snapshot"|"report"|"budgets"|"frames"|"tally", ...}`.
pub const METHOD: &str = crate::rpc::method::MUX_PERF;

/// Serves [`METHOD`].
pub async fn handle(params: &Value) -> Result<Value, crate::rpc::RpcError> {
    let watch = global();
    match params.get("op").and_then(Value::as_str).unwrap_or("status") {
        "on" => Ok(watch.set(true, Some(file_path()))),
        "off" => Ok(watch.set(false, None)),
        "status" => Ok(watch.status()),
        "read" => {
            let after = params.get("after").and_then(Value::as_u64).unwrap_or(0);
            let limit =
                params.get("limit").and_then(Value::as_u64).unwrap_or(500).min(2_000) as usize;
            let wait = params.get("waitMs").and_then(Value::as_u64).unwrap_or(0);
            if wait == 0 {
                Ok(watch.read(after, limit))
            } else {
                Ok(watch.read_wait(after, limit, Duration::from_millis(wait)).await)
            }
        }
        "snapshot" => Ok(watch.snapshot()),
        "report" => {
            if !on() {
                return Ok(json!({"on": false}));
            }
            let page = params.get("page").and_then(Value::as_str).unwrap_or("page");
            let page: String = page.chars().take(64).collect();
            watch.report(&page, params);
            Ok(json!({"on": true}))
        }
        "budgets" => Ok(watch.snapshot().get("budgets").cloned().unwrap_or(Value::Null)),
        // The always-on frame tally (`frame_tally.rs`): on or off, the watch has no say in it.
        "frames" => Ok(crate::frame_tally::read()),
        "tally" => crate::frame_tally::report(params).map_err(|error| {
            crate::rpc::RpcError::invalid_params(format!("_acpmux/perf tally: {error}"))
        }),
        other => Err(crate::rpc::RpcError::invalid_params(format!(
            "_acpmux/perf: unknown op {other:?} (on, off, status, read, snapshot, report, budgets, frames, tally)"
        ))),
    }
}

#[cfg(test)]
#[path = "perf_watch_tests.rs"]
mod tests;
