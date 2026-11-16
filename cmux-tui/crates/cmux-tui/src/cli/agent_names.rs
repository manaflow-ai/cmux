//! Agent names and unique tab names as selectors.
//!
//! `cmux agent start alpha` runs the agent in a tab named `alpha`. That tab
//! name is the agent's name: `cmux terminal alpha send …`, `cmux tab alpha
//! focus`, `cmux pane alpha split` and `--terminal alpha` (or `--tab`,
//! `--pane`) take it wherever a terminal, tab or pane selector goes. Any
//! other tab name that is unique in the session works the same way.
//!
//! Before the CLI parses a command, [`rewrite_args`] asks the daemon to
//! resolve each selector word that is not an id, `current`/`caller`/`focused`
//! or a command word (also a subcommand word of the parser, like `group` in
//! `tab group list`), as `<scope> <word> show` from the caller, and puts the
//! id it answers in place of the word. The daemon has the one selector
//! resolver (W5-P, `resource_selector` in cmux-tui-core): the current scope
//! first, then a terminal title or pane name, then a tab name in the whole
//! session, a tab whose terminal runs before one whose terminal exited (kept
//! by `--on-exit keep`, so `terminal alpha resume` finds it). Two or more at
//! one step are `selector.ambiguous` with the tab ids. So `--terminal alpha`
//! gives the full `term_` id that `notification create` and `agent report`
//! need, and it is the object `terminal alpha …` selects.
//!
//! [`resolve`] is the same tab-name rule over a `session.snapshot`, for the
//! commands that already read one (`agent start --pane`, `agent resume`,
//! `terminal … send`).

use std::collections::HashMap;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::Value;

use super::command::WireOperation;

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
        || [Scope::Terminal, Scope::Tab, Scope::Pane]
            .into_iter()
            .any(|scope| is_subcommand(scope, name))
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

