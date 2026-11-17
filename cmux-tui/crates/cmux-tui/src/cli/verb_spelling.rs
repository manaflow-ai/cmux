//! The other spellings of an app verb (cmux#44937): the words a person or an agent reaches for
//! first, mapped to the catalog's CLI name (plans/cmux-next/action-surfaces.json), so every app
//! verb also answers to them and none needs its own hand-written module.
//!
//! - Object first, as the resource grammar spells it: `cmux <noun> <id> <verb…> [flags]` is
//!   `cmux <noun> <verb…> --target <id> [flags]` (`cmux workspace ws_… pin`, `cmux tab tab_…
//!   mute-unmute`). Only an id: the app's action target is an id, so a name, `current` or `caller`
//!   stays the grammar's usage error.
//! - A state, not a toggle: `<noun> X` and `<noun> unX` run the toggle `<noun> X-unX` or
//!   `<noun> toggle-X` with its bool argument named for X (`pinned`) set to true or false, so
//!   `cmux workspace pin` and `cmux workspace unpin` set the pin instead of flipping it.
//! - `cmux action run <verb>` for a verb that is no action's id or CLI name: a usage error that
//!   names each action whose CLI name ends in that verb (`pin-unpin` is a workspace's, a tab's
//!   and a home conversation's). It never runs one by itself: one match among the offered names
//!   is no proof that it is the one meant (`pin` is also a tab's mux verb).

use std::collections::HashMap;
use std::sync::OnceLock;

use serde_json::Value;

/// An offered app action's bool argument names, by CLI name; and every id and CLI name the
/// catalog has, offered or not.
struct Catalog {
    offered: HashMap<String, Vec<String>>,
    names: std::collections::HashSet<String>,
}

fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let doc: Value =
            serde_json::from_str(super::app_action_help::ACTIONS_JSON).unwrap_or(Value::Null);
        let mut catalog = Catalog { offered: HashMap::new(), names: Default::default() };
        for action in doc.get("actions").and_then(Value::as_array).into_iter().flatten() {
            let cli_name = action.get("cli_name").and_then(Value::as_str);
            for name in [action.get("id").and_then(Value::as_str), cli_name].into_iter().flatten() {
                catalog.names.insert(name.to_owned());
            }
            let Some(cli_name) = cli_name else { continue };
            if action.get("cli").and_then(Value::as_str) != Some("offered") {
                continue;
            }
            let bools = action
                .get("args")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|arg| arg.get("kind").and_then(Value::as_str) == Some("bool"))
                .filter_map(|arg| arg.get("name").and_then(Value::as_str).map(str::to_owned))
                .collect();
            catalog.offered.insert(cli_name.to_owned(), bools);
        }
        catalog
    })
}

/// A public object id (`ws_…`, `tab_…`, `pane_…`, `term_…`): lowercase letters, `_`, then at
/// least 16 lowercase hex digits, so a snake_case name (`my_proj`) is not taken for one.
fn is_object_id(word: &str) -> bool {
    let Some((kind, rest)) = word.split_once('_') else { return false };
    !kind.is_empty()
        && kind.chars().all(|character| character.is_ascii_lowercase())
        && rest.len() >= 16
        && rest.chars().all(|character| matches!(character, '0'..='9' | 'a'..='f'))
}

/// `<noun> X` or `<noun> unX` as the toggle that takes X's state: its CLI name and the bool
/// argument's `--flag` with `true` or `false`.
fn state_spelling(noun: &str, verb: &str) -> Option<(String, [String; 2])> {
    let (base, on) = match verb.strip_prefix("un") {
        Some(base) if !base.is_empty() => (base, false),
        _ => (verb, true),
    };
    let offered = &catalog().offered;
    [format!("{noun} {base}-un{base}"), format!("{noun} toggle-{base}")].into_iter().find_map(
        |name| {
            // The state's own name only (`pin`: `pin`, `pinned`, `pined`), not any argument
            // that merely starts with the word.
            let states = [base.to_owned(), format!("{base}ned"), format!("{base}ed")];
            let argument = offered.get(&name)?.iter().find(|argument| states.contains(argument))?;
            Some((name, [format!("--{}", kebab(argument)), on.to_string()]))
        },
    )
}

/// `pinnedOnly` as its flag: `pinned-only`.
fn kebab(name: &str) -> String {
    let mut flag = String::with_capacity(name.len());
    for character in name.chars() {
        if character.is_ascii_uppercase() {
            flag.push('-');
            flag.push(character.to_ascii_lowercase());
        } else {
            flag.push(character);
        }
    }
    flag
}

/// The app action and its flags for another spelling of an offered app verb, or None for words
/// that are not one (the caller keeps its own path for those).
pub(super) fn action(command_args: &[String]) -> Option<(String, Vec<String>)> {
    let (noun, rest) = command_args.split_first()?;
    let (target, rest) = match rest.split_first() {
        Some((id, rest)) if is_object_id(id) => (Some(id), rest),
        _ => (None, rest),
    };
    let words = rest.iter().take_while(|word| !word.starts_with('-')).count();
    if words == 0 {
        return None;
    }
    let (verb, flags) = rest.split_at(words);
    // The object is named once: an id before the verb and a --target after it is ambiguous.
    if target.is_some()
        && flags.iter().any(|flag| flag == "--target" || flag.starts_with("--target="))
    {
        return None;
    }
    let name = format!("{noun} {}", verb.join(" "));
    let (name, mut args) = if catalog().offered.contains_key(&name) {
        // Only the object-first form is a new spelling of an offered name.
        target?;
        (name, Vec::new())
    } else {
        let [verb] = verb else { return None };
        let (name, state) = state_spelling(noun, verb)?;
        (name, state.to_vec())
    };
    if let Some(target) = target {
        args.splice(0..0, ["--target".to_owned(), target.clone()]);
    }
    args.extend(flags.iter().cloned());
    Some((name, args))
}

/// `cmux action run <verb>`: `Ok` to send `name` as it is, or `Err` with the CLI names a bare
/// verb that is no action's id or CLI name could mean.
pub(super) fn action_run_name(name: &str) -> Result<(), Vec<String>> {
    let catalog = catalog();
    let spaced = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if spaced.contains(' ') || catalog.names.contains(&spaced) {
        return Ok(());
    }
    let suffix = format!(" {spaced}");
    let mut matches = catalog
        .offered
        .keys()
        .filter(|cli_name| cli_name.ends_with(&suffix))
        .cloned()
        .collect::<Vec<_>>();
    matches.sort();
    if matches.is_empty() { Ok(()) } else { Err(matches) }
}
