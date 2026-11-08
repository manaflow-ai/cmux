//! A chat's review brief (`_acpmux/review_brief`): what the agent set out to do, the approaches it
//! dropped and why, and the spots it was unsure about, drawn from its own log for whoever reviews
//! its diff.
//!
//! The brief is a [`Fold`] of the chat's records: its first prompt, its latest plan (an ACP `plan`
//! update, or a plan tool's `rawInput.plan`), the sentences of its replies that hedge ("not sure",
//! "couldn't verify") or drop an approach ("didn't work", "instead"), and its edits. An edit that
//! puts back the text an earlier edit replaced is a revert; one that writes that change again is
//! a redo; the same text rewritten three times running is rework. Each of those, and each hedge
//! that names an edited file or follows an edit in its turn, is a spot linked to its file, with the
//! first changed line as the snippet the diff page finds the hunk by.
//!
//! The fold is small and bounded (every list is capped, edits are kept as hashes) and is saved
//! beside the log as `review-brief.json` with the last `seq` it read, so a later open reads only
//! the records past it, and one with no new records reads none (`hub/review_brief.rs`). The words
//! are matched, not judged: the brief shows what the agent said and did, not whether it was right.
//! Leo, 2026-11-08: "go think of things/look at things, esp valuable things that people would
//! think \"wow this is awesome\"".

use crate::store::EventRecord;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;

/// The saved fold's schema; a file of another is read past and folded again.
pub const SCHEMA: &str = "acpmux.review-brief.v1";
/// The file beside the log a chat's fold is kept in.
pub const FILE: &str = "review-brief.json";
/// The kinds a fold reads.
pub const KINDS: &[&str] = &[
    "user_message",
    "agent_message_chunk",
    "tool_call",
    "tool_call_update",
    "plan",
    "turn_started",
    "turn_result",
];

const MAX_GOAL: usize = 600;
const MAX_PLAN_TEXT: usize = 1200;
const MAX_PLAN: usize = 12;
const MAX_NOTE: usize = 280;
const MAX_REJECTED: usize = 6;
const MAX_HEDGES: usize = 10;
const MAX_EDIT_SPOTS: usize = 10;
const MAX_EDITS: usize = 200;
const MAX_SEEN_CALLS: usize = 64;
const MAX_OPEN_TEXT: usize = 16 * 1024;
const MAX_SNIPPET: usize = 120;
/// The most spots one brief lists.
pub const MAX_SPOTS: usize = 12;
/// A prompt shorter than this ("go on", "yes") is not the goal.
const MIN_GOAL: usize = 12;
/// Text past this is not compared line by line for a snippet.
const MAX_DIFF_TEXT: usize = 256 * 1024;

/// Phrases that hedge: the agent says it is not sure the change is right.
const HEDGES: &[&str] = &[
    "not sure",
    "unsure",
    "not certain",
    "uncertain",
    "unclear",
    "i assume",
    "assuming",
    "i guess",
    "best guess",
    "hopefully",
    "can't verify",
    "cannot verify",
    "couldn't verify",
    "could not verify",
    "unable to verify",
    "untested",
    "not tested",
    "haven't tested",
    "didn't test",
    "couldn't test",
    "could not test",
    "might break",
    "may break",
    "might not work",
    "may not work",
    "double-check",
    "double check",
    "worth checking",
    "worth a look",
    "please check",
    "needs review",
    "risky",
    "fragile",
    "a hack",
    "workaround",
];

/// Phrases that drop an approach.
const REJECTIONS: &[&str] = &[
    "didn't work",
    "did not work",
    "doesn't work",
    "does not work",
    "won't work",
    "will not work",
    "not going to work",
    "instead of",
    "instead,",
    "rather than",
    "abandon",
    "ruled out",
    "dead end",
    "scrap",
    "back out",
    "backed out",
    "that failed",
    "failed because",
    "fails because",
    "different approach",
    "another approach",
    "simpler approach",
    "better approach",
    "switch to",
    "switching to",
];

/// One plan entry, as the chat's latest plan has it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlanItem {
    pub content: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub status: String,
}

