//! The hook host's rules and the pure half of answering one hook event: which rules an event
//! runs, and the one answer their outputs make. No I/O here; `hook_host/mod.rs` runs the commands.
//!
//! `<acpmux home>/hooks.json`:
//!
//! ```json
//! {
//!   "listen": "127.0.0.1:47620",
//!   "rules": [
//!     {"name": "heavy-work", "events": ["PreToolUse"], "tools": "Bash",
//!      "screen": "(?i)cargo|xcodebuild|pytest", "command": ["bash", "/path/heavy.sh"],
//!      "timeout_s": 5, "env": ["PATH", "CLAUDE_CODE_SESSION_ID"]},
//!     {"name": "checkpoint", "events": ["PostToolUse"], "command": "bash /path/wip.sh PostToolUse",
//!      "every_s": 300, "timeout_s": 3}
//!   ]
//! }
//! ```
//!
//! - `events`: the harness's hook event names the rule answers.
//! - `tools`: a matcher on the tool's name, as a Claude Code `matcher` is (a whole-name regex:
//!   `Bash`, `Bash|Monitor`, `mcp__.*`); unset is every tool, and every event without a tool.
//! - `screen`: a regex over the call ([`screen_text`]: the tool's input, or a prompt). The
//!   command starts only when it matches, so the cheap test a hook script makes on its payload
//!   before it does anything costs no process. Unset is always.
//! - `command`: an argv, or one string run by `sh -c`. It reads the payload on stdin and answers
//!   as a command hook does: JSON on stdout, or exit 2 with the reason on stderr.
//! - `timeout_s`: past it the event is answered without this rule; the command goes on unless
//!   `kill` is true, and is reaped.
//! - `env`: the caller's variables the command reads. The harness entry sends them as
//!   `X-Env-NAME` headers (`acpmux hook settings` writes them); the client sends its own.
//! - `every_s`: at most one run per session in that many seconds (a checkpoint, a heartbeat).

use regex::Regex;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// The rules' file in the acpmux home.
pub const FILE: &str = "hooks.json";
/// Where the host listens when the file names no address.
pub const DEFAULT_LISTEN: &str = "127.0.0.1:47620";
/// A rule's bound when it names none.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Deserialize)]
struct RawConfig {
    #[serde(default)]
    listen: Option<String>,
    #[serde(default)]
    rules: Vec<RawRule>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum RawCommand {
    Shell(String),
    Argv(Vec<String>),
}

#[derive(Deserialize)]
struct RawRule {
    name: String,
    events: Vec<String>,
    #[serde(default)]
    tools: Option<String>,
    #[serde(default)]
    screen: Option<String>,
    command: RawCommand,
    #[serde(default)]
    timeout_s: Option<f64>,
    #[serde(default)]
    env: Vec<String>,
    #[serde(default)]
    every_s: Option<u64>,
    #[serde(default)]
    kill: bool,
}

#[derive(Debug, Clone)]
pub struct Rule {
    pub name: String,
    pub events: Vec<String>,
    /// The `tools` matcher as written (`acpmux hook settings` joins them into the entry's).
    pub tools: Option<String>,
    tools_re: Option<Regex>,
    screen: Option<Regex>,
    pub argv: Vec<String>,
    pub timeout: Duration,
    pub env: Vec<String>,
    pub every: Option<Duration>,
    pub kill: bool,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub listen: String,
    pub rules: Vec<Rule>,
}

impl Config {
    /// The rules in `text`, or what is wrong with them (the rule's name first).
    pub fn parse(text: &str) -> Result<Config, String> {
        let raw: RawConfig = serde_json::from_str(text).map_err(|e| format!("{FILE}: {e}"))?;
        let mut rules = Vec::with_capacity(raw.rules.len());
        for r in raw.rules {
            let name = r.name.clone();
            let regex = |what: &str, src: &str, whole: bool| {
                let src = if whole { format!("^(?:{src})$") } else { src.to_owned() };
                Regex::new(&src).map_err(|e| format!("{FILE}: rule {name:?}: {what}: {e}"))
            };
            let tools_re = r.tools.as_deref().map(|t| regex("tools", t, true)).transpose()?;
            let screen = r.screen.as_deref().map(|s| regex("screen", s, false)).transpose()?;
            let argv = match r.command {
                RawCommand::Shell(s) => vec!["sh".to_owned(), "-c".to_owned(), s],
                RawCommand::Argv(a) => a,
            };
            if argv.first().is_none_or(String::is_empty) {
                return Err(format!("{FILE}: rule {name:?}: an empty command"));
            }
            if r.events.is_empty() {
                return Err(format!("{FILE}: rule {name:?}: no events"));
            }
            let timeout = match r.timeout_s {
                Some(s) if s.is_finite() && s > 0.0 => Duration::from_secs_f64(s.min(3600.0)),
                Some(_) => return Err(format!("{FILE}: rule {name:?}: timeout_s must be > 0")),
                None => DEFAULT_TIMEOUT,
            };
            rules.push(Rule {
                name: r.name,
                events: r.events,
                tools: r.tools,
                tools_re,
                screen,
                argv,
                timeout,
                env: r.env,
                every: r.every_s.filter(|s| *s > 0).map(Duration::from_secs),
                kill: r.kill,
            });
        }
        Ok(Config { listen: raw.listen.unwrap_or_else(|| DEFAULT_LISTEN.to_owned()), rules })
    }

