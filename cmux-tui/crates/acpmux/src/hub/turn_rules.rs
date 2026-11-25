//! Part of `Hub`; see `hub/mod.rs`. Turn rules: what a session is told at the start and the end
//! of a turn, and when, from the person's own settings (`agents.turnRules`, an array, and the
//! optional file `turn-rules.json` beside the settings file, an array or `{"rules": [..]}`).
//!
//! Leo, 2026-11-24: "I feel like there are some times where like we can have conditional
//! injections at starts and ends of turns, like not only for chief but also for Claude. And
//! having that be a vector for determining, well, I mean directions that we want Claude or
//! Chief to be going in". Mirrors `tools/turn_rules.py` of leo-workspace.
//!
//! A rule is `{"id", "at": "start"|"end", "say", "if": {..}, "cooldown": turns}`. Its conditions
//! (all must hold; each `*_any` is a list of regexes, one matching is enough, a pattern that is
//! not a regex is a substring; all case-insensitive): `prompt_any`, `prompt_none`, `draft_any`,
//! `draft_none` (the turn's final message; end rules only), `tools_any`, `tools_none` (the
//! turn's tool calls: title and command; end rules only), `min_tools`, `min_prompt_chars`,
//! `session_any` (the session's name) and `host_any`. At most one rule fires per boundary, the
//! first in order that matches and is not cooling down (`cooldown`, in turns of that session,
//! default 6); none when none matches.
//!
//! A start rule is said in the outgoing prompt. An end rule never re-prompts the session: it is
//! said at the session's next prompt, with that prompt's start rule if one fires too.
//! (Re-entry, a per-rule opt-in in the prior art, is not built here.)
//!
//! Same path for every harness. On by default, nothing happens with no rules; off switch
//! `agents.harnessMagic.turnRules.enabled`, kill switch `ACPMUX_HM_TURNRULES=0`. Counters on the
//! `turn_result`: `harnessMagic.turnRules.fired` and `.suppressedByCooldown`. A firing is logged
//! with its rule id, boundary and session, never its text. Any error leaves the turn as vanilla.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use regex::RegexBuilder;
use serde_json::{Value, json};

use super::{Hub, Session};

pub(crate) const FEATURE: &str = "turnRules";
const DEFAULT_COOLDOWN: u64 = 6;
const MAX_RULES: usize = 200;
const MAX_TOOLS: usize = 300;
const MAX_TOOL_CHARS: usize = 300;
const MAX_SAY: usize = 4000;
const MAX_SESSIONS: usize = 4000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum At {
    Start,
    End,
}

#[derive(Clone, Debug, Default)]
struct Cond {
    prompt_any: Vec<String>,
    prompt_none: Vec<String>,
    draft_any: Vec<String>,
    draft_none: Vec<String>,
    tools_any: Vec<String>,
    tools_none: Vec<String>,
    session_any: Option<Vec<String>>,
    host_any: Option<Vec<String>>,
    min_tools: usize,
    min_prompt_chars: usize,
}

#[derive(Clone, Debug)]
pub(crate) struct Rule {
    id: String,
    at: At,
    say: String,
    cooldown: u64,
    cond: Cond,
}

/// What a rule is matched against.
#[derive(Default)]
pub(crate) struct Facts<'a> {
    pub prompt: &'a str,
    pub draft: &'a str,
    pub tools: &'a [String],
    pub session: &'a str,
    pub host: &'a str,
}

fn strings(v: Option<&Value>) -> Option<Vec<String>> {
    let v = v?;
    match v {
        Value::String(s) => Some(vec![s.clone()]),
        Value::Array(a) => Some(a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect()),
        _ => None,
    }
}

