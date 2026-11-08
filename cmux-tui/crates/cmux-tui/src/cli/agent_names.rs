//! Agent names and unique tab names as selectors.
//!
//! `cmux agent start alpha` runs the agent in a tab named `alpha`. That tab
//! name is the agent's name: `cmux terminal alpha send …`, `cmux tab alpha
//! focus`, `cmux pane alpha split` and `--terminal alpha` (or `--tab`,
//! `--pane`) take it wherever a terminal, tab or pane selector goes. Any
//! other tab name that is unique in the session works the same way.
//!
//! Before the CLI parses a command, [`rewrite_args`] looks a selector word
//! that is not an id, `current`/`caller`/`focused` or a command word up in
//! one `session.snapshot` and puts the matching id in its place:
//!
//! 1. a tab with that name whose terminal runs and has an agent;
//! 2. else a tab with that name whose terminal runs;
//! 3. else a tab with that name whose terminal exited (kept by
//!    `--on-exit keep`, so `terminal alpha resume` finds it).
//!
//! The first step with exactly one tab wins; two or more there is
//! `selector.ambiguous` with the tab ids. No match leaves the word to the
//! daemon's own name rules (terminal titles, names under a parent), so a
//! command that worked before works the same. A pane selector is not
//! rewritten when a pane has that name itself.

use std::collections::HashMap;

use serde_json::{Value, json};

use super::terminal_talk::send;

/// Agent name grammar: a lowercase letter, then up to 31 lowercase letters,
/// digits, `-` or `_`.
const MAX_NAME_CHARS: usize = 32;

/// Public id prefixes (`term_…`): a word with one is an id or an id prefix,
/// never a name.
const ID_PREFIXES: &[&str] = &[
    "machine",
    "session",
    "ws",
    "screen",
    "pane",
    "tab",
    "term",
    "browser",
    "client",
    "split",
    "stream",
    "notification",
    "agent",
    "projection",
    "pairing",
    "sidebar",
];

/// Selector keywords that already mean an object.
const KEYWORDS: &[&str] = &["current", "caller", "focused", "all", "help"];

/// Why `name` cannot name an agent; `Ok` when it can.
pub(in crate::cli) fn valid_agent_name(name: &str) -> Result<(), String> {
    let mut chars = name.chars();
    let first_ok = chars.next().is_some_and(|first| first.is_ascii_lowercase());
    let rest_ok = chars.all(|character| {
        character.is_ascii_lowercase()
            || character.is_ascii_digit()
            || character == '-'
            || character == '_'
    });
    if !first_ok || !rest_ok || name.chars().count() > MAX_NAME_CHARS {
        return Err(format!(
            "an agent name is a lowercase letter, then up to 31 lowercase letters, digits, - or \
             _ (like alpha or fix-tests-2), not {name:?}"
        ));
    }
    if KEYWORDS.contains(&name)
        || matches!(name, "start" | "resume")
        || cmux_tui_core::resource::is_reserved_selector_token(name)
    {
        return Err(format!("{name:?} is a cmux command word; choose another agent name"));
    }
    if looks_like_id(name) {
        return Err(format!("{name:?} looks like a cmux id; choose another agent name"));
    }
    Ok(())
}

fn looks_like_id(word: &str) -> bool {
    word.split_once('_').is_some_and(|(prefix, _)| ID_PREFIXES.contains(&prefix))
}

/// Where a named agent (or tab) is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Place {
    pub terminal: String,
    pub tab: String,
    pub pane: String,
    /// The terminal has not exited.
    pub live: bool,
    /// An agent record or program status runs in the terminal.
    pub agent: bool,
}

/// What a name selects.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Found {
    One(Place),
    /// Two or more tabs at the first step that has any: their tab ids.
    Ambiguous(Vec<String>),
    Missing,
}

fn list<'a>(snapshot: &'a Value, key: &str) -> &'a [Value] {
    snapshot[key].as_array().map(Vec::as_slice).unwrap_or_default()
}