    /// Every variable some rule reads, sorted, once each.
    pub fn env_names(&self) -> Vec<String> {
        let mut names: Vec<String> =
            self.rules.iter().flat_map(|r| r.env.iter().cloned()).collect();
        names.sort();
        names.dedup();
        names
    }

    /// The events some rule answers, in the order the rules first name them.
    pub fn events(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for e in self.rules.iter().flat_map(|r| r.events.iter()) {
            if !out.contains(e) {
                out.push(e.clone());
            }
        }
        out
    }

    /// The rules `event` names, in file order.
    pub fn for_event<'a>(&'a self, event: &'a str) -> impl Iterator<Item = &'a Rule> + 'a {
        self.rules.iter().filter(move |r| r.events.iter().any(|e| e == event))
    }

    /// The matcher a harness entry for `event` can carry: the rules' `tools` joined, or None
    /// when one of them answers every tool (the entry then sends every call).
    pub fn matcher(&self, event: &str) -> Option<String> {
        let mut parts: Vec<&str> = Vec::new();
        for r in self.for_event(event) {
            let t = r.tools.as_deref()?;
            if !parts.contains(&t) {
                parts.push(t);
            }
        }
        (!parts.is_empty()).then(|| parts.join("|"))
    }

    /// The longest bound of `event`'s rules.
    pub fn longest(&self, event: &str) -> Duration {
        self.for_event(event).map(|r| r.timeout).max().unwrap_or(DEFAULT_TIMEOUT)
    }
}

impl Rule {
    /// Whether this rule runs for `event` with `payload` (its throttle aside: [`Throttle`]).
    pub fn applies(&self, event: &str, payload: &Value) -> bool {
        if !self.events.iter().any(|e| e == event) {
            return false;
        }
        if let Some(re) = &self.tools_re {
            match payload.get("tool_name").and_then(Value::as_str) {
                Some(tool) if re.is_match(tool) => {}
                _ => return false,
            }
        }
        match &self.screen {
            Some(re) => re.is_match(&screen_text(payload)),
            None => true,
        }
    }
}

/// What a `screen` reads: the tool's input as JSON, else a prompt, else the whole payload. The
/// envelope around a call (its folder, transcript path, session and call ids) is never read, so
/// a word in a folder's name cannot start every command.
pub fn screen_text(payload: &Value) -> String {
    if let Some(input) = payload.get("tool_input") {
        return input.to_string();
    }
    if let Some(prompt) = payload.get("prompt").and_then(Value::as_str) {
        return prompt.to_owned();
    }
    payload.to_string()
}

/// `every_s`: the last run of each (rule, session).
#[derive(Default)]
pub struct Throttle {
    last: HashMap<(String, String), Instant>,
}