impl Rule {
    fn parse(v: &Value) -> Option<Rule> {
        let o = v.as_object()?;
        let id = o.get("id")?.as_str()?.trim().to_owned();
        let say: String = o.get("say")?.as_str()?.trim().chars().take(MAX_SAY).collect();
        if id.is_empty() || say.is_empty() || o.get("enabled") == Some(&Value::Bool(false)) {
            return None;
        }
        let at = match o.get("at")?.as_str()? {
            "start" => At::Start,
            "end" => At::End,
            _ => return None,
        };
        // Conditions sit under "if", or flat on the rule.
        let c = o.get("if").and_then(Value::as_object).unwrap_or(o);
        let list = |k: &str| strings(c.get(k)).unwrap_or_default();
        let num = |k: &str| c.get(k).and_then(Value::as_u64).unwrap_or(0) as usize;
        let cooldown = o
            .get("cooldown")
            .or_else(|| o.get("cooldown_turns"))
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_COOLDOWN);
        Some(Rule {
            id,
            at,
            say,
            cooldown,
            cond: Cond {
                prompt_any: list("prompt_any"),
                prompt_none: list("prompt_none"),
                draft_any: list("draft_any"),
                draft_none: list("draft_none"),
                tools_any: list("tools_any"),
                tools_none: list("tools_none"),
                session_any: strings(c.get("session_any")),
                host_any: strings(c.get("host_any")),
                min_tools: num("min_tools"),
                min_prompt_chars: num("min_prompt_chars"),
            },
        })
    }
}

/// The rules of an array, the invalid ones dropped.
fn parse_rules(v: &Value) -> Vec<Rule> {
    v.as_array()
        .map(|a| a.iter().take(MAX_RULES).filter_map(Rule::parse).collect())
        .unwrap_or_default()
}

fn pattern_hits(pattern: &str, text: &str) -> bool {
    match RegexBuilder::new(pattern).case_insensitive(true).size_limit(1 << 20).build() {
        Ok(re) => re.is_match(text),
        Err(_) => text.to_lowercase().contains(&pattern.to_lowercase()),
    }
}

fn any(patterns: &[String], text: &str) -> bool {
    patterns.iter().any(|p| pattern_hits(p, text))
}

fn matches(rule: &Rule, f: &Facts) -> bool {
    let c = &rule.cond;
    let tools = f.tools.join("\n");
    if (!c.prompt_any.is_empty() && !any(&c.prompt_any, f.prompt))
        || any(&c.prompt_none, f.prompt)
        || (!c.draft_any.is_empty() && !any(&c.draft_any, f.draft))
        || any(&c.draft_none, f.draft)
        || (!c.tools_any.is_empty() && !any(&c.tools_any, &tools))
        || any(&c.tools_none, &tools)
        || f.tools.len() < c.min_tools
        || f.prompt.chars().count() < c.min_prompt_chars
    {
        return false;
    }
    if let Some(s) = &c.session_any
        && !any(s, f.session)
    {
        return false;
    }
    if let Some(h) = &c.host_any
        && !any(h, f.host)
    {
        return false;
    }
    // A rule with no condition at all says its line at every boundary its cooldown allows.
    true
}

#[derive(Default)]
struct State {
    turn: u64,
    last_fired: HashMap<String, u64>,
    tools: Vec<String>,
    /// The end rule matched last, to be said at the next prompt: its id and words.
    pending_end: Option<(String, String)>,
    fired: u64,
    suppressed: u64,
}

static STATES: LazyLock<Mutex<HashMap<String, State>>> = LazyLock::new(Default::default);

#[cfg(test)]
static TEST_RULES: Mutex<Option<(String, Vec<Rule>)>> = Mutex::new(None);

/// The first rule of `at` that matches and is not cooling down; `suppressed` counts the matching
/// ones that were.
fn pick<'a>(rules: &'a [Rule], at: At, facts: &Facts, st: &mut State) -> Option<&'a Rule> {
    for rule in rules.iter().filter(|r| r.at == at) {
        if !matches(rule, facts) {
            continue;
        }
        let cooling = st
            .last_fired
            .get(&rule.id)
            .is_some_and(|last| st.turn.saturating_sub(*last) < rule.cooldown);
        if cooling {
            st.suppressed += 1;
            continue;
        }
        st.last_fired.insert(rule.id.clone(), st.turn);
        st.fired += 1;
        return Some(rule);
    }
    None
}