/// Whether the daemon's records say an agent runs in `terminal` (a hook or
/// plugin record that is not `done`, or an OSC 7501 program status).
fn runs_agent(terminal: &Value, agents: &[Value]) -> bool {
    let id = &terminal["id"];
    let recorded = agents.iter().filter(|agent| &agent["terminal_id"] == id).max_by_key(|agent| {
        agent["updated_at_ms"]
            .as_u64()
            .or_else(|| agent["updated_at_ms"].as_str().and_then(|text| text.parse().ok()))
            .unwrap_or(0)
    });
    match recorded {
        Some(record) => record["state"] != "done",
        None => terminal["extra"]["program_status"]
            .as_array()
            .is_some_and(|records| records.iter().any(|record| record["app"].is_string())),
    }
}

/// Every tab named `name` that shows a terminal of the snapshot.
pub(in crate::cli) fn places_named(snapshot: &Value, name: &str) -> Vec<Place> {
    let terminals: HashMap<&str, &Value> = list(snapshot, "terminals")
        .iter()
        .filter_map(|terminal| Some((terminal["id"].as_str()?, terminal)))
        .collect();
    let agents = list(snapshot, "agents");
    list(snapshot, "tabs")
        .iter()
        .filter(|tab| tab["name"] == name)
        .filter_map(|tab| {
            let terminal = *terminals.get(tab["content_id"].as_str()?)?;
            Some(Place {
                terminal: terminal["id"].as_str()?.to_owned(),
                tab: tab["id"].as_str()?.to_owned(),
                pane: tab["pane_id"].as_str()?.to_owned(),
                live: terminal["lifecycle"] != "exited",
                agent: runs_agent(terminal, agents),
            })
        })
        .collect()
}

/// The tab `name` selects (a leading `name:` is dropped).
pub(in crate::cli) fn resolve(snapshot: &Value, name: &str) -> Found {
    let name = name.strip_prefix("name:").unwrap_or(name);
    if name.is_empty() {
        return Found::Missing;
    }
    let places = places_named(snapshot, name);
    let steps: [fn(&Place) -> bool; 3] = [
        |place: &Place| place.live && place.agent,
        |place: &Place| place.live,
        |place: &Place| !place.live,
    ];
    for step in steps {
        let picked: Vec<&Place> = places.iter().filter(|place| step(place)).collect();
        match picked.as_slice() {
            [] => {}
            [one] => return Found::One((*one).clone()),
            many => return Found::Ambiguous(many.iter().map(|place| place.tab.clone()).collect()),
        }
    }
    Found::Missing
}

/// Which id a selector word becomes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Scope {
    Terminal,
    Tab,
    Pane,
}

impl Scope {
    fn of(word: &str) -> Option<Self> {
        Some(match super::canonical_scope(word) {
            "terminal" => Self::Terminal,
            "tab" => Self::Tab,
            "pane" => Self::Pane,
            _ => return None,
        })
    }

    fn id(self, place: &Place) -> &str {
        match self {
            Self::Terminal => &place.terminal,
            Self::Tab => &place.tab,
            Self::Pane => &place.pane,
        }
    }
}

/// One selector word that may be a name: the command word after the scope,
/// or the value of a `--terminal`, `--tab` or `--pane` flag.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Target {
    pub scope: Scope,
    pub word: String,
    /// `Some("--tab")` for a flag value, `None` for the positional selector.
    pub flag: Option<&'static str>,
}

/// The word as a name to look up; `None` for an id, an id prefix, a
/// keyword or a command word.
fn candidate(word: &str) -> Option<&str> {
    if let Some(name) = word.strip_prefix("name:") {
        return (!name.is_empty()).then_some(name);
    }
    if word.is_empty()
        || word.starts_with('-')
        || KEYWORDS.contains(&word)
        || cmux_tui_core::resource::is_reserved_selector_token(word)
        || looks_like_id(word)
    {
        return None;
    }
    Some(word)
}

/// The scopes whose `--terminal`, `--tab` and `--pane` flags name a place.
const FLAG_SCOPES: &[&str] = &["terminal", "tab", "pane", "agent", "notification"];