impl Throttle {
    /// Whether `rule` may run for `session` at `now`; a yes is recorded as its run.
    pub fn take(&mut self, rule: &Rule, session: &str, now: Instant) -> bool {
        let Some(every) = rule.every else { return true };
        let key = (rule.name.clone(), session.to_owned());
        if let Some(at) = self.last.get(&key)
            && now.saturating_duration_since(*at) < every
        {
            return false;
        }
        // Bounded: a long-lived host forgets runs older than an hour once it holds many.
        if self.last.len() > 4096 {
            self.last
                .retain(|_, at| now.saturating_duration_since(*at) < Duration::from_secs(3600));
        }
        self.last.insert(key, now);
        true
    }
}

/// One command's run: its exit code (None: still running at its bound), stdout, stderr.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Ran {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// The one answer the runs make, as the harness read them when each was its own hook entry:
/// the first refusal (a deny, a `decision: block`, `continue: false`, or an exit 2) is the
/// answer, with every context before it joined to its own; otherwise the first of each other
/// field, and every context joined. An exit other than 0 or 2, or a run past its bound, adds
/// nothing. Plain stdout is context on the events whose command hooks take it so.
pub fn answer(event: &str, runs: &[Ran]) -> Value {
    let mut merged = Map::new();
    let mut special = Map::new();
    let mut contexts: Vec<String> = Vec::new();
    let mut messages: Vec<String> = Vec::new();
    for run in runs {
        let mut out = match run.code {
            Some(2) => refusal(event, run.stderr.trim()),
            Some(0) => match serde_json::from_str::<Value>(run.stdout.trim()) {
                Ok(Value::Object(o)) => o,
                _ => {
                    let text = run.stdout.trim();
                    if !text.is_empty() && matches!(event, "UserPromptSubmit" | "SessionStart") {
                        contexts.push(text.to_owned());
                    }
                    continue;
                }
            },
            _ => continue,
        };
        let refused = out.get("decision").and_then(Value::as_str) == Some("block")
            || out.get("continue") == Some(&Value::Bool(false))
            || out
                .get("hookSpecificOutput")
                .and_then(|h| h.get("permissionDecision"))
                .and_then(Value::as_str)
                == Some("deny");
        if let Some(Value::Object(hso)) = out.remove("hookSpecificOutput") {
            for (k, v) in hso {
                match (k.as_str(), v) {
                    ("additionalContext", Value::String(s)) if !s.is_empty() => contexts.push(s),
                    ("additionalContext", _) | ("hookEventName", _) => {}
                    (_, v) if refused => {
                        special.insert(k, v);
                    }
                    (_, v) => {
                        special.entry(k).or_insert(v);
                    }
                }
            }
        }
        if let Some(Value::String(s)) = out.remove("systemMessage")
            && !s.is_empty()
        {
            messages.push(s);
        }
        if refused {
            merged.extend(out);
            break;
        }
        for (k, v) in out {
            merged.entry(k).or_insert(v);
        }
    }
    if !contexts.is_empty() {
        special.insert("additionalContext".into(), Value::String(contexts.join("\n\n")));
    }
    if !special.is_empty() {
        special.insert("hookEventName".into(), Value::String(event.to_owned()));
        merged.insert("hookSpecificOutput".into(), Value::Object(special));
    }
    if !messages.is_empty() {
        merged.insert("systemMessage".into(), Value::String(messages.join("\n")));
    }
    Value::Object(merged)
}

/// An exit 2's answer for `event`: a deny before a tool call, a block anywhere else.
fn refusal(event: &str, reason: &str) -> Map<String, Value> {
    let reason = if reason.is_empty() { "refused by a hook" } else { reason };
    let v = if event == "PreToolUse" {
        json!({"hookSpecificOutput": {"hookEventName": event, "permissionDecision": "deny",
                                      "permissionDecisionReason": reason}})
    } else {
        json!({"decision": "block", "reason": reason})
    };
    match v {
        Value::Object(o) => o,
        _ => Map::new(),
    }
}

#[cfg(test)]
#[path = "rules_tests.rs"]
mod tests;