fn log_firing(rule_id: &str, at: &str, session: &str) {
    // The rule's id and boundary only, never its words.
    tracing::info!(target: "acpmux::turn_rules", rule = rule_id, at, session, "turn rule fired");
}

/// The rules now: the settings' array, then the file's. `None` when the feature is off or there
/// are none.
fn rules_now(key: &str) -> Option<Vec<Rule>> {
    // Tests only: rules for one session id, so no other test's turns see them.
    #[cfg(test)]
    if let Some((id, r)) = TEST_RULES.lock().unwrap_or_else(|e| e.into_inner()).clone()
        && id == key
    {
        return Some(r);
    }
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    if !super::harness_magic::enabled_in(FEATURE, doc.as_ref(), &|k| std::env::var(k).ok()) {
        return None;
    }
    let mut rules = doc
        .as_ref()
        .and_then(|d| crate::user_settings::value(d, "agents.turnRules"))
        .map(|v| parse_rules(&v))
        .unwrap_or_default();
    // Beside the settings file, so a DEV build (its own settings file) reads its own rules.
    if let Some(path) =
        crate::user_settings::resolved_path().parent().map(|d| d.join("turn-rules.json"))
        && let Ok(text) = std::fs::read_to_string(path)
        && let Ok(v) = serde_json::from_str::<Value>(&text)
    {
        let list = v.get("rules").unwrap_or(&v);
        rules.extend(parse_rules(list));
    }
    (!rules.is_empty()).then_some(rules)
}

fn host() -> &'static str {
    static HOST: LazyLock<String> = LazyLock::new(|| {
        std::fs::read_to_string("/proc/sys/kernel/hostname")
            .ok()
            .or_else(|| std::env::var("HOSTNAME").ok())
            .or_else(|| {
                std::process::Command::new("hostname")
                    .output()
                    .ok()
                    .and_then(|o| String::from_utf8(o.stdout).ok())
            })
            .unwrap_or_default()
            .trim()
            .to_owned()
    });
    &HOST
}

fn said(id: &str, say: &str) -> String {
    format!("[turn rule {id}] {say}")
}

/// A new turn of `session` with `prompt`: its start rule and the end rule it owes, said as one
/// text, `None` when there is nothing to say.
pub(crate) fn start_with(
    rules: &[Rule],
    key: &str,
    name: &str,
    prompt: &str,
    host: &str,
) -> Option<String> {
    let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
    if map.len() > MAX_SESSIONS && !map.contains_key(key) {
        map.clear();
    }
    let st = map.entry(key.to_owned()).or_default();
    st.turn += 1;
    st.tools.clear();
    let mut lines = Vec::new();
    if let Some((id, say)) = st.pending_end.take() {
        lines.push(said(&id, &say));
    }
    let tools = Vec::new();
    let facts = Facts { prompt, draft: "", tools: &tools, session: name, host };
    if let Some(rule) = pick(rules, At::Start, &facts, st) {
        log_firing(&rule.id, "start", key);
        lines.push(said(&rule.id, &rule.say));
    }
    (!lines.is_empty()).then(|| lines.join("\n"))
}

/// A tool call of the running turn of `key`.
pub(crate) fn note_tool(key: &str, update: &Value) {
    if update.get("sessionUpdate").and_then(Value::as_str) != Some("tool_call") {
        return;
    }
    let mut text = update.get("title").and_then(Value::as_str).unwrap_or("").to_owned();
    if let Some(cmd) = update.pointer("/rawInput/command") {
        let cmd = match cmd {
            Value::String(s) => s.clone(),
            Value::Array(a) => a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "),
            _ => String::new(),
        };
        text = format!("{text} {cmd}");
    }
    let text: String = text.trim().chars().take(MAX_TOOL_CHARS).collect();
    let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(st) = map.get_mut(key)
        && st.tools.len() < MAX_TOOLS
    {
        st.tools.push(text);
    }
}