/// A sentence from a reply: a dropped approach.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub text: String,
    pub seq: u64,
}

/// Why a spot is in the brief.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SpotKind {
    /// The agent's own words hedge.
    Hedge,
    /// An edit put back the text an earlier edit replaced.
    Reverted,
    /// Reverted, then written again.
    Redone,
    /// The same text rewritten again and again.
    Reworked,
}

/// A spot the agent was unsure about.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Spot {
    pub kind: SpotKind,
    /// The hedge's sentence; empty for an edit's spot.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
    /// The file, as the tool call named it (absolute); empty when none is known.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// The first changed line of the edit, which the page finds the hunk by.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub snippet: String,
    /// How many times the text was rewritten (rework).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub count: u32,
    pub seq: u64,
    /// An edit spot's chain: the hash of the text before its first edit.
    #[serde(default, skip_serializing_if = "is_zero64")]
    origin: u64,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

fn is_zero64(n: &u64) -> bool {
    *n == 0
}

/// One edit, kept as hashes: enough to know a later edit undoes or rewrites it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Edit {
    path: String,
    old: u64,
    new: u64,
    /// The text before the chain of edits this one continues.
    origin: u64,
    /// How many edits the chain has, this one included.
    chain: u32,
    /// The chain was reverted (its text went back to `origin`).
    reverted: bool,
}

/// A reply still taking chunks.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct OpenMessage {
    id: String,
    seq: u64,
    text: String,
}

/// A chat's brief so far, and the last record it read.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Fold {
    pub schema: String,
    /// The last record folded.
    pub seq: u64,
    #[serde(default)]
    goal: String,
    #[serde(default)]
    plan_text: String,
    #[serde(default)]
    plan: Vec<PlanItem>,
    #[serde(default)]
    rejected: Vec<Note>,
    #[serde(default)]
    hedges: Vec<Spot>,
    #[serde(default)]
    edit_spots: Vec<Spot>,
    #[serde(default)]
    edits: Vec<Edit>,
    /// The files edited in the running turn, latest last: a hedge naming none links to the last.
    #[serde(default)]
    turn_paths: Vec<String>,
    /// Tool calls whose diff was folded, so an update repeating it is not a second edit.
    #[serde(default)]
    seen_calls: Vec<String>,
    #[serde(default)]
    open: Option<OpenMessage>,
}

impl Default for Fold {
    fn default() -> Self {
        Self {
            schema: SCHEMA.to_owned(),
            seq: 0,
            goal: String::new(),
            plan_text: String::new(),
            plan: Vec::new(),
            rejected: Vec::new(),
            hedges: Vec::new(),
            edit_spots: Vec::new(),
            edits: Vec::new(),
            turn_paths: Vec::new(),
            seen_calls: Vec::new(),
            open: None,
        }
    }
}

impl Fold {
    /// A saved fold, or a new one when the bytes are not one of this schema.
    pub fn read(bytes: &[u8]) -> Self {
        serde_json::from_slice::<Self>(bytes).ok().filter(|f| f.schema == SCHEMA).unwrap_or_default()
    }

    /// Folds one record; records at or before the last one folded are passed.
    pub fn feed(&mut self, rec: &EventRecord) {
        if rec.seq <= self.seq && self.seq > 0 {
            return;
        }
        self.seq = rec.seq;
        if rec.kind.ends_with(".replay") {
            return;
        }
        if rec.kind != "agent_message_chunk" {
            self.close_message();
        }
        match rec.kind.as_str() {
            "user_message" => {
                let steer = rec.msg.get("steer").and_then(Value::as_bool) == Some(true);
                let text = rec.msg.get("text").and_then(Value::as_str).unwrap_or_default().trim();
                if self.goal.is_empty() && !steer && text.chars().count() >= MIN_GOAL {
                    self.goal = clip(text, MAX_GOAL);
                }
            }
            "turn_started" => self.turn_paths.clear(),
            "agent_message_chunk" if rec.dir == "in" => self.chunk(rec),
            "plan" if rec.dir == "in" => {
                let Some(params) = own_params(rec) else { return };
                if let Some(entries) = params.pointer("/update/entries").and_then(Value::as_array) {
                    self.plan = entries
                        .iter()
                        .filter_map(|e| {
                            let content = e.get("content").and_then(Value::as_str)?.trim();
                            (!content.is_empty()).then(|| PlanItem {
                                content: clip(content, MAX_NOTE),
                                status: e
                                    .get("status")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_owned(),
                            })
                        })
                        .take(MAX_PLAN)
                        .collect();
                }
            }
            "tool_call" | "tool_call_update" if rec.dir == "in" => {
                let Some(params) = own_params(rec) else { return };
                let Some(update) = params.get("update") else { return };
                if let Some(plan) = update.pointer("/rawInput/plan").and_then(Value::as_str)
                    && !plan.trim().is_empty()
                {
                    self.plan_text = clip(plan.trim(), MAX_PLAN_TEXT);
                }
                self.tool_edits(rec.seq, update);
            }
            _ => {}
        }
    }

