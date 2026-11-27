//! A display model built from acpmux events. Shared by the CLI stream view
//! and the TUI so both render the same thing.

use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    User {
        text: String,
        steer: bool,
        queued: bool,
    },
    Assistant {
        text: String,
    },
    Thought {
        text: String,
    },
    Tool {
        id: String,
        title: String,
        kind: String,
        status: String,
        detail: String,
    },
    Permission {
        id: String,
        title: String,
        options: Vec<(String, String, String)>,
        decided: Option<String>,
        /// The request's `toolCall._meta.acpmux.question`: a question a
        /// person answers (question_answer.rs), never a blank allow.
        question: Option<Value>,
    },
    Status {
        text: String,
    },
    TurnEnd {
        stop: String,
    },
    Error {
        text: String,
    },
    Stderr {
        text: String,
    },
}

/// A person's prompt the daemon queued and has not delivered yet. It docks at the tail, outside
/// `items`, until its `user_message` arrives: rows that arrive meanwhile draw above it, and it
/// joins `items` at its delivery point, so the transcript keeps the order things came in.
#[derive(Debug, Clone, PartialEq)]
pub struct QueuedPrompt {
    /// The text shown: the record's, or the local echo's (image names included).
    pub text: String,
    /// The daemon's `promptId`; `None` for a local echo the daemon has not queued yet.
    pub prompt_id: Option<String>,
}

/// The `dir` of a record `push_local_error` keeps: an error this client showed, with no seq.
const LOCAL_ERROR: &str = "local_error";

#[derive(Debug, Default, Clone)]
pub struct Transcript {
    pub items: Vec<Item>,
    /// Queued prompts, oldest first: drawn after `items` until each is delivered.
    pub queue: Vec<QueuedPrompt>,
    /// Event records currently represented by `items`, kept only when `keeps_records` is set
    /// (the TUI's transcripts, which page older history in): they let it rebuild the display
    /// with an older page in front without reordering live updates. A CLI stream keeps none.
    pub(crate) raw_events: Vec<Value>,
    pub(crate) keeps_records: bool,
    /// Earliest item whose layout may have changed since the TUI consumed it.
    /// Streaming invalidates the mutable tail, not the entire conversation.
    pub layout_dirty_from: usize,
    pub last_seq: u64,
    pub status: String,
    pub mode: Option<String>,
    pub model: Option<String>,
    pub usage: Option<(u64, u64)>,
    pub available_commands: Vec<String>,
    /// What each of `available_commands` does, by name, when the agent says (ACP's
    /// `availableCommands[].description`): the terminal's / rows show it, as the GUI's do (#50541).
    pub command_descriptions: std::collections::BTreeMap<String, String>,
    /// Transient note for the working row, e.g. an API retry in progress.
    pub note: Option<String>,
    /// Provider-neutral live activity shown by every client.
    pub activity: Option<String>,
    /// Pending or in-progress ACP tool calls.
    pub active_tools: usize,
    /// Pending or in-progress execute/terminal/shell calls.
    pub active_terminals: usize,
    pending_user_chunk: bool,
    /// Texts shown before the daemon echoed them; matched on arrival.
    pub optimistic: Vec<String>,
    /// The rows shown for `optimistic`, by the same index when the sender recorded them (the
    /// TUI does): a rebuild puts them back as shown, steer, queued and image names included.
    pub(crate) optimistic_rows: Vec<Item>,
    /// Unix ms the daemon recorded each user item at (by item index).
    pub user_at: std::collections::HashMap<usize, u64>,
    /// (user item index, turn start ms, turn end ms) per turn seen.
    pub turn_times: Vec<(usize, u64, Option<u64>)>,
    /// Steers the agent has not read yet: (promptId, user item index). A steer that
    /// lands as its turn ends is run as the next prompt and logged again with the
    /// same promptId and no `steer` (`hub/steer_end.rs`); that record replaces its row.
    waiting_steers: Vec<(String, usize)>,
    /// Item indices removed since the TUI last read them, in order, so it can move
    /// state it keys by index (folds) with the rows that stay.
    pub removed_items: Vec<usize>,
    /// The chat's capacity wait from its session row (`hub/capacity_wait.rs`, the row's
    /// `capacityWait`): acpmux holds the cut turn and goes on by itself. A client draws that
    /// turn's error as a calm wait, never red. Set by the TUI from the row; None otherwise.
    pub capacity_wait: Option<Value>,
    /// The turn's own subagents still running (`_meta.acpmux.subagents`, `subagents.rs`), by id,
    /// each with the wall-clock ms it started: what the working row's "waiting on N subagents"
    /// counts and times. One that outlives its turn (`background`) is never waited on.
    pub subagents_running: std::collections::BTreeMap<String, u64>,
}

