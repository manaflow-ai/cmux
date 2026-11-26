//! acpmux's per-session event logs (`~/.acpmux/sessions/<id>/events/*.ndjson`) as runs: one graph
//! per turn, from the prompt's arrival to its turn's end.
//!
//! A turn's chain, each step following the one before:
//!
//! | category | from | to | state |
//! | --- | --- | --- | --- |
//! | `acpmux:queue` | `queued` | `dequeued` | wait (behind the session's running turn) |
//! | `acpmux:dispatch` | `dequeued` | `turn_started` | ours |
//! | `acpmux:prompt-write` | `turn_started` | `session/prompt` written to the harness | ours |
//! | `acpmux:harness-busy` | the same window, while the harness still sends events (an earlier turn's tail) | | wait |
//! | `acpmux:stall` | the same window, when nothing at all happened for [`STALL_MS`] before the write | | wait |
//! | `model:first-token` | `session/prompt` | the harness's first event | model |
//! | `model` | between tool calls | | model |
//! | `tool:<Tool>[:<command>]` | `tool_call` | its `completed`/`failed` update | tool |
//!
//! Tool calls that overlap (one assistant message, several calls) are parallel branches: each
//! follows the model step before them, and the next model step follows all of them. So a short
//! call beside a long one has no drag.
//!
//! A stall is what Rewind's wakeup attribution finds: the prompt sat unwritten while nothing ran,
//! and the event just before the write is what woke it ([`Stall::waker`]).

use crate::{Graph, Node, State, quantiles};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// Quiet before a prompt write that makes it a stall, not our own write time.
pub const STALL_MS: i64 = 1000;

/// Speed of light of our own stages, in ms: what the step costs with nothing in its way. A
/// dispatch is a queue pop and a journal append (group commit, no sync wait on the path); a
/// prompt write is one pipe write to a harness already waiting for it. See the RFD's table.
pub const SOL_DISPATCH_MS: i64 = 1;
pub const SOL_PROMPT_WRITE_MS: i64 = 1;

const FIRST_IN: &[&str] = &[
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "claude.stream_event",
    "claude.assistant",
    "plan",
];

#[derive(Clone, Debug, PartialEq)]
pub struct Stall {
    pub session: String,
    pub prompt_id: String,
    /// When the turn started (epoch ms).
    pub at: i64,
    pub ms: i64,
    /// The event just before the write (`dir:kind`): what woke the prompt.
    pub waker: String,
    /// `event` when the write came within [`RELEASE_MS`] of the waker (the waker released it: a
    /// wake the prompt should not have needed), `timer` when it came later (a poll or timeout
    /// released it), `none` when nothing at all happened in the turn before the write.
    pub released_by: &'static str,
}

/// A write this soon after the event before it was released by that event.
pub const RELEASE_MS: i64 = 250;

#[derive(Debug, Default)]
pub struct Report {
    pub graphs: Vec<Graph>,
    /// Stage samples (ms) by stage name.
    pub stages: BTreeMap<&'static str, Vec<i64>>,
    pub stalls: Vec<Stall>,
    pub sessions_read: usize,
    pub files_read: usize,
    pub bad_lines: usize,
}

#[derive(Default)]
struct Turn {
    session: String,
    prompt_id: String,
    queued: Option<i64>,
    dequeued: Option<i64>,
    started: i64,
    last_in: Option<i64>,
    prev: Option<(i64, String)>,
    waker: Option<(i64, String)>,
    out: Option<i64>,
    first_in: Option<i64>,
    tools: Vec<Tool>,
    tool_index: HashMap<String, usize>,
}

struct Tool {
    name: String,
    detail: Option<String>,
    start: i64,
    end: Option<i64>,
}

/// `{"seq":N,"at":N,"dir":"D","kind":"K"` without a full parse: most lines are streamed chunks
/// whose bodies the analysis never reads.
fn header(line: &str) -> Option<(i64, &str, &str)> {
    line.get(..64)?.find("\"at\":")?;
    let (_, rest) = line.split_once("\"at\":")?;
    let at_end = rest.find(|c: char| !c.is_ascii_digit())?;
    let (at, rest) = rest.split_at_checked(at_end)?;
    let at: i64 = at.parse().ok()?;
    let (_, rest) = rest.split_once("\"dir\":\"")?;
    let (dir, rest) = rest.split_once('"')?;
    let (_, rest) = rest.split_once("\"kind\":\"")?;
    let (kind, _) = rest.split_once('"')?;
    Some((at, dir, kind))
}