/// The turn of `key` ends with `draft` as its final message: matches its end rule, if any, to be
/// said at the next prompt; puts the turn's counters on `msg`.
pub(crate) fn end_with(
    rules: &[Rule],
    key: &str,
    name: &str,
    prompt_hint: &str,
    draft: &str,
    host: &str,
    msg: &mut Value,
) {
    let mut map = STATES.lock().unwrap_or_else(|e| e.into_inner());
    let Some(st) = map.get_mut(key) else { return };
    let tools = std::mem::take(&mut st.tools);
    if !draft.is_empty() && st.pending_end.is_none() {
        let facts = Facts { prompt: prompt_hint, draft, tools: &tools, session: name, host };
        if let Some(rule) = pick(rules, At::End, &facts, st) {
            log_firing(&rule.id, "end", key);
            st.pending_end = Some((rule.id.clone(), rule.say.clone()));
        }
    }
    let (fired, suppressed) = (std::mem::take(&mut st.fired), std::mem::take(&mut st.suppressed));
    drop(map);
    for (counter, n) in [("fired", fired), ("suppressedByCooldown", suppressed)] {
        if n > 0 {
            super::harness_magic::add_counter(msg, FEATURE, counter, n);
        }
    }
}

impl Hub {
    /// The text to add to `session`'s outgoing prompt, if a rule says one.
    pub(super) fn turn_rules_start(&self, session: &Session, prompt: &str) -> Option<String> {
        let rules = rules_now(&session.id)?;
        start_with(&rules, &session.id, &session.meta().name, prompt, host())
    }

    /// A tool call of the running turn.
    pub(super) fn turn_rules_tool(&self, session: &Session, update: &Value) {
        note_tool(&session.id, update);
    }