/// Line diff of two texts: `+`, `-` and ` ` prefixed lines, in order. LCS
/// on lines, bounded so a huge file falls back to "everything changed".
pub fn diff_lines(old: &str, new: &str) -> Vec<(char, String)> {
    let a: Vec<&str> = old.lines().collect();
    let b: Vec<&str> = new.lines().collect();
    if a.len() * b.len() > 400_000 {
        let mut out: Vec<(char, String)> = a.iter().map(|l| ('-', l.to_string())).collect();
        out.extend(b.iter().map(|l| ('+', l.to_string())));
        return out;
    }
    let (n, m) = (a.len(), b.len());
    // Cell `i * width + j`: the longest common subsequence of `a[i..]` and `b[j..]`.
    let width = m + 1;
    let mut lcs = vec![0u32; (n + 1) * width];
    let at = |lcs: &[u32], i: usize, j: usize| lcs.get(i * width + j).copied().unwrap_or(0);
    for (i, x) in a.iter().enumerate().rev() {
        for (j, y) in b.iter().enumerate().rev() {
            let v = if x == y {
                at(&lcs, i + 1, j + 1) + 1
            } else {
                at(&lcs, i + 1, j).max(at(&lcs, i, j + 1))
            };
            if let Some(cell) = lcs.get_mut(i * width + j) {
                *cell = v;
            }
        }
    }
    let (mut i, mut j) = (0, 0);
    let mut out = Vec::new();
    while let (Some(x), Some(y)) = (a.get(i), b.get(j)) {
        if x == y {
            out.push((' ', x.to_string()));
            i += 1;
            j += 1;
        } else if at(&lcs, i + 1, j) >= at(&lcs, i, j + 1) {
            out.push(('-', x.to_string()));
            i += 1;
        } else {
            out.push(('+', y.to_string()));
            j += 1;
        }
    }
    out.extend(a.get(i..).unwrap_or_default().iter().map(|l| ('-', l.to_string())));
    out.extend(b.get(j..).unwrap_or_default().iter().map(|l| ('+', l.to_string())));
    out
}

/// A diff block as transcript detail: the path, then changed lines with two
/// lines of context, hunks separated by `…`.
pub fn diff_text(path: &str, old: &str, new: &str) -> String {
    let lines = diff_lines(old, new);
    let keep: Vec<bool> = (0..lines.len())
        .map(|i| {
            let lo = i.saturating_sub(2);
            let hi = (i + 3).min(lines.len());
            lines.get(lo..hi).unwrap_or_default().iter().any(|(k, _)| *k != ' ')
        })
        .collect();
    let mut out = String::new();
    if !path.is_empty() {
        out.push_str(&format!("@@ {path}\n"));
    }
    let mut gap = false;
    for ((k, l), &kept) in lines.iter().zip(&keep) {
        if !kept {
            gap = true;
            continue;
        }
        if gap && !out.is_empty() && !out.ends_with("@@ ") {
            out.push_str("…\n");
            gap = false;
        }
        out.push(*k);
        out.push(' ');
        out.push_str(l);
        out.push('\n');
    }
    out.trim_end().to_owned()
}

/// (+lines, -lines) when `detail` is a diff, else None.
pub fn diff_counts(detail: &str) -> Option<(usize, usize)> {
    if !detail.starts_with("@@ ")
        && !detail.lines().any(|l| l.starts_with("+ ") || l.starts_with("- "))
    {
        return None;
    }
    let plus = detail.lines().filter(|l| l.starts_with("+ ")).count();
    let minus = detail.lines().filter(|l| l.starts_with("- ")).count();
    if plus + minus == 0 { None } else { Some((plus, minus)) }
}

fn text_of(content: &Value) -> String {
    match content {
        Value::Array(items) => items.iter().map(text_of).collect::<Vec<_>>().join(""),
        Value::Object(o) => {
            if let Some(t) = o.get("text").and_then(Value::as_str) {
                t.to_owned()
            } else if let Some(c) = o.get("content") {
                text_of(c)
            } else if o.get("type").and_then(Value::as_str) == Some("image") {
                "[image]".into()
            } else if let Some(r) = o.get("resource") {
                r.get("text").and_then(Value::as_str).unwrap_or("[resource]").to_owned()
            } else {
                String::new()
            }
        }
        Value::String(s) => s.clone(),
        _ => String::new(),
    }
}

/// Whether a user row's `shown` text is prompt `text`: the TUI's echo of a prompt with
/// images adds an `[image: …]` line (`tui/mod.rs`).
fn shows_prompt(shown: &str, text: &str) -> bool {
    match shown.strip_prefix(text) {
        Some("") => true,
        Some(rest) => rest.starts_with(if text.is_empty() { "[image: " } else { "\n[image: " }),
        None => false,
    }
}

impl Transcript {
    pub(crate) fn invalidate_layout(&mut self, from: usize) {
        self.layout_dirty_from = self.layout_dirty_from.min(from);
    }

    /// Removes user item `pos`, keeping the per-item indices after it in step.
    fn remove_user_item(&mut self, pos: usize) -> Item {
        self.invalidate_layout(pos);
        let item = self.items.remove(pos);
        self.removed_items.push(pos);
        let moved: std::collections::HashMap<usize, u64> = self
            .user_at
            .drain()
            .filter_map(|(k, v)| match k.cmp(&pos) {
                std::cmp::Ordering::Equal => None,
                std::cmp::Ordering::Greater => Some((k - 1, v)),
                std::cmp::Ordering::Less => Some((k, v)),
            })
            .collect();
        self.user_at = moved;
        for tt in self.turn_times.iter_mut() {
            if tt.0 > pos {
                tt.0 -= 1;
            }
        }
        self.waiting_steers.retain(|(_, i)| *i != pos);
        for (_, i) in self.waiting_steers.iter_mut() {
            if *i > pos {
                *i -= 1;
            }
        }
        item
    }