/// The selector words of `words` (the command after the global options)
/// that may be names.
pub(in crate::cli) fn targets(words: &[String]) -> Vec<Target> {
    let Some(first) = words.first() else { return Vec::new() };
    let scope = super::canonical_scope(first);
    if scope == "agent" && words.get(1).is_some_and(|verb| verb == "start" || verb == "resume") {
        return Vec::new();
    }
    let mut found = Vec::new();
    // The words before the first flag, read as the parser reads them: a
    // shorthand (`tab new terminal`, `tab rename`) names no selector.
    let mut head: Vec<String> =
        words.iter().take_while(|word| !word.starts_with('-')).cloned().collect();
    let given = head.get(1).cloned();
    super::shorthand::normalize_words(&mut head);
    if let (Some(scope), Some(word), Some(_verb)) = (Scope::of(first), head.get(1), head.get(2))
        && given.as_ref() == Some(word)
        && !(scope == Scope::Tab && word == "new")
        && candidate(word).is_some()
    {
        found.push(Target { scope, word: word.clone(), flag: None });
    }
    if !FLAG_SCOPES.contains(&scope) {
        return found;
    }
    let mut rest = words.iter().skip(1).take_while(|word| word.as_str() != "--");
    while let Some(word) = rest.next() {
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (word.as_str(), None),
        };
        let (flag, scope) = match name {
            "--terminal" => ("--terminal", Scope::Terminal),
            "--tab" => ("--tab", Scope::Tab),
            "--pane" => ("--pane", Scope::Pane),
            _ => continue,
        };
        let Some(value) = inline.or_else(|| rest.next().cloned()) else { break };
        if candidate(&value).is_some() {
            found.push(Target { scope, word: value, flag: Some(flag) });
        }
    }
    found
}

/// Puts `id` in place of `target`'s word in the full `args`; false when the
/// word is not found there.
pub(in crate::cli) fn replace(args: &mut [String], target: &Target, id: &str) -> bool {
    let end = args.iter().position(|word| word == "--").unwrap_or(args.len());
    match target.flag {
        None => {
            let scope = args[..end].iter().position(|word| Scope::of(word).is_some());
            let Some(scope) = scope else { return false };
            let Some(offset) = args[scope + 1..end].iter().position(|word| *word == target.word)
            else {
                return false;
            };
            args[scope + 1 + offset] = id.to_owned();
            true
        }
        Some(flag) => {
            for index in 0..end {
                if args[index] == flag && args.get(index + 1) == Some(&target.word) {
                    args[index + 1] = id.to_owned();
                    return true;
                }
                if args[index] == format!("{flag}={}", target.word) {
                    args[index] = format!("{flag}={id}");
                    return true;
                }
            }
            false
        }
    }
}

/// The id each target selects in `snapshot`: `Ok(None)` for a word that
/// stays as it is, `Err` with the error for an ambiguous name.
pub(in crate::cli) fn lookup(snapshot: &Value, target: &Target) -> Result<Option<String>, Value> {
    let Some(name) = candidate(&target.word) else { return Ok(None) };
    if target.scope == Scope::Pane
        && list(snapshot, "panes").iter().any(|pane| pane["name"] == name)
    {
        return Ok(None);
    }
    match resolve(snapshot, name) {
        Found::One(place) => Ok(Some(target.scope.id(&place).to_owned())),
        Found::Missing => Ok(None),
        Found::Ambiguous(tabs) => Err(json!({
            "code": "selector.ambiguous",
            "message": format!(
                "{} tabs are named {name:?}; name one by its id ({})",
                tabs.len(),
                tabs.join(", ")
            ),
            "details": {"name": name, "candidates": tabs},
            "retryable": false,
        })),
    }
}

/// `args` with each agent or unique tab name replaced by its id;
/// `Ok(None)` when nothing changed (or the session could not be read),
/// `Err(exit code)` after printing an ambiguous-name error.
pub(in crate::cli) fn rewrite_args(args: &[String]) -> Result<Option<Vec<String>>, i32> {
    let Ok((global, words)) = super::parse_globals(args) else { return Ok(None) };
    if global.all_sessions || super::has_help_option(&words) {
        return Ok(None);
    }
    let targets = targets(&words);
    if targets.is_empty() {
        return Ok(None);
    }
    let backend = super::mcp::cli_backend(global.clone());
    let Ok(snapshot) = send::snapshot(&backend, None) else { return Ok(None) };
    let mut rewritten = args.to_vec();
    let mut changed = false;
    for target in &targets {
        match lookup(&snapshot, target) {
            Ok(Some(id)) => changed |= replace(&mut rewritten, target, &id),
            Ok(None) => {}
            Err(error) => return Err(super::wire::print_local_error(&error, global.output, 1)),
        }
    }
    Ok(changed.then_some(rewritten))
}

#[cfg(test)]
#[path = "agent_names/tests.rs"]
mod tests;
