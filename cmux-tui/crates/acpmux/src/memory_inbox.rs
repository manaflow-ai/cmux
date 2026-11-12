//! The memory inbox: facts a chat learned about its project, offered as lines for the project's
//! instructions file (`CLAUDE.md`, `AGENTS.md`, the file `folder_instructions.rs` carries), so
//! agents stop repeating the same mistake and the person never edits a memory file by hand. Leo,
//! 2026-11-08: "go think of things/look at things, esp valuable things that people would think
//! \"wow this is awesome\"".
//!
//! - The agent proposes: its turn-ending `wrap_up` call (`acpmux_mcp_wrap_up.rs`) may carry
//!   `learned`, at most three one-line facts. No other model is asked, so it costs nothing past
//!   the turn itself, and nothing runs per token.
//! - Only a turn with a correction in it keeps them ([`Signals`]): the person's prompt corrected
//!   the agent ("no, use pnpm"), or a command failed and a later one worked. Facts from any other
//!   turn are dropped.
//! - What the file already says, what the person dismissed before in that folder, and repeats are
//!   left out ([`fresh`]). What is left is logged once, at the turn's end, as a `mux`
//!   `memory_offer` record the chat draws as a card with Accept and Dismiss (`hub/memory_inbox.rs`).
//! - Accept writes the lines under [`HEADING`] through a link-safe open in the chat folder
//!   ([`write`]); nothing is committed: the person sees the file change and commits it.

use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{LazyLock, Mutex};

/// The section accepted facts go under; added at the end of a file without it.
pub const HEADING: &str = "## Learned in chats";
/// The largest instructions file edited; a bigger one is left alone.
const MAX_FILE: u64 = 512 * 1024;
/// The most dismissed facts kept per folder.
const MAX_DISMISSED: usize = 200;

/// The facts a wrap-up's arguments carry: trimmed, one line each, at most three.
pub fn learned_facts(args: &Value) -> Vec<String> {
    let parsed;
    let args = match args {
        // Some harnesses pass the arguments as a JSON string.
        Value::String(s) => match serde_json::from_str::<Value>(s) {
            Ok(v) => {
                parsed = v;
                &parsed
            }
            Err(_) => return Vec::new(),
        },
        other => other,
    };
    let Some(list) = args.get("learned").and_then(Value::as_array) else { return Vec::new() };
    list.iter()
        .filter_map(Value::as_str)
        .map(clean_fact)
        .filter(|f| !f.is_empty())
        .take(crate::acpmux_mcp::WRAP_UP_MAX_LEARNED)
        .collect()
}

/// One line, with no list marker of its own, capped.
fn clean_fact(fact: &str) -> String {
    let line = fact.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let line = line.trim_start_matches(['-', '*', '•']).trim();
    line.chars().take(crate::acpmux_mcp::WRAP_UP_MAX_FACT).collect()
}

/// What makes a turn one that taught something: a correction from the person, or a command that
/// failed and a later one that worked.
#[derive(Debug, Default)]
pub struct Signals {
    /// The person's prompt this turn corrected the agent.
    corrected: bool,
    /// Shell calls still running, by tool call id.
    commands: HashSet<String>,
    /// A shell call failed this turn.
    failed: bool,
    /// A shell call worked after one failed.
    recovered: bool,
}

impl Signals {
    /// A person's prompt.
    pub fn prompt(&mut self, text: &str) {
        self.corrected |= is_correction(text);
    }

    /// A live `session/update` of the chat's own thread.
    pub fn observe(&mut self, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        if !matches!(kind, Some("tool_call" | "tool_call_update")) {
            return;
        }
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
        if update.get("kind").and_then(Value::as_str) == Some("execute") {
            self.commands.insert(id.to_owned());
        }
        if !self.commands.contains(id) {
            return;
        }
        let failed = match update.get("status").and_then(Value::as_str) {
            Some("failed") => true,
            Some("completed") => exit_code(update).is_some_and(|c| c != 0),
            _ => return,
        };
        self.commands.remove(id);
        if failed {
            self.failed = true;
        } else if self.failed {
            self.recovered = true;
        }
    }

    /// Whether the turn taught something.
    pub fn taught(&self) -> bool {
        self.corrected || self.recovered
    }
}

/// A finished command's exit code, where its harness reports one.
fn exit_code(update: &Value) -> Option<i64> {
    let out = update.get("rawOutput")?;
    ["exit_code", "exitCode", "code"].iter().find_map(|k| out.get(*k).and_then(Value::as_i64))
}