    /// Apply a `session/update` params object (live or replayed).
    /// Apply a live or replayed update. Records carry the daemon's sequence
    /// number; anything at or below what was already applied is a duplicate
    /// (an attach snapshot racing a live notification) and is dropped.
    pub fn apply_update(&mut self, params: &Value) {
        if let Some(seq) = params.pointer("/_meta/acpmux/seq").and_then(Value::as_u64) {
            if seq <= self.last_seq {
                return;
            }
            self.last_seq = seq;
        }
        // Kept so a prepended older page can rebuild the transcript with this update in place.
        if self.keeps_records {
            let seq = params.pointer("/_meta/acpmux/seq").cloned().unwrap_or(Value::Null);
            self.raw_events.push(json!({"seq": seq, "dir": "update", "params": params}));
        }
        self.apply_update_inner(params);
    }

    fn apply_update_inner(&mut self, params: &Value) {
        self.note_subagents(params);
        let Some(update) = params.get("update") else { return };
        // A subagent's words are its own view's, never the chat's reply.
        if crate::subagents::is_subagents(params) && is_words(update) {
            return;
        }
        self.apply_session_update(update);
    }

    pub fn apply_session_update(&mut self, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let from = match kind {
            "agent_message_chunk" | "agent_thought_chunk" | "user_message_chunk" => {
                self.items.len().saturating_sub(1)
            }
            "tool_call" | "tool_call_update" => {
                let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or("");
                self.items
                    .iter()
                    .rposition(|i| matches!(i, Item::Tool { id: tid, .. } if tid == id))
                    .unwrap_or(self.items.len())
            }
            _ => self.items.len(),
        };
        self.invalidate_layout(from);
        match kind {
            "user_message_chunk" => {
                let t = text_of(update.get("content").unwrap_or(&Value::Null));
                match self.items.last_mut() {
                    Some(Item::User { text, steer: false, .. })
                        if !text.is_empty() && self.pending_user_chunk =>
                    {
                        text.push_str(&t)
                    }
                    _ => self.items.push(Item::User { text: t, steer: false, queued: false }),
                }
                self.pending_user_chunk = true;
                return;
            }
            "agent_message_chunk" => {
                let t = text_of(update.get("content").unwrap_or(&Value::Null));
                match self.items.last_mut() {
                    Some(Item::Assistant { text }) => text.push_str(&t),
                    _ => self.items.push(Item::Assistant { text: t }),
                }
                self.activity = Some("Writing response".into());
            }
            "agent_thought_chunk" => {
                let t = text_of(update.get("content").unwrap_or(&Value::Null));
                match self.items.last_mut() {
                    Some(Item::Thought { text }) => text.push_str(&t),
                    _ => self.items.push(Item::Thought { text: t }),
                }
                let preview = self.items.iter().rev().find_map(|item| match item {
                    Item::Thought { text } => {
                        text.lines().find(|line| !line.trim().is_empty()).map(str::trim)
                    }
                    _ => None,
                });
                self.activity = Some(
                    preview
                        .map(|line| line.chars().take(120).collect::<String>())
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "Thinking".into()),
                );
            }
            "tool_call" | "tool_call_update" => {
                let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or("").to_owned();
                let title = update.get("title").and_then(Value::as_str).map(str::to_owned);
                let tkind = update.get("kind").and_then(Value::as_str).map(str::to_owned);
                let status = update.get("status").and_then(Value::as_str).map(str::to_owned);
                let mut detail = String::new();
                if let Some(c) = update.get("content").and_then(Value::as_array) {
                    for block in c {
                        // ACP diff blocks: {type: "diff", path, oldText, newText}.
                        let t = if block.get("type").and_then(Value::as_str) == Some("diff") {
                            let old = block.get("oldText").and_then(Value::as_str).unwrap_or("");
                            let new = block.get("newText").and_then(Value::as_str).unwrap_or("");
                            let path = block.get("path").and_then(Value::as_str).unwrap_or("");
                            diff_text(path, old, new)
                        } else {
                            text_of(block)
                        };
                        if !t.is_empty() {
                            if !detail.is_empty() {
                                detail.push('\n');
                            }
                            detail.push_str(&t);
                        }
                    }
                }
                if detail.is_empty()
                    && let Some(o) = update.get("rawOutput")
                {
                    detail = match o {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                }
                if detail.len() > 4000 {
                    let mut cut = 4000;
                    while !detail.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    detail.truncate(cut);
                    detail.push_str("\n…");
                }
                if let Some(existing) = self.items.iter_mut().rev().find_map(|i| match i {
                    Item::Tool { id: tid, .. } if *tid == id => Some(i),
                    _ => None,
                }) {
                    if let Item::Tool { title: et, kind: ek, status: es, detail: ed, .. } = existing
                    {
                        if let Some(t) = title {
                            *et = t;
                        }
                        if let Some(k) = tkind {
                            *ek = k;
                        }
                        if let Some(s) = status {
                            *es = s;
                        }
                        if !detail.is_empty() {
                            *ed = detail;
                        }
                    }
                } else {
                    self.items.push(Item::Tool {
                        id,
                        title: title.unwrap_or_else(|| "tool".into()),
                        kind: tkind.unwrap_or_default(),
                        status: status.unwrap_or_else(|| "pending".into()),
                        detail,
                    });
                }
                self.refresh_activity();
            }
            "usage_update" => {
                let used = update.get("used").and_then(Value::as_u64).unwrap_or(0);
                let size = update.get("size").and_then(Value::as_u64).unwrap_or(0);
                self.usage = Some((used, size));
            }
            "current_mode_update" => {
                self.mode = update.get("currentModeId").and_then(Value::as_str).map(str::to_owned);
            }
            "config_option_update" => {
                if let Some(opts) = update.get("configOptions").and_then(Value::as_array) {
                    for o in opts {
                        if o.get("id").and_then(Value::as_str) == Some("model") {
                            self.model =
                                o.get("currentValue").and_then(Value::as_str).map(str::to_owned);
                        }
                    }
                }
            }
            "available_commands_update" => {
                let listed =
                    update.get("availableCommands").and_then(Value::as_array).map(Vec::as_slice);
                self.available_commands = listed
                    .unwrap_or_default()
                    .iter()
                    .filter_map(|c| c.get("name").and_then(Value::as_str).map(str::to_owned))
                    .collect();
                self.command_descriptions = listed
                    .unwrap_or_default()
                    .iter()
                    .filter_map(|c| {
                        let name = c.get("name").and_then(Value::as_str)?;
                        let text = c.get("description").and_then(Value::as_str)?.trim();
                        (!text.is_empty()).then(|| (name.to_owned(), text.to_owned()))
                    })
                    .collect();
            }
            _ => {}
        }
        self.pending_user_chunk = false;
    }