/// Every tab named `name` that shows a terminal of the snapshot.
pub(in crate::cli) fn places_named(snapshot: &Value, name: &str) -> Vec<Place> {
    let terminals: HashMap<&str, &Value> = list(snapshot, "terminals")
        .iter()
        .filter_map(|terminal| Some((terminal["id"].as_str()?, terminal)))
        .collect();
    list(snapshot, "tabs")
        .iter()
        .filter(|tab| tab["name"] == name)
        .filter_map(|tab| {
            let terminal = *terminals.get(tab["content_id"].as_str()?)?;
            Some(Place {
                terminal: terminal["id"].as_str()?.to_owned(),
                tab: tab["id"].as_str()?.to_owned(),
                pane: tab["pane_id"].as_str()?.to_owned(),
                live: super::terminal_lifecycle::is_live(terminal),
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
    // Live tabs first, then exited ones (resume). Two live tabs with the name
    // are ambiguous even when one runs an agent: the daemon's tab-name scope
    // does not prefer it either, so every selector picks the same object.
    let steps: [fn(&Place) -> bool; 2] = [|place: &Place| place.live, |place: &Place| !place.live];
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

    /// The scope word of the CLI grammar.
    fn word(self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::Tab => "tab",
            Self::Pane => "pane",
        }
    }

    /// The get operation of the scope.
    fn get(self) -> ResourceOperation {
        match self {
            Self::Terminal => ResourceOperation::TerminalGet,
            Self::Tab => ResourceOperation::TabGet,
            Self::Pane => ResourceOperation::PaneGet,
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
    /// Where the word is in the command words.
    pub index: usize,
    /// The value is in the flag's own word (`--tab=alpha`).
    pub inline: bool,
}

/// The word as a selector to resolve; `None` for a full id, a keyword or a
/// command word. A unique id prefix (`term_3f0a`) and a bare or host id are
/// resolved too, so a flag that needs the full id gets it.
fn candidate(word: &str) -> Option<&str> {
    if let Some(name) = word.strip_prefix("name:") {
        return (!name.is_empty()).then_some(name);
    }
    if word.is_empty()
        || word.starts_with('-')
        || KEYWORDS.contains(&word)
        || cmux_tui_core::resource::is_reserved_selector_token(word)
        || (looks_like_id(word) && cmux_tui_core::resource::id_prefix_parts(word).is_none())
    {
        return None;
    }
    Some(word)
}

/// Whether the parser reads `word` after `scope` as a subcommand word
/// (`tab group list`), not as a selector: it does not read
/// `<scope> <word> show` as a get of `word`. A word with `_` is never a
/// subcommand word (the parser's words use `-`).
fn is_subcommand(scope: Scope, word: &str) -> bool {
    if word.contains('_') {
        return false;
    }
    let words = [scope.word().to_owned(), word.to_owned(), "show".to_owned()];
    !matches!(
        super::command::parse(&words, super::Surface::current()),
        Ok(super::command::CommandPlan::Protocol(plan))
            if matches!(&plan.operation, WireOperation::Typed(operation) if *operation == scope.get())
    )
}

/// The scopes whose `--terminal`, `--tab` and `--pane` flags name a place.
const FLAG_SCOPES: &[&str] = &["terminal", "tab", "pane", "agent", "notification"];

/// The selector words of `words` (the command after the global options)
/// that may be names. The words are read as the parser reads them: every
/// flag that is not a boolean flag takes the next word as its value, and
/// nothing after `--` is read.
pub(in crate::cli) fn targets(words: &[String]) -> Vec<Target> {
    let Some(first) = words.first() else { return Vec::new() };
    let scope = super::canonical_scope(first);
    if scope == "agent" && words.get(1).is_some_and(|verb| verb == "start" || verb == "resume") {
        return Vec::new();
    }
    let mut positional: Vec<(usize, String)> = Vec::new();
    let mut flagged = Vec::new();
    let mut scan = words.iter().enumerate().take_while(|(_, word)| *word != "--");
    while let Some((index, word)) = scan.next() {
        let Some(flag) = word.strip_prefix("--") else {
            positional.push((index, word.clone()));
            continue;
        };
        let (name, inline) = match flag.split_once('=') {
            Some((name, value)) => (name, Some(value)),
            None => (flag, None),
        };
        if inline.is_none()
            && super::command::flag_takes_no_value(name, words.get(index + 1).map(String::as_str))
        {
            continue;
        }
        let (value_index, value) = match inline {
            Some(value) => (index, value.to_owned()),
            None => match scan.next() {
                Some((at, value)) => (at, value.clone()),
                None => break,
            },
        };
        let named = match name {
            "terminal" => Some(("--terminal", Scope::Terminal)),
            "tab" => Some(("--tab", Scope::Tab)),
            "pane" => Some(("--pane", Scope::Pane)),
            _ => None,
        };
        if let Some((flag, scope)) = named
            && candidate(&value).is_some()
        {
            let inline = inline.is_some();
            flagged.push(Target {
                scope,
                word: value,
                flag: Some(flag),
                index: value_index,
                inline,
            });
        }
    }
    let mut found = Vec::new();
    // A shorthand (`tab new terminal`, `tab rename`) names no selector.
    let mut head: Vec<String> = positional.iter().map(|(_, word)| word.clone()).collect();
    let given = head.get(1).cloned();
    super::shorthand::normalize_words(&mut head);
    if let (Some(scope), Some(word), Some(_verb), Some((index, _))) =
        (Scope::of(first), head.get(1), head.get(2), positional.get(1))
        && given.as_ref() == Some(word)
        && !(scope == Scope::Tab && word == "new")
        && candidate(word).is_some()
        && !is_subcommand(scope, word)
    {
        found.push(Target { scope, word: word.clone(), flag: None, index: *index, inline: false });
    }
    if FLAG_SCOPES.contains(&scope) {
        found.extend(flagged);
    }
    found
}

/// Puts `id` in place of `target`'s word in the command `words`.
pub(in crate::cli) fn replace(words: &mut [String], target: &Target, id: &str) {
    let Some(word) = words.get_mut(target.index) else { return };
    *word = match target.flag {
        Some(flag) if target.inline => format!("{flag}={id}"),
        _ => id.to_owned(),
    };
}

/// The command `words` with each target's word replaced by the id that
/// `resolve` gives for it; `Ok(None)` when nothing changes. `resolve` is the
/// daemon's one selector resolver (W5-P): `Ok(Some(id))` for the object the
/// word selects, `Ok(None)` for a word that stays as it is (not found, or
/// no answer), `Err` with the daemon's error (`selector.ambiguous`).
pub(in crate::cli) fn rewrite_words(
    words: &[String],
    resolve: &mut dyn FnMut(&Target) -> Result<Option<String>, Value>,
) -> Result<Option<Vec<String>>, Value> {
    let mut rewritten = words.to_vec();
    let mut changed = false;
    for target in targets(words) {
        let Some(id) = resolve(&target)? else { continue };
        if id != target.word {
            replace(&mut rewritten, &target, &id);
            changed = true;
        }
    }
    Ok(changed.then_some(rewritten))
}

/// The id the daemon resolves `target`'s word to, read as
/// `<scope> <word> show` from this caller: the same rules as every other
/// command (W5-P's one resolver), so `terminal alpha`, `--terminal alpha`
/// and `notification create --terminal alpha` select one object. Only
/// `selector.ambiguous` is an error; any other failure, or no answer, keeps
/// the word (the command then reports its own error).
fn daemon_resolves(global: &super::GlobalArgs, target: &Target) -> Result<Option<String>, Value> {
    use super::resolve::{self, Failure, SocketRoute};
    let words = [target.scope.word().to_owned(), target.word.clone(), "show".to_owned()];
    let Ok(super::command::CommandPlan::Protocol(plan)) =
        super::command::parse(&words, super::Surface::current())
    else {
        return Ok(None);
    };
    let mut plan = *plan;
    if resolve::apply_global_route(global, &mut plan).is_err() {
        return Ok(None);
    }
    let Ok((socket, derived)) = super::wire::resolve_socket_with_origin(global) else {
        return Ok(None);
    };
    let Ok(stream) = cmux_tui_core::server::connect_session_socket(&socket, derived) else {
        return Ok(None);
    };
    let _ = stream.set_read_timeout(Some(PROBE_TIMEOUT));
    let mut reader = std::io::BufReader::new(stream);
    let route = SocketRoute::new(&socket, derived, global);
    let caller_route = super::wire::routes_to_caller_session(global);
    let found = resolve::apply(&mut reader, &mut plan, caller_route, &route).and_then(|()| {
        let params = plan.params.as_object().cloned().unwrap_or_default();
        resolve::read(&mut reader, target.scope.get(), params)
    });
    match found {
        Ok(object) => Ok(object.get("id").and_then(Value::as_str).map(str::to_owned)),
        Err(Failure::Resource(error))
            if error.get("code").is_some_and(|code| code == "selector.ambiguous") =>
        {
            Err(error)
        }
        Err(_) => Ok(None),
    }
}

/// How long the selector probe waits for the daemon.
// timeout: each read of the probe; a daemon that does not answer leaves the args as typed.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// `args` with each selector word that may be a name replaced by the id the
/// daemon resolves it to; `Ok(None)` when nothing changed (or the session
/// could not be read), `Err(exit code)` after printing an ambiguous-name
/// error.
pub(in crate::cli) fn rewrite_args(args: &[String]) -> Result<Option<Vec<String>>, i32> {
    let Ok((global, words)) = super::parse_globals(args) else { return Ok(None) };
    if global.all_sessions || super::has_help_option(&words) || targets(&words).is_empty() {
        return Ok(None);
    }
    let mut resolve = |target: &Target| daemon_resolves(&global, target);
    let rewritten = match rewrite_words(&words, &mut resolve) {
        Ok(Some(rewritten)) => rewritten,
        Ok(None) => return Ok(None),
        Err(error) => return Err(super::wire::print_local_error(&error, global.output, 1)),
    };
    Ok(args_with_words(args, &words, &rewritten))
}

/// `args` with its command words changed from `words` to `rewritten` (the
/// same length): each changed word is put at the position of `args` where
/// the global options then still give `rewritten`. `None` when no position
/// does, so a global option's value is never changed.
pub(in crate::cli) fn args_with_words(
    args: &[String],
    words: &[String],
    rewritten: &[String],
) -> Option<Vec<String>> {
    let mut result = args.to_vec();
    let mut expected = words.to_vec();
    let changes = words.iter().zip(rewritten).enumerate().filter(|(_, (old, new))| old != new);
    for (index, (old, new)) in changes {
        if let Some(slot) = expected.get_mut(index) {
            slot.clone_from(new);
        }
        let end = result.iter().position(|word| word == "--").unwrap_or(result.len());
        let position = result
            .iter()
            .take(end)
            .enumerate()
            .filter(|(_, word)| *word == old)
            .map(|(at, _)| at)
            .find(|&at| {
                let mut tried = result.clone();
                if let Some(slot) = tried.get_mut(at) {
                    slot.clone_from(new);
                }
                super::parse_globals(&tried).is_ok_and(|(_, words)| words == expected)
            })?;
        if let Some(slot) = result.get_mut(position) {
            slot.clone_from(new);
        }
    }
    Some(result)
}

#[cfg(test)]
#[path = "agent_names/tests.rs"]
mod tests;