    fn chunk(&mut self, rec: &EventRecord) {
        let Some(params) = own_params(rec) else { return };
        let Some(text) = params.pointer("/update/content/text").and_then(Value::as_str) else {
            return;
        };
        let id = params.pointer("/update/messageId").and_then(Value::as_str).unwrap_or_default();
        if self.open.as_ref().is_some_and(|open| open.id != id) {
            self.close_message();
        }
        let open = self.open.get_or_insert_with(|| OpenMessage {
            id: id.to_owned(),
            seq: rec.seq,
            text: String::new(),
        });
        if open.text.len() + text.len() <= MAX_OPEN_TEXT {
            open.text.push_str(text);
        }
    }

    /// A finished reply: its hedging and rejecting sentences.
    fn close_message(&mut self) {
        let Some(open) = self.open.take() else { return };
        for sentence in sentences(&open.text) {
            let lower = sentence.to_lowercase();
            if HEDGES.iter().any(|h| lower.contains(h)) {
                let path = self.mentioned_path(&lower).unwrap_or_default();
                let spot = Spot {
                    kind: SpotKind::Hedge,
                    text: clip(&sentence, MAX_NOTE),
                    path,
                    line: None,
                    snippet: String::new(),
                    count: 0,
                    seq: open.seq,
                    origin: 0,
                };
                if !self.hedges.iter().any(|h| h.text == spot.text) {
                    push_capped(&mut self.hedges, spot, MAX_HEDGES);
                }
            } else if REJECTIONS.iter().any(|r| lower.contains(r)) {
                let note = Note { text: clip(&sentence, MAX_NOTE), seq: open.seq };
                if !self.rejected.iter().any(|n| n.text == note.text) {
                    push_capped(&mut self.rejected, note, MAX_REJECTED);
                }
            }
        }
    }

    /// The edited file a sentence names by its file name, else the last file edited this turn.
    fn mentioned_path(&self, lower: &str) -> Option<String> {
        let named = self.edits.iter().rev().map(|e| &e.path).find(|path| {
            let name = path.rsplit('/').next().unwrap_or(path).to_lowercase();
            name.contains('.') && lower.contains(&name)
        });
        named.or_else(|| self.turn_paths.last()).cloned()
    }

    fn tool_edits(&mut self, seq: u64, update: &Value) {
        let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or_default();
        let diffs = diffs_of(update);
        if diffs.is_empty() {
            return;
        }
        if !id.is_empty() {
            if self.seen_calls.iter().any(|seen| seen == id) {
                return;
            }
            push_capped(&mut self.seen_calls, id.to_owned(), MAX_SEEN_CALLS);
        }
        let line_of = |path: &str| {
            update.get("locations").and_then(Value::as_array).into_iter().flatten().find_map(|l| {
                (l.get("path").and_then(Value::as_str) == Some(path))
                    .then(|| l.get("line").and_then(Value::as_u64))
                    .flatten()
                    .and_then(|n| u32::try_from(n).ok())
            })
        };
        for (path, old, new) in diffs {
            let line = line_of(&path);
            self.edit(seq, path, &old, &new, line);
        }
    }