    /// Derive one stable live activity line from ACP's provider-specific
    /// update stream. This is intentionally based on normalized transcript
    /// items so all harnesses render the same semantics.
    fn refresh_activity(&mut self) {
        self.active_tools = self
            .items
            .iter()
            .filter(|item| {
                matches!(item,
                    Item::Tool { status, .. } if status == "pending" || status == "in_progress"
                )
            })
            .count();
        self.active_terminals = self.items.iter().filter(|item| matches!(item,
            Item::Tool { kind, status, .. } if matches!(kind.as_str(), "execute" | "terminal" | "shell") && (status == "pending" || status == "in_progress")
        )).count();
        if let Some(title) = self.items.iter().rev().find_map(|item| match item {
            Item::Tool { title, status, .. } if status == "pending" || status == "in_progress" => {
                Some(title.as_str())
            }
            _ => None,
        }) {
            self.activity = Some(title.chars().take(120).collect());
        } else if self.status == "running" && self.activity.is_none() {
            self.activity = Some("Thinking".into());
        }
    }

    /// Apply one `_acpmux/event` record (mux-internal or raw wire).
    /// Wall time of the turn that started at user item `idx`: (start, end).
    pub fn turn_span(&self, idx: usize) -> Option<(u64, Option<u64>)> {
        self.turn_times.iter().rev().find(|(u, _, _)| *u == idx).map(|(_, s, e)| (*s, *e))
    }

    pub fn apply_event(&mut self, ev: &Value) {
        if let Some(seq) = ev.get("seq").and_then(Value::as_u64) {
            if seq <= self.last_seq {
                return;
            }
            self.last_seq = seq;
        }
        if self.keeps_records {
            self.raw_events.push(ev.clone());
        }
        self.apply_event_inner(ev);
    }