/// The command a shell call ran, as one word: the first program past `cd`, env assignments and
/// paths (`cargo`, `glaeda-gh`, `gh`).
pub fn command_word(command: &str) -> Option<String> {
    for part in command.split(['\n', ';', '|', '&']) {
        let words = part
            .split_whitespace()
            .map(|w| w.trim_matches(|c| c == '"' || c == '\'' || c == '(' || c == ')' || c == '{'))
            .filter(|w| !w.is_empty() && !w.contains('='));
        for word in words {
            // Wrappers and their arguments: the program they run is the word.
            if matches!(
                word,
                "time"
                    | "env"
                    | "nice"
                    | "nohup"
                    | "sudo"
                    | "exec"
                    | "command"
                    | "timeout"
                    | "then"
                    | "do"
            ) || word.starts_with('-')
                || word.chars().all(|c| c.is_ascii_digit() || c == '.' || c == 's' || c == 'm')
            {
                continue;
            }
            if matches!(
                word,
                "cd" | "export"
                    | "set"
                    | "if"
                    | "for"
                    | "while"
                    | "echo"
                    | "true"
                    | "done"
                    | "fi"
                    | "else"
            ) {
                break;
            }
            let base = word.rsplit('/').next().unwrap_or(word);
            if !base.is_empty() {
                return Some(base.chars().take(32).collect());
            }
        }
    }
    None
}

impl Turn {
    fn finish(mut self, end: i64, report: &mut Report) {
        let label =
            format!("{} {}", self.session.get(..8).unwrap_or(&self.session), self.prompt_id);
        let mut g = Graph { label, nodes: Vec::new() };
        let mut prev: Option<usize> = None;
        let chain = |g: &mut Graph,
                     prev: &mut Option<usize>,
                     name: &str,
                     cat: &str,
                     state: State,
                     s: i64,
                     e: i64| {
            if e < s {
                return;
            }
            let at = g.push(Node {
                name: name.to_string(),
                cat: cat.to_string(),
                state,
                start: s,
                end: e,
                deps: prev.iter().copied().collect(),
            });
            *prev = Some(at);
        };
        if let (Some(q), Some(d)) = (self.queued, self.dequeued) {
            chain(&mut g, &mut prev, "queued", "acpmux:queue", State::Wait, q, d);
            report.stages.entry("queue").or_default().push(d - q);
        }
        if let Some(d) = self.dequeued {
            chain(&mut g, &mut prev, "dispatch", "acpmux:dispatch", State::Ours, d, self.started);
            report.stages.entry("dispatch").or_default().push(self.started - d);
        }
        let Some(out) = self.out else {
            return;
        };
        let written = out - self.started;
        report.stages.entry("prompt_write").or_default().push(written);
        let quiet_from = self.last_in.unwrap_or(self.started).max(self.started);
        let quiet = out - quiet_from;
        if quiet >= STALL_MS {
            if quiet_from > self.started {
                chain(
                    &mut g,
                    &mut prev,
                    "harness busy",
                    "acpmux:harness-busy",
                    State::Wait,
                    self.started,
                    quiet_from,
                );
            }
            chain(&mut g, &mut prev, "stall", "acpmux:stall", State::Wait, quiet_from, out);
            report.stalls.push(Stall {
                session: self.session.clone(),
                prompt_id: self.prompt_id.clone(),
                at: self.started,
                ms: quiet,
                waker: self.waker.as_ref().map(|w| w.1.clone()).unwrap_or_else(|| "-".into()),
                released_by: match &self.waker {
                    Some((at, _)) if out - at <= RELEASE_MS => "event",
                    Some(_) => "timer",
                    None => "none",
                },
            });
        } else if self.last_in.is_some_and(|l| l > self.started) && written >= STALL_MS {
            chain(
                &mut g,
                &mut prev,
                "harness busy",
                "acpmux:harness-busy",
                State::Wait,
                self.started,
                out,
            );
        } else {
            chain(
                &mut g,
                &mut prev,
                "prompt write",
                "acpmux:prompt-write",
                State::Ours,
                self.started,
                out,
            );
        }
        let first = self.first_in.unwrap_or(end).min(end);
        chain(&mut g, &mut prev, "first token", "model:first-token", State::Model, out, first);
        report.stages.entry("first_token").or_default().push(first - out);
        let arrival = self.queued.or(self.dequeued).unwrap_or(self.started);
        report.stages.entry("arrival_to_first_token").or_default().push(first - arrival);
        report.stages.entry("turn").or_default().push(end - self.started);

        // The body: model steps between clusters of overlapping tool calls.
        self.tools.retain(|t| t.start >= first && t.start <= end);
        self.tools.sort_by_key(|t| t.start);
        let mut cursor = first;
        let mut joins: Vec<usize> = prev.into_iter().collect();
        let mut rest = self.tools.as_slice();
        while let Some(first_tool) = rest.first() {
            let c_start = first_tool.start;
            let mut c_end = first_tool.end.unwrap_or(end).min(end).max(c_start);
            let mut j = 1;
            while let Some(next) = rest.get(j).filter(|t| t.start < c_end) {
                c_end = c_end.max(next.end.unwrap_or(end).min(end));
                j += 1;
            }
            let (cluster, after) = rest.split_at(j);
            let model = g.push(Node {
                name: "model".into(),
                cat: "model".into(),
                state: State::Model,
                start: cursor,
                end: c_start.max(cursor),
                deps: joins.clone(),
            });
            joins.clear();
            for t in cluster {
                let cat = match &t.detail {
                    Some(d) => format!("tool:{}:{d}", t.name),
                    None => format!("tool:{}", t.name),
                };
                let name = t.detail.clone().unwrap_or_else(|| t.name.clone());
                let t_end = t.end.unwrap_or(end).min(end).max(t.start);
                joins.push(g.push(Node {
                    name,
                    cat,
                    state: State::Tool,
                    start: t.start.max(c_start),
                    end: t_end,
                    deps: vec![model],
                }));
            }
            cursor = c_end.max(cursor);
            rest = after;
        }
        g.push(Node {
            name: "model".into(),
            cat: "model".into(),
            state: State::Model,
            start: cursor,
            end: end.max(cursor),
            deps: joins,
        });
        report.graphs.push(g);
    }
}