    /// The turn's end, on its `turn_result`.
    pub(super) fn turn_rules_end(&self, session: &Session, msg: &mut Value) {
        let known = STATES.lock().unwrap_or_else(|e| e.into_inner()).contains_key(&session.id);
        if !known {
            return;
        }
        let draft = session.stream.lock().unwrap_or_else(|e| e.into_inner()).trailing_text.clone();
        let rules = rules_now(&session.id).unwrap_or_default();
        let completed = msg.get("status").and_then(Value::as_str) == Some("completed");
        let draft = if completed { draft.as_str() } else { "" };
        end_with(&rules, &session.id, &session.meta().name, "", draft, host(), msg);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules(v: Value) -> Vec<Rule> {
        parse_rules(&v)
    }

    fn start(r: &[Rule], key: &str, prompt: &str) -> Option<String> {
        start_with(r, key, "s", prompt, "h")
    }

    #[test]
    fn a_start_rule_fires_on_its_prompt_and_nothing_fires_otherwise() {
        let r = rules(json!([{"id": "a", "at": "start", "say": "check the cause",
            "if": {"prompt_any": ["fix(ed)? the bug"]}}]));
        assert_eq!(start(&r, "t1", "please do X"), None);
        assert_eq!(
            start(&r, "t1", "Fix the BUG now").as_deref(),
            Some("[turn rule a] check the cause")
        );
    }

    #[test]
    fn one_rule_per_boundary_and_a_cooldown_per_rule() {
        let r = rules(json!([
            {"id": "a", "at": "start", "say": "A", "cooldown": 2},
            {"id": "b", "at": "start", "say": "B", "cooldown": 0},
        ]));
        assert_eq!(start(&r, "t2", "p").as_deref(), Some("[turn rule a] A"));
        // a is cooling down (turn 2 - 1 < 2): b fires instead.
        assert_eq!(start(&r, "t2", "p").as_deref(), Some("[turn rule b] B"));
        assert_eq!(start(&r, "t2", "p").as_deref(), Some("[turn rule a] A"));
        let map = STATES.lock().unwrap();
        assert_eq!(map["t2"].suppressed, 1);
    }

    #[test]
    fn conditions_on_session_host_tools_and_draft() {
        let r = rules(json!([{"id": "e", "at": "end", "say": "E", "if": {
            "draft_any": ["\\bfixed\\b"], "draft_none": ["root cause"],
            "min_tools": 2, "tools_any": ["cargo"], "session_any": ["^lane"], "host_any": ["box"]}}]));
        let tools = vec!["Bash cargo test".to_owned(), "Edit".to_owned()];
        let f = |draft: &'static str, tools: &'static [String], session, host| Facts {
            prompt: "",
            draft,
            tools,
            session,
            host,
        };
        let tools: &'static [String] = Box::leak(tools.into_boxed_slice());
        assert!(matches(&r[0], &f("it is fixed", tools, "lane-1", "mybox")));
        assert!(!matches(&r[0], &f("it is fixed, root cause x", tools, "lane-1", "mybox")));
        assert!(!matches(&r[0], &f("it is fixed", &tools[..1], "lane-1", "mybox")));
        assert!(!matches(&r[0], &f("it is fixed", tools, "other", "mybox")));
        assert!(!matches(&r[0], &f("it is fixed", tools, "lane-1", "elsewhere")));
    }

    #[test]
    fn an_end_rule_is_said_at_the_next_prompt_not_now() {
        let r = rules(json!([{"id": "e", "at": "end", "say": "E", "if": {"draft_any": ["done"]}}]));
        assert_eq!(start(&r, "t3", "p"), None);
        let mut msg = json!({});
        end_with(&r, "t3", "s", "", "all done", "h", &mut msg);
        assert_eq!(msg["harnessMagic"]["turnRules"]["fired"], 1);
        assert_eq!(start(&r, "t3", "p").as_deref(), Some("[turn rule e] E"));
        assert_eq!(start(&r, "t3", "p"), None);
    }

    #[test]
    fn bad_rules_are_dropped_and_a_bad_regex_is_a_substring() {
        let r = rules(json!([{"id": "x", "at": "mid", "say": "s"}, {"say": "s", "at": "end"},
            {"id": "ok", "at": "start", "say": "s", "if": {"prompt_any": ["a(b"]}}]));
        assert_eq!(r.len(), 1);
        assert!(start(&r, "t4", "has a(b in it").is_some());
    }

    #[tokio::test]
    async fn a_hub_turn_end_matches_and_counts() {
        let cfg = crate::config::Config::default();
        let store = Box::new(crate::store::MemoryStore::default());
        let hub = Hub::new(cfg, store);
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "tr-hub", "name": "tr-hub",
            "harness": "fake", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        *TEST_RULES.lock().unwrap() = Some((
            "tr-hub".into(),
            rules(json!([
                {"id": "s", "at": "start", "say": "S", "cooldown": 0},
                {"id": "e", "at": "end", "say": "E", "if": {"draft_any": ["fixed"], "tools_any": ["cargo"]}},
            ])),
        ));
        let said = hub.turn_rules_start(&session, "go").unwrap();
        assert_eq!(said, "[turn rule s] S");
        hub.turn_rules_tool(
            &session,
            &json!({"sessionUpdate": "tool_call", "title": "Bash",
            "rawInput": {"command": "cargo test"}}),
        );
        session.stream.lock().unwrap().trailing_text = "It is fixed.".into();
        let mut msg = json!({"status": "completed"});
        hub.turn_rules_end(&session, &mut msg);
        assert_eq!(msg["harnessMagic"]["turnRules"]["fired"], 2);
        assert_eq!(
            hub.turn_rules_start(&session, "next").as_deref(),
            Some("[turn rule e] E\n[turn rule s] S")
        );
        *TEST_RULES.lock().unwrap() = None;
        hub.shutdown_all().await;
    }
}