/// Whether the person's prompt corrects the agent: it opens with a no or a stop, or says to use,
/// keep or avoid something instead.
pub fn is_correction(text: &str) -> bool {
    let text: String = text.chars().take(600).collect::<String>().to_lowercase();
    let text = text.trim().replace('’', "'");
    let first: String = text.chars().take_while(|c| c.is_alphanumeric() || *c == '\'').collect();
    let rest = text.get(first.len()..).unwrap_or("").trim_start();
    let opener = match first.as_str() {
        // "no problem", "no thanks" and the like are not corrections.
        "no" => !["problem", "worries", "thanks", "thank", "rush", "need"]
            .iter()
            .any(|w| rest.starts_with(w)),
        "nope" | "wrong" | "stop" | "don't" | "dont" | "never" => true,
        "actually" => rest.starts_with(','),
        _ => false,
    };
    const PHRASES: &[&str] = &[
        "instead of",
        " instead",
        "don't use",
        "do not use",
        "dont use",
        "don't edit",
        "do not edit",
        "don't touch",
        "do not touch",
        "never edit",
        "never use",
        "always use",
        "that's wrong",
        "that is wrong",
        "that's not right",
        "that's not how",
        "you forgot",
        "you need to set",
        "you have to use",
        "you should use",
        "should have used",
        "not npm",
        "not yarn",
        "not pip",
    ];
    opener || PHRASES.iter().any(|p| text.contains(p)) || says_use_not(&text)
}

/// "use X, not Y" and "use X not Y".
fn says_use_not(text: &str) -> bool {
    let mut words = text.split_whitespace().peekable();
    while let Some(word) = words.next() {
        if word == "use" {
            // The word used, then "not" within the next three.
            if words.clone().skip(1).take(3).any(|w| w.trim_matches(',') == "not") {
                return true;
            }
        }
    }
    false
}

/// Words of a line, lower-cased, without punctuation or list markers: what two facts compare by.
fn words(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !(c.is_alphanumeric() || matches!(c, '_' | '/' | '.' | '-' | '*')))
        .map(|w| w.trim_matches(|c: char| matches!(c, '.' | '-' | '*')))
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Whether `a` and `b` say the same thing: the same words, or every word of the shorter one,
/// at least three, in the other ("Use pnpm, not npm." in "Use pnpm, not npm, in every
/// package."). One word apart ("port 4100" against "port 4200") is another fact.
fn same_fact(a: &[String], b: &[String]) -> bool {
    if a.is_empty() || b.is_empty() {
        return false;
    }
    if a == b {
        return true;
    }
    let (small, big) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    let big: HashSet<&String> = big.iter().collect();
    small.len() >= 3 && small.iter().all(|w| big.contains(w))
}

/// The facts not yet in `existing` (the file's text), not dismissed before (`dismissed`, each a
/// fact's [`key`]) and not repeated among themselves.
pub fn fresh(facts: &[String], existing: &str, dismissed: &[String]) -> Vec<String> {
    let lines: Vec<Vec<String>> = existing.lines().map(words).filter(|w| !w.is_empty()).collect();
    let mut kept: Vec<(String, Vec<String>)> = Vec::new();
    for fact in facts {
        let w = words(fact);
        if w.is_empty()
            || dismissed.iter().any(|d| *d == key(fact))
            || lines.iter().any(|l| same_fact(&w, l))
            || kept.iter().any(|(_, k)| same_fact(&w, k))
        {
            continue;
        }
        kept.push((fact.clone(), w));
    }
    kept.into_iter().map(|(f, _)| f).collect()
}

/// A fact's key in the dismissed list.
pub fn key(fact: &str) -> String {
    words(fact).join(" ")
}

/// `existing` with `facts` added as list lines at the end of its [`HEADING`] section, the
/// section made at the end of the file when it has none.
pub fn with_facts(existing: &str, facts: &[String]) -> String {
    let lines: Vec<&str> = existing.lines().collect();
    let bullets: Vec<String> = facts.iter().map(|f| format!("- {f}")).collect();
    let Some(start) = lines.iter().position(|l| l.trim() == HEADING) else {
        let mut out = existing.trim_end().to_owned();
        if !out.is_empty() {
            out.push_str("\n\n");
        }
        out.push_str(HEADING);
        out.push_str("\n\n");
        out.push_str(&bullets.join("\n"));
        out.push('\n');
        return out;
    };
    // The section ends at the next heading of its level or above.
    let body = start.saturating_add(1);
    let end = lines
        .iter()
        .enumerate()
        .skip(body)
        .find(|(_, l)| l.starts_with("# ") || l.starts_with("## "))
        .map_or(lines.len(), |(i, _)| i);
    // After its last non-blank line.
    let at = lines
        .iter()
        .enumerate()
        .take(end)
        .skip(body)
        .rev()
        .find(|(_, l)| !l.trim().is_empty())
        .map_or(body, |(i, _)| i.saturating_add(1));
    let mut out: Vec<String> = lines.iter().take(at).map(|l| (*l).to_owned()).collect();
    if at == body {
        out.push(String::new());
    }
    out.extend(bullets);
    if end < lines.len() {
        out.push(String::new());
        out.extend(lines.iter().skip(end).map(|l| (*l).to_owned()));
    }
    let mut text = out.join("\n");
    text.push('\n');
    text
}