fn read_session(dir: &Path, session: &str, since_ms: i64, since: SystemTime, report: &mut Report) {
    let Ok(entries) = fs::read_dir(dir.join("events")) else { return };
    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().ends_with(".ndjson"))
        .filter(|e| e.metadata().and_then(|m| m.modified()).is_ok_and(|m| m >= since))
        .map(|e| e.path())
        .collect();
    if files.is_empty() {
        return;
    }
    files.sort();
    report.sessions_read += 1;
    let mut queued: HashMap<String, i64> = HashMap::new();
    let mut dequeued: Option<(String, i64)> = None;
    let mut turn: Option<Turn> = None;
    for path in files {
        let Ok(file) = fs::File::open(&path) else { continue };
        report.files_read += 1;
        for line in BufReader::with_capacity(1 << 20, file).lines() {
            let Ok(line) = line else {
                report.bad_lines += 1;
                continue;
            };
            let Some((at, dir, kind)) = header(&line) else {
                report.bad_lines += 1;
                continue;
            };
            if at < since_ms {
                continue;
            }
            let full = || serde_json::from_str::<Value>(&line).ok();
            match (dir, kind) {
                ("mux", "queued") => {
                    if let Some(id) = full().and_then(|v| {
                        v.pointer("/msg/promptId").and_then(Value::as_str).map(str::to_string)
                    }) {
                        queued.insert(id, at);
                    }
                }
                ("mux", "dequeued") => {
                    let id = full()
                        .and_then(|v| {
                            v.pointer("/msg/promptId").and_then(Value::as_str).map(str::to_string)
                        })
                        .unwrap_or_default();
                    dequeued = Some((id, at));
                }
                ("mux", "turn_started") => {
                    let id = full()
                        .and_then(|v| {
                            v.pointer("/msg/promptId").and_then(Value::as_str).map(str::to_string)
                        })
                        .unwrap_or_default();
                    let deq =
                        dequeued.take().filter(|(d, _)| d == &id || id.is_empty()).map(|(_, t)| t);
                    turn = Some(Turn {
                        session: session.to_string(),
                        queued: queued.remove(&id),
                        prompt_id: id,
                        dequeued: deq,
                        started: at,
                        ..Turn::default()
                    });
                }
                ("mux", "turn_end") => {
                    if let Some(t) = turn.take() {
                        t.finish(at, report);
                    }
                }
                _ => {
                    let Some(t) = turn.as_mut() else { continue };
                    if t.out.is_none() {
                        if dir == "out" && kind == "session/prompt" {
                            t.out = Some(at);
                            t.waker = t.prev.take();
                        } else {
                            if dir == "in" {
                                t.last_in = Some(at);
                            }
                            // Our own write's receipts (`_acpmux/host_queued`, `claude.stdin`) are the
                            // write, not what woke it.
                            if kind != "status" && dir != "out" {
                                t.prev = Some((at, format!("{dir}:{kind}")));
                            }
                        }
                        continue;
                    }
                    if dir != "in" {
                        continue;
                    }
                    if t.first_in.is_none() && FIRST_IN.contains(&kind) {
                        t.first_in = Some(at);
                    }
                    if kind == "tool_call" || kind == "tool_call_update" {
                        let Some(v) = full() else { continue };
                        let u = v.pointer("/msg/params/update").unwrap_or(&Value::Null);
                        let Some(id) = u.get("toolCallId").and_then(Value::as_str) else {
                            continue;
                        };
                        let at_index = match t.tool_index.get(id) {
                            Some(&i) => i,
                            None => {
                                let name = u
                                    .pointer("/_meta/claude/tool")
                                    .and_then(Value::as_str)
                                    .or(u.get("title").and_then(Value::as_str))
                                    .unwrap_or("tool");
                                t.tools.push(Tool {
                                    name: name.chars().take(40).collect(),
                                    detail: None,
                                    start: at,
                                    end: None,
                                });
                                t.tool_index.insert(id.to_string(), t.tools.len() - 1);
                                t.tools.len() - 1
                            }
                        };
                        let Some(tool) = t.tools.get_mut(at_index) else { continue };
                        if tool.detail.is_none()
                            && let Some(cmd) =
                                u.pointer("/rawInput/command").and_then(Value::as_str)
                        {
                            tool.detail = command_word(cmd);
                        }
                        if matches!(
                            u.get("status").and_then(Value::as_str),
                            Some("completed" | "failed")
                        ) && tool.end.is_none()
                        {
                            tool.end = Some(at);
                        }
                    }
                }
            }
        }
    }
}