    fn edit(&mut self, seq: u64, path: String, old: &str, new: &str, line: Option<u32>) {
        let (old_h, new_h) = (hash(old), hash(new));
        if old_h == new_h {
            return;
        }
        self.turn_paths.retain(|p| p != &path);
        self.turn_paths.push(path.clone());
        if self.turn_paths.len() > MAX_SEEN_CALLS {
            self.turn_paths.remove(0);
        }
        // This edit changes text an earlier edit wrote: it continues that chain.
        let earlier = self.edits.iter().rev().find(|e| e.path == path && e.new == old_h).cloned();
        // This edit writes again a change a reverted chain had written: a redo.
        let redo = self
            .edits
            .iter()
            .rev()
            .find(|e| e.path == path && e.reverted && e.new != e.origin && e.new == new_h)
            .map(|e| e.origin);
        let (origin, chain) = earlier.as_ref().map_or((old_h, 1), |e| (e.origin, e.chain + 1));
        let reverted = earlier.is_some() && new_h == origin;
        let snippet = changed_line(old, new);
        if let Some(origin) = redo {
            self.edit_spot(SpotKind::Redone, &path, origin, line, snippet.clone(), 0, seq);
        } else if reverted {
            self.edit_spot(SpotKind::Reverted, &path, origin, line, changed_line(new, old), 0, seq);
        } else if chain >= 3 {
            self.edit_spot(SpotKind::Reworked, &path, origin, line, snippet, chain - 1, seq);
        }
        if reverted {
            for e in self.edits.iter_mut().filter(|e| e.path == path && e.origin == origin) {
                e.reverted = true;
            }
        }
        let edit = Edit { path, old: old_h, new: new_h, origin, chain, reverted };
        push_capped(&mut self.edits, edit, MAX_EDITS);
    }

    #[allow(clippy::too_many_arguments)]
    fn edit_spot(
        &mut self,
        kind: SpotKind,
        path: &str,
        origin: u64,
        line: Option<u32>,
        snippet: String,
        count: u32,
        seq: u64,
    ) {
        // One spot per chain: a later turn of it (a redo after a revert) takes its place.
        self.edit_spots.retain(|s| !(s.path == path && s.origin == origin));
        let spot = Spot {
            kind,
            text: String::new(),
            path: path.to_owned(),
            line,
            snippet,
            count,
            seq,
            origin,
        };
        push_capped(&mut self.edit_spots, spot, MAX_EDIT_SPOTS);
    }

    /// The brief as the page draws it. With `root`, paths are relative to it, and an edit spot
    /// outside it (not in this diff) is left out; a hedge naming a file outside it keeps its words.
    pub fn brief(&self, root: Option<&str>) -> Value {
        let mut fold = self.clone();
        fold.close_message();
        let relative = |path: &str| -> Option<String> {
            let Some(root) = root.map(|r| r.trim_end_matches('/')).filter(|r| !r.is_empty()) else {
                return Some(path.to_owned());
            };
            path.strip_prefix(root)?.strip_prefix('/').map(str::to_owned)
        };
        let mut spots: Vec<Spot> = fold
            .edit_spots
            .iter()
            .filter_map(|s| Some(Spot { path: relative(&s.path)?, ..s.clone() }))
            .collect();
        let hedges = fold.hedges.iter().map(|s| Spot {
            path: if s.path.is_empty() { String::new() } else { relative(&s.path).unwrap_or_default() },
            ..s.clone()
        });
        let (linked, unlinked): (Vec<Spot>, Vec<Spot>) = hedges.partition(|s| !s.path.is_empty());
        spots.extend(linked);
        spots.extend(unlinked);
        spots.truncate(MAX_SPOTS);
        let unsure: Vec<Value> = spots
            .iter()
            .map(|s| {
                let mut v = serde_json::to_value(s).unwrap_or(Value::Null);
                if let Some(o) = v.as_object_mut() {
                    o.remove("origin");
                }
                v
            })
            .collect();
        json!({
            "goal": fold.goal,
            "planText": fold.plan_text,
            "plan": fold.plan,
            "rejected": fold.rejected,
            "unsure": unsure,
        })
    }
}