    fn apply_event_inner(&mut self, ev: &Value) {
        let dir = ev.get("dir").and_then(Value::as_str).unwrap_or("");
        let kind = ev.get("kind").and_then(Value::as_str).unwrap_or("");
        let msg = ev.get("msg").unwrap_or(&Value::Null);
        let at = ev.get("at").and_then(Value::as_u64).unwrap_or(0);
        if dir == "in" {
            if kind.ends_with(".replay") {
                return;
            }
            if msg.get("method").and_then(Value::as_str) == Some("session/update")
                && let Some(update) = msg.pointer("/params/update")
                && !(msg.get("params").is_some_and(crate::subagents::is_subagents)
                    && is_words(update))
            {
                self.apply_session_update(update);
            }
            return;
        }
        if dir != "mux" {
            return;
        }
        // A line the harness wrote into a turn (a task notification) is no prompt to draw here.
        if kind == "user_message" && crate::adopt_replay::harness_row(msg) {
            return;
        }
        // A queued user can be promoted out of the middle of the transcript,
        // and a permission decision can update an older item.
        let from = match kind {
            "permission_decision" | "permission_auto" => {
                let id = msg.get("permissionId").and_then(Value::as_str).unwrap_or("");
                self.items
                    .iter()
                    .rposition(|i| matches!(i, Item::Permission { id: pid, .. } if pid == id))
                    .unwrap_or(self.items.len())
            }
            _ => self.items.len().saturating_sub(1),
        };
        self.invalidate_layout(from);
        self.pending_user_chunk = false;
        match kind {
            "queued" => {
                let text = msg.get("text").and_then(Value::as_str).unwrap_or("");
                let prompt_id =
                    msg.get("promptId").and_then(Value::as_str).filter(|p| !p.is_empty());
                self.dock(text, prompt_id);
            }
            // Withdrawn, refused, or joined into a digest: it never arrives as itself.
            "queue_removed" | "prompt_refused" | "dequeued" => {
                if let Some(id) =
                    msg.get("promptId").and_then(Value::as_str).filter(|p| !p.is_empty())
                    && let Some(pos) =
                        self.queue.iter().position(|q| q.prompt_id.as_deref() == Some(id))
                {
                    let q = self.queue.remove(pos);
                    self.take_optimistic_shown(&q.text);
                }
            }
            "user_message" => {
                let text = msg.get("text").and_then(Value::as_str).unwrap_or("").to_owned();
                let steer = msg.get("steer").and_then(Value::as_bool).unwrap_or(false);
                let prompt_id = msg.get("promptId").and_then(Value::as_str).unwrap_or("");
                if !steer
                    && !prompt_id.is_empty()
                    && let Some(w) = self.waiting_steers.iter().position(|(id, _)| id == prompt_id)
                {
                    // A steer the turn ended before reading, now run as this prompt: its row
                    // gives way. Only its own: another steer's re-run may still be queued.
                    let (_, pos) = self.waiting_steers.remove(w);
                    self.remove_user_item(pos);
                }
                // A queued prompt leaves the dock when it is delivered and takes its place at
                // the delivery point, the end of `items`: nothing already shown moves. It is
                // matched by promptId, so two prompts with the same text deliver in order; by
                // text only when one side has no id (an old record, or a local echo the daemon
                // has not queued yet). A steer starts no turn, so it never takes a queued one.
                let docked = if steer { None } else { self.docked(&text, prompt_id) };
                match docked {
                    Some(pos) => {
                        let q = self.queue.remove(pos);
                        self.items.push(Item::User { text: q.text, steer: false, queued: false });
                        // A docked local echo was this message's: it is consumed.
                        self.take_optimistic(&text);
                    }
                    None => {
                        // Already on screen from the local echo, or shown now.
                        if !self.take_optimistic(&text) {
                            self.items.push(Item::User {
                                text: text.clone(),
                                steer,
                                queued: false,
                            });
                        }
                    }
                }
                if steer
                    && !prompt_id.is_empty()
                    && let Some(idx) = (0..self.items.len()).rev().find(|&i| {
                        let shown = match self.items.get(i) {
                            Some(Item::User { text: t, steer: true, .. }) => shows_prompt(t, &text),
                            _ => false,
                        };
                        shown && !self.waiting_steers.iter().any(|(_, w)| *w == i)
                    })
                {
                    self.waiting_steers.push((prompt_id.to_owned(), idx));
                }
                if let Some(idx) = self.items.iter().rposition(|i| matches!(i, Item::User { .. }))
                    && at > 0
                {
                    self.user_at.entry(idx).or_insert(at);
                }
            }
            "turn_started" => {
                if let Some(idx) = self.items.iter().rposition(|i| matches!(i, Item::User { .. })) {
                    self.turn_times.push((idx, at, None));
                }
            }
            "turn_result" => {
                if let Some(last) = self.turn_times.last_mut()
                    && last.2.is_none()
                {
                    last.2 = Some(at);
                }
            }
            "status" => {
                self.status = msg.get("status").and_then(Value::as_str).unwrap_or("").to_owned();
                if self.status == "running" {
                    self.refresh_activity();
                } else {
                    self.activity = None;
                    self.active_tools = 0;
                    self.active_terminals = 0;
                    self.subagents_running.clear();
                }
            }
            "claude.system.api_retry" => {
                let attempt = msg.get("attempt").and_then(Value::as_u64).unwrap_or(0);
                let max = msg.get("max_retries").and_then(Value::as_u64).unwrap_or(0);
                let err = msg
                    .get("error")
                    .and_then(Value::as_str)
                    .filter(|e| *e != "unknown")
                    .map(|e| format!(" ({e})"))
                    .unwrap_or_default();
                self.note = Some(format!("API retry {attempt}/{max}{err}"));
            }
            "turn_end"
                if {
                    self.note = None;
                    true
                } =>
            {
                self.activity = None;
                self.active_tools = 0;
                self.active_terminals = 0;
                self.subagents_running.clear();
                if let Some(last) = self.turn_times.last_mut()
                    && last.2.is_none()
                {
                    last.2 = Some(at);
                }
                self.items.push(Item::TurnEnd {
                    stop: msg
                        .get("stopReason")
                        .and_then(Value::as_str)
                        .unwrap_or("end_turn")
                        .to_owned(),
                })
            }
            "turn_error" => self.items.push(Item::Error {
                text: msg.get("error").and_then(Value::as_str).unwrap_or("turn failed").to_owned(),
            }),
            "permission_request" => {
                let id = msg.get("permissionId").and_then(Value::as_str).unwrap_or("").to_owned();
                let req = msg.get("request").unwrap_or(&Value::Null);
                let title = req
                    .pointer("/toolCall/title")
                    .and_then(Value::as_str)
                    .unwrap_or("permission")
                    .to_owned();
                let options = req
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(|o| {
                                (
                                    o.get("optionId")
                                        .and_then(Value::as_str)
                                        .unwrap_or("")
                                        .to_owned(),
                                    o.get("name").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    o.get("kind").and_then(Value::as_str).unwrap_or("").to_owned(),
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let question = crate::question_answer::question(req).cloned();
                self.items.push(Item::Permission { id, title, options, decided: None, question });
            }
            "permission_decision" | "permission_auto" => {
                let id = msg.get("permissionId").and_then(Value::as_str).unwrap_or("");
                let decided = msg
                    .pointer("/outcome/optionId")
                    .or_else(|| msg.get("optionId"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| {
                        msg.pointer("/outcome/outcome").and_then(Value::as_str).map(str::to_owned)
                    })
                    .unwrap_or_else(|| "cancelled".into());
                let mut found = false;
                for item in self.items.iter_mut().rev() {
                    if let Item::Permission { id: pid, decided: d, .. } = item
                        && pid == id
                    {
                        *d = Some(decided.clone());
                        found = true;
                        break;
                    }
                }
                if !found && kind == "permission_auto" {
                    let title = msg
                        .pointer("/request/toolCall/title")
                        .and_then(Value::as_str)
                        .unwrap_or("permission")
                        .to_owned();
                    self.items.push(Item::Permission {
                        id: id.to_owned(),
                        title,
                        options: vec![],
                        decided: Some(decided),
                        question: None,
                    });
                }
            }
            "stderr" => self.items.push(Item::Stderr {
                text: msg.get("text").and_then(Value::as_str).unwrap_or("").to_owned(),
            }),
            // A hibernation (the idle exit, `hub/idle.rs`) and its wake are not the person's to
            // see: the chat reads as it did.
            "exited" | "stopped"
                if msg.get("hibernated").and_then(Value::as_bool) == Some(true) => {}
            "resumed" if msg.get("wake").and_then(Value::as_bool) == Some(true) => {}
            "exited" => self.items.push(Item::Status { text: exited_text(msg) }),
            "stopped" => self.items.push(Item::Status { text: "agent stopped".into() }),
            "resumed" => self.items.push(Item::Status {
                text: format!(
                    "resumed ({})",
                    msg.get("level").and_then(Value::as_str).unwrap_or("?")
                ),
            }),
            "resume_failed" => self.items.push(Item::Status {
                text: format!(
                    "resume failed: {}",
                    msg.get("error").and_then(Value::as_str).unwrap_or("?")
                ),
            }),
            "forked" => self.items.push(Item::Status { text: "forked from parent".into() }),
            "reopened" => self.items.push(Item::Status { text: "reopened".into() }),
            "imported" => self.items.push(Item::Status { text: "imported".into() }),
            "mode" => {
                self.mode = msg.get("modeId").and_then(Value::as_str).map(str::to_owned);
                self.items.push(Item::Status {
                    text: format!("mode: {}", self.mode.clone().unwrap_or_default()),
                });
            }
            "model" => {
                self.model = msg.get("modelId").and_then(Value::as_str).map(str::to_owned);
                self.items.push(Item::Status {
                    text: format!("model: {}", self.model.clone().unwrap_or_default()),
                });
            }
            // The settings a new agent was given again (`replay_config`): nothing changed, and a
            // wake from hibernation does it every time.
            "config" if msg.get("replayed").and_then(Value::as_bool) == Some(true) => {}
            "config" => {
                if msg.get("configId").and_then(Value::as_str) == Some("model") {
                    self.model = msg.get("value").and_then(Value::as_str).map(str::to_owned);
                }
                self.items.push(Item::Status {
                    text: format!(
                        "{} = {}",
                        msg.get("configId").and_then(Value::as_str).unwrap_or("?"),
                        msg.get("value").map(|v| v.to_string()).unwrap_or_default()
                    ),
                });
            }
            "renamed" => self.items.push(Item::Status {
                text: format!(
                    "renamed to {}",
                    msg.get("to").and_then(Value::as_str).unwrap_or("?")
                ),
            }),
            _ => {}
        }
    }

    /// Prepend an older event page and rebuild the transcript in sequence order. Only records
    /// older than every record already held are taken, so a page that overlaps what is shown
    /// (or arrives after live records) adds each record once and keeps live ones in place.
    /// Returns the number of display items added before the old ones: the items already shown
    /// are the rebuilt transcript's tail, so per-item state moves down by that count.
    pub fn prepend_events(&mut self, older: &[Value]) -> usize {
        if !self.keeps_records {
            return 0; // nothing to rebuild what is shown from
        }
        let seq_of = |e: &Value| e.get("seq").and_then(Value::as_u64);
        let oldest = self.oldest_seq();
        let mut page: Vec<Value> = older
            .iter()
            .filter(|e| seq_of(e).is_some_and(|s| oldest.is_none_or(|o| s < o)))
            .cloned()
            .collect();
        if page.is_empty() {
            return 0;
        }
        page.sort_by_key(|e| seq_of(e).unwrap_or(0));
        page.dedup_by(|a, b| seq_of(a) == seq_of(b));
        let previous_items = self.items.len();
        let mut rebuilt = Transcript::paging();
        for event in page.iter().chain(self.raw_events.iter()) {
            rebuilt.apply_record(event);
        }
        // Messages sent but not yet echoed stay last, as they were shown; a queued one goes
        // back to the dock, onto the entry the replay docked for it when the daemon queued it.
        if self.optimistic_rows.len() == self.optimistic.len() {
            let mut adopted = vec![false; rebuilt.queue.len()];
            for (text, row) in self.optimistic.iter().zip(&self.optimistic_rows) {
                match row {
                    Item::User { text: shown, queued: true, .. } => {
                        let found = rebuilt.queue.iter().zip(&adopted).position(|(q, taken)| {
                            !*taken && q.prompt_id.is_some() && q.text == *text
                        });
                        let slot =
                            found.and_then(|n| adopted.get_mut(n).zip(rebuilt.queue.get_mut(n)));
                        match slot {
                            Some((taken, q)) => {
                                *taken = true;
                                q.text.clone_from(shown);
                            }
                            None => rebuilt
                                .queue
                                .push(QueuedPrompt { text: shown.clone(), prompt_id: None }),
                        }
                    }
                    _ => rebuilt.items.push(row.clone()),
                }
            }
        } else {
            rebuilt.items.extend(self.optimistic.iter().map(|text| Item::User {
                text: text.clone(),
                steer: false,
                queued: false,
            }));
        }
        rebuilt.optimistic = std::mem::take(&mut self.optimistic);
        rebuilt.optimistic_rows = std::mem::take(&mut self.optimistic_rows);
        // State the TUI sets from the session detail after attach, and the newest values the
        // live records already gave, are the old transcript's.
        rebuilt.last_seq = rebuilt.last_seq.max(self.last_seq);
        rebuilt.status = std::mem::take(&mut self.status);
        rebuilt.mode = self.mode.take();
        rebuilt.model = self.model.take();
        rebuilt.usage = self.usage.take().or(rebuilt.usage);
        if !self.available_commands.is_empty() {
            rebuilt.available_commands = std::mem::take(&mut self.available_commands);
            rebuilt.command_descriptions = std::mem::take(&mut self.command_descriptions);
        }
        // A rebuild names every row afresh: folds move by the prepended count, not by
        // removals the replay made along the way.
        rebuilt.removed_items.clear();
        rebuilt.layout_dirty_from = 0;
        *self = rebuilt;
        self.items.len().saturating_sub(previous_items)
    }

    /// Re-apply one stored record during a rebuild: a mux event, or a live `session/update`
    /// that `apply_update` stored as one.
    fn apply_record(&mut self, ev: &Value) {
        if let Some(seq) = ev.get("seq").and_then(Value::as_u64) {
            self.last_seq = self.last_seq.max(seq);
        }
        self.raw_events.push(ev.clone());
        if ev.get("dir").and_then(Value::as_str) == Some("update")
            && let Some(params) = ev.get("params")
        {
            self.apply_update_inner(params);
        } else if ev.get("dir").and_then(Value::as_str) == Some(LOCAL_ERROR) {
            let text = ev.get("text").and_then(Value::as_str).unwrap_or_default();
            self.items.push(Item::Error { text: text.to_string() });
        } else {
            self.apply_event_inner(ev);
        }
    }

    /// A transcript that keeps its records, so `prepend_events` can page older history in.
    pub fn paging() -> Self {
        Transcript { keeps_records: true, ..Transcript::default() }
    }

    /// Show an error this client raised (not one the daemon logged). A paging transcript keeps it
    /// as a record with no seq, so a rebuild puts it back where it was shown.
    pub fn push_local_error(&mut self, text: String) {
        if self.keeps_records {
            self.raw_events.push(json!({"dir": LOCAL_ERROR, "text": text}));
        }
        self.items.push(Item::Error { text });
    }

    /// Record a message shown before the daemon echoes it, with the row it is shown as.
    /// A queued row (sent while a turn runs) docks at the tail, not in `items`.
    pub fn push_optimistic(&mut self, text: String, row: Item) {
        match &row {
            Item::User { text: shown, queued: true, .. } => {
                self.queue.push(QueuedPrompt { text: shown.clone(), prompt_id: None });
                self.invalidate_layout(self.items.len().saturating_sub(1));
            }
            _ => self.items.push(row.clone()),
        }
        self.optimistic.push(text);
        if self.optimistic_rows.len() + 1 == self.optimistic.len() {
            self.optimistic_rows.push(row);
        }
    }

    /// Dock a `queued` record: once per promptId (a digest that fails queues its prompts
    /// again), onto this client's local echo of it when one waits, else at the tail.
    fn dock(&mut self, text: &str, prompt_id: Option<&str>) {
        if let Some(id) = prompt_id
            && self.queue.iter().any(|q| q.prompt_id.as_deref() == Some(id))
        {
            return;
        }
        let echo =
            self.queue.iter_mut().find(|q| q.prompt_id.is_none() && shows_prompt(&q.text, text));
        match echo {
            Some(q) if prompt_id.is_some() => q.prompt_id = prompt_id.map(str::to_owned),
            _ => self.queue.push(QueuedPrompt {
                text: text.to_owned(),
                prompt_id: prompt_id.map(str::to_owned),
            }),
        }
    }

    /// The dock entry a delivered prompt is: by promptId, else by text when either side has
    /// no id. The oldest match, so same-text prompts without ids still deliver in order.
    fn docked(&self, text: &str, prompt_id: &str) -> Option<usize> {
        if !prompt_id.is_empty()
            && let Some(pos) =
                self.queue.iter().position(|q| q.prompt_id.as_deref() == Some(prompt_id))
        {
            return Some(pos);
        }
        self.queue.iter().position(|q| {
            (prompt_id.is_empty() || q.prompt_id.is_none()) && shows_prompt(&q.text, text)
        })
    }

    /// Consume the local echo shown as SHOWN (a dock entry's text), if one is pending.
    fn take_optimistic_shown(&mut self, shown: &str) {
        if let Some(pos) = self.optimistic.iter().position(|t| shows_prompt(shown, t)) {
            self.optimistic.remove(pos);
            if pos < self.optimistic_rows.len() {
                self.optimistic_rows.remove(pos);
            }
        }
    }

    /// Consume the local echo of TEXT, if one is pending.
    fn take_optimistic(&mut self, text: &str) -> bool {
        let Some(pos) = self.optimistic.iter().position(|t| t == text) else { return false };
        self.optimistic.remove(pos);
        if pos < self.optimistic_rows.len() {
            self.optimistic_rows.remove(pos);
        }
        true
    }

    pub fn oldest_seq(&self) -> Option<u64> {
        self.raw_events.iter().filter_map(|e| e.get("seq").and_then(Value::as_u64)).min()
    }

    pub fn pending_permission(&self) -> Option<&Item> {
        self.items.iter().rev().find(|i| matches!(i, Item::Permission { decided: None, .. }))
    }
}

/// Plain text of one item, for copying.
pub fn item_text(item: &Item) -> String {
    match item {
        Item::User { text, .. }
        | Item::Assistant { text }
        | Item::Thought { text }
        | Item::Error { text }
        | Item::Stderr { text }
        | Item::Status { text } => text.clone(),
        Item::Tool { title, detail, .. } => {
            if detail.is_empty() {
                title.clone()
            } else {
                format!("{title}\n{detail}")
            }
        }
        Item::Permission { title, .. } => title.clone(),
        Item::TurnEnd { stop } => stop.clone(),
    }
}

#[cfg(test)]
#[path = "transcript_tests.rs"]
mod tests;

/// What an `exited` record (an agent process that ended with no Stop, close or idle exit asking:
/// `hub/exit_reason.rs`) reads as. Never "agent stopped", its code 0 included: that is what a
/// Stop reads as, and nobody stopped it. Its stderr's `reason` and `error` say why, when it said.
fn exited_text(msg: &Value) -> String {
    let code = msg.get("code").filter(|c| !c.is_null()).map_or("?".to_owned(), Value::to_string);
    let why = match msg.get("reason").and_then(Value::as_str) {
        Some("rate_limit") => ", rate limited",
        Some("capacity") => ", no capacity upstream",
        Some("transport") => ", connection lost",
        Some("context") => ", context window full",
        Some("auth") => ", signed out",
        _ => "",
    };
    let mut text = format!("agent exited unexpectedly (code {code}{why})");
    if let Some(error) = msg.get("error").and_then(Value::as_str) {
        text.push_str(": ");
        text.push_str(error);
    }
    // A signed-out harness needs its sign-in first; anything else comes back on the next message.
    if why != ", signed out" {
        text.push_str("; the next message resumes it");
    }
    text
}

impl Transcript {
    /// Track the turn's own running subagents from an update's `_meta.acpmux.subagents`: each by
    /// id with the wall-clock ms it started (its first sighting less the `elapsedMs` it names).
    fn note_subagents(&mut self, params: &Value) {
        let Some(list) = params.pointer("/_meta/acpmux/subagents").and_then(Value::as_array) else {
            return;
        };
        let now = wall_ms();
        for s in list {
            let Some(id) = s.get("id").and_then(Value::as_str) else { continue };
            let own = s.get("parent").is_none_or(Value::is_null);
            let waited = s.get("state").and_then(Value::as_str) == Some("running")
                && s.get("background").and_then(Value::as_bool) != Some(true);
            if own && waited {
                let elapsed = s.get("elapsedMs").and_then(Value::as_u64).unwrap_or(0);
                self.subagents_running.entry(id.to_owned()).or_insert(now.saturating_sub(elapsed));
            } else {
                self.subagents_running.remove(id);
            }
        }
    }

    /// "waiting on N subagents 2m 5s" while the turn's own subagents run: the time is the wait's
    /// own, from the first one's start, never the turn's whole clock (GUI cmux#48009). None when
    /// none runs; one that outlives the turn (`background`) is never waited on.
    pub fn subagent_wait(&self, now_ms: u64) -> Option<String> {
        let n = self.subagents_running.len();
        let since = *self.subagents_running.values().min()?;
        let s = if n == 1 { "" } else { "s" };
        let ms = now_ms.saturating_sub(since);
        let time = if ms >= 1000 { format!(" {}", short_duration(ms)) } else { String::new() };
        Some(format!("waiting on {n} subagent{s}{time}"))
    }
}

fn wall_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn short_duration(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        0..=59 => format!("{s}s"),
        60..=3599 => format!("{}m {}s", s / 60, s % 60),
        _ => format!("{}h {}m", s / 3600, (s % 3600) / 60),
    }
}

/// A message or thought chunk: the words a reader of the chat's own text keeps.
fn is_words(update: &Value) -> bool {
    matches!(
        update.get("sessionUpdate").and_then(Value::as_str),
        Some("agent_message_chunk" | "agent_thought_chunk")
    )
}