/// Every session's turns that started in the last `hours`, read from `root` (`~/.acpmux/sessions`).
pub fn read(root: &Path, hours: f64, now: SystemTime) -> Report {
    let since = now - Duration::from_secs_f64(hours * 3600.0);
    let since_ms =
        since.duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    let mut report = Report::default();
    let Ok(entries) = fs::read_dir(root) else { return report };
    let mut dirs: Vec<(String, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
        .collect();
    dirs.sort();
    for (session, dir) in dirs {
        read_session(&dir, &session, since_ms, since, &mut report);
    }
    report
}

/// A session's name from its `session.json`, else its id's first 8.
pub fn session_name(root: &Path, session: &str) -> String {
    fs::read(root.join(session).join("session.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.get("name").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_else(|| session.chars().take(8).collect())
}

/// The `critpath/v1` reading NOW publishes (`acpmux` block): stages against their speed of light,
/// what drags turns most, and the stalls with their wakers.
pub fn summary(report: &Report, root: &Path, host: &str, hours: f64, at_ms: i64) -> Value {
    let mut stages = serde_json::Map::new();
    let mut samples = report.stages.clone();
    for (name, values) in samples.iter_mut() {
        let n = values.len();
        let sum: i64 = values.iter().sum();
        let (p50, p90, p99, max) = quantiles(values);
        let floor = values.get(n / 20).copied().unwrap_or(0);
        let sol = match *name {
            "dispatch" => Some(SOL_DISPATCH_MS),
            "prompt_write" => Some(SOL_PROMPT_WRITE_MS),
            "first_token" | "arrival_to_first_token" => Some(floor),
            _ => None,
        };
        stages.insert(
            name.to_string(),
            json!({"n": n, "p50_ms": p50, "p90_ms": p90, "p99_ms": p99, "max_ms": max, "sum_s": sum / 1000,
                   "sol_ms": sol, "sol_basis": match *name {
                       "dispatch" | "prompt_write" => "one local IPC step",
                       "first_token" | "arrival_to_first_token" => "p5 of the window (the measured floor)",
                       _ => "none: waiting behind a busy turn is by design",
                   },
                   "excess_over_sol_s": sol.map(|s| values.iter().map(|v| (v - s).max(0)).sum::<i64>() / 1000)}),
        );
    }
    let mut rollup = crate::Rollup::default();
    for g in &report.graphs {
        rollup.add(g);
    }
    let drag: Vec<Value> = rollup
        .top()
        .into_iter()
        .take(12)
        .map(|(cat, d, p, n)| json!({"cat": cat, "drag_s": d / 1000, "path_s": p / 1000, "turns": n}))
        .collect();
    let mut wakers: BTreeMap<&str, (usize, i64)> = BTreeMap::new();
    let mut released: BTreeMap<&str, (usize, i64)> = BTreeMap::new();
    for s in &report.stalls {
        for (map, key) in [(&mut wakers, s.waker.as_str()), (&mut released, s.released_by)] {
            let e = map.entry(key).or_default();
            e.0 += 1;
            e.1 += s.ms;
        }
    }
    let count_sum = |m: &BTreeMap<&str, (usize, i64)>| {
        m.iter()
            .map(|(w, (n, ms))| (w.to_string(), json!({"count": n, "sum_s": ms / 1000})))
            .collect::<serde_json::Map<_, _>>()
    };
    let (by_event, by_event_ms) = released.get("event").copied().unwrap_or_default();
    let mut stalls = report.stalls.clone();
    stalls.sort_by_key(|s| -s.ms);
    let stall_sum: i64 = stalls.iter().map(|s| s.ms).sum();
    let top: Vec<Value> = stalls
        .iter()
        .take(5)
        .map(|s| json!({"session": session_name(root, &s.session), "prompt": s.prompt_id, "at": s.at, "ms": s.ms, "waker": s.waker, "released_by": s.released_by}))
        .collect();
    let pw = &stages.get("prompt_write").cloned().unwrap_or(Value::Null);
    let finding = format!(
        "acpmux prompt write (turn_started -> session/prompt): speed of light {SOL_PROMPT_WRITE_MS} ms, measured p50 {} ms, p99 {} ms, max {} s. {} stalls (>= {} s with nothing running) held prompts {} s in {:.0} h, longest {} s; {} of them ({} s) were released within {RELEASE_MS} ms of an unrelated event (a lost wakeup)",
        crate::field(pw, "p50_ms"),
        crate::field(pw, "p99_ms"),
        crate::field(pw, "max_ms").as_i64().unwrap_or(0) / 1000,
        stalls.len(),
        STALL_MS / 1000,
        stall_sum / 1000,
        hours,
        stalls.first().map(|s| s.ms / 1000).unwrap_or(0),
        by_event,
        by_event_ms / 1000,
    );
    json!({
        "schema": "critpath/v1", "host": host, "at": at_ms, "window_h": hours,
        "source": "acpmux session events", "sessions": report.sessions_read, "turns": report.graphs.len(),
        "elapsed_s": rollup.elapsed_ms / 1000,
        "path_by_state_s": rollup.states.iter().map(|(s, ms)| (s.as_str().to_string(), json!(ms / 1000))).collect::<serde_json::Map<_, _>>(),
        "stages": stages, "drag": drag,
        "stalls": {"count": stalls.len(), "sum_s": stall_sum / 1000, "threshold_ms": STALL_MS, "top": top,
                   "wakers": count_sum(&wakers), "released_by": count_sum(&released)},
        "finding": finding,
    })
}