/// The params of a record of the chat's own thread (a subagent's are its own).
fn own_params(rec: &EventRecord) -> Option<&Value> {
    rec.msg.get("params").filter(|p| !crate::subagents::is_subagents(p))
}

/// The edits a tool update carries: each ACP `diff` block, else the call's
/// `rawInput` (`file_path` with `old_string`/`new_string`, or `content` for a whole write).
fn diffs_of(update: &Value) -> Vec<(String, String, String)> {
    let mut out = Vec::new();
    for block in update.get("content").and_then(Value::as_array).into_iter().flatten() {
        if block.get("type").and_then(Value::as_str) != Some("diff") {
            continue;
        }
        let Some(path) = block.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()) else {
            continue;
        };
        let text = |key: &str| block.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
        out.push((path.to_owned(), text("oldText"), text("newText")));
    }
    if !out.is_empty() {
        return out;
    }
    let Some(input) = update.get("rawInput") else { return out };
    let path = ["file_path", "filePath"].iter().find_map(|k| input.get(*k).and_then(Value::as_str));
    let new = input.get("new_string").or_else(|| input.get("content")).and_then(Value::as_str);
    if let (Some(path), Some(new)) = (path.filter(|p| !p.is_empty()), new) {
        let old = input.get("old_string").and_then(Value::as_str).unwrap_or_default();
        out.push((path.to_owned(), old.to_owned(), new.to_owned()));
    }
    out
}

/// The first line of `new` that `old` does not have, trimmed; empty when none (or too long to
/// compare).
fn changed_line(old: &str, new: &str) -> String {
    if old.len() > MAX_DIFF_TEXT || new.len() > MAX_DIFF_TEXT {
        return String::new();
    }
    let before: HashSet<&str> = old.lines().map(str::trim).collect();
    new.lines()
        .map(str::trim)
        .find(|line| line.chars().any(char::is_alphanumeric) && !before.contains(line))
        .map(|line| clip(line, MAX_SNIPPET))
        .unwrap_or_default()
}

/// FNV-1a of the text with its lines' trailing space trimmed, never 0.
fn hash(text: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for line in text.trim().lines() {
        for b in line.trim_end().bytes().chain(std::iter::once(b'\n')) {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    h.max(1)
}

/// The sentences of a reply, markdown marks and code fences left out.
fn sentences(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut fenced = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced {
            continue;
        }
        let line = line.trim_start_matches(['-', '*', '>', '#', ' ']).trim();
        let line = strip_number(line);
        let mut start = 0;
        let bytes = line.as_bytes();
        for (i, b) in bytes.iter().enumerate() {
            let ends = matches!(b, b'.' | b'?' | b'!')
                && bytes.get(i + 1).is_none_or(|next| next.is_ascii_whitespace());
            if ends {
                push_sentence(&mut out, line.get(start..=i).unwrap_or_default());
                start = i + 1;
            }
        }
        push_sentence(&mut out, line.get(start..).unwrap_or_default());
    }
    out
}

fn strip_number(line: &str) -> &str {
    let digits = line.bytes().take_while(u8::is_ascii_digit).count();
    match line.get(digits..) {
        Some(rest) if digits > 0 && (rest.starts_with(". ") || rest.starts_with(") ")) => {
            rest.get(2..).unwrap_or_default()
        }
        _ => line,
    }
}

fn push_sentence(out: &mut Vec<String>, s: &str) {
    let s = s.replace("**", "").replace('`', "");
    let s = s.trim();
    if s.chars().filter(|c| c.is_alphanumeric()).count() >= 8 {
        out.push(s.to_owned());
    }
}

/// `text` cut to at most `max` characters, control characters made spaces, an ellipsis when cut.
fn clip(text: &str, max: usize) -> String {
    let mut out: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(max)
        .collect();
    if text.chars().count() > max {
        out.push('…');
    }
    out
}

fn push_capped<T>(list: &mut Vec<T>, item: T, cap: usize) {
    list.push(item);
    if list.len() > cap {
        list.remove(0);
    }
}

#[cfg(test)]
#[path = "review_brief_tests.rs"]
mod tests;