/// Whether `existing` has the [`HEADING`] section already.
pub fn has_heading(existing: &str) -> bool {
    existing.lines().any(|l| l.trim() == HEADING)
}

/// The whole of `rel` in `cwd`, None when it is not there as a regular file; an error when it is
/// too big to edit or not text.
pub fn read(cwd: &Path, rel: &str) -> Result<Option<String>, String> {
    Ok(read_stamped(cwd, rel)?.map(|(text, _)| text))
}

/// [`read`] with what the file was when read.
fn read_stamped(
    cwd: &Path,
    rel: &str,
) -> Result<Option<(String, crate::folder_instructions::Stamp)>, String> {
    let Some((bytes, stamp)) = crate::folder_instructions::read_whole_beneath(cwd, rel, MAX_FILE)?
    else {
        return Ok(None);
    };
    let text = String::from_utf8(bytes).map_err(|_| format!("{rel} is not UTF-8 text"))?;
    Ok(Some((text, stamp)))
}

/// One write at a time: two Accepts read, merge and replace the file one after the other, so
/// neither loses the other's lines.
static WRITING: Mutex<()> = Mutex::new(());

/// Adds `facts` to `rel` in `cwd` (made when missing), skipping the ones it already says; the
/// ones added. The file is replaced whole or not at all, never through a link, and never
/// committed.
pub fn write(cwd: &Path, rel: &str, facts: &[String]) -> Result<Vec<String>, String> {
    let _one = WRITING.lock().unwrap_or_else(|e| e.into_inner());
    let read = read_stamped(cwd, rel)?;
    let stamp = read.as_ref().map(|(_, stamp)| *stamp);
    let existing = read.map(|(text, _)| text).unwrap_or_default();
    let added = fresh(facts, &existing, &[]);
    if added.is_empty() {
        return Ok(added);
    }
    let text = with_facts(&existing, &added);
    crate::folder_instructions::replace_beneath(cwd, rel, text.as_bytes(), stamp)?;
    Ok(added)
}

/// The dismissed facts of each folder, by [`key`]: `memory-dismissed.json` in acpmux's home.
pub struct Dismissed {
    path: std::path::PathBuf,
}

impl Dismissed {
    pub fn at(path: std::path::PathBuf) -> Self {
        Self { path }
    }

    fn load(&self) -> HashMap<String, Vec<String>> {
        std::fs::read(&self.path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    /// The keys dismissed in `cwd`.
    pub fn of(&self, cwd: &Path) -> Vec<String> {
        self.load().remove(&cwd.to_string_lossy().into_owned()).unwrap_or_default()
    }

    /// Remembers `facts` as dismissed in `cwd`, the newest [`MAX_DISMISSED`] kept.
    pub fn add(&self, cwd: &Path, facts: &[String]) {
        if facts.is_empty() {
            return;
        }
        let _one = WRITING.lock().unwrap_or_else(|e| e.into_inner());
        let mut all = self.load();
        let list = all.entry(cwd.to_string_lossy().into_owned()).or_default();
        for fact in facts {
            let k = key(fact);
            list.retain(|d| *d != k);
            list.push(k);
        }
        let over = list.len().saturating_sub(MAX_DISMISSED);
        list.drain(..over);
        if let Ok(bytes) = serde_json::to_vec(&all) {
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
    }
}

static SIGNALS: LazyLock<Mutex<HashMap<String, Signals>>> = LazyLock::new(Default::default);

/// [`Signals::prompt`] for `session`'s person prompt.
pub fn note_prompt(session: &str, text: &str) {
    SIGNALS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entry(session.to_owned())
        .or_default()
        .prompt(text);
}

/// [`Signals::observe`] for `session`.
pub fn observe(session: &str, update: &Value) {
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    if !matches!(kind, Some("tool_call" | "tool_call_update")) {
        return;
    }
    SIGNALS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entry(session.to_owned())
        .or_default()
        .observe(update);
}

/// Whether `session`'s turn taught something, and a clean slate for the next turn.
pub fn take(session: &str) -> bool {
    SIGNALS.lock().unwrap_or_else(|e| e.into_inner()).remove(session).is_some_and(|s| s.taught())
}

#[cfg(test)]
#[path = "memory_inbox_tests.rs"]
mod tests;
