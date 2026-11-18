//! The APP ACTIONS section of `cmux <scope> --help`: every app action the
//! catalog (plans/cmux-next/action-surfaces.json) offers to the CLI as
//! `cmux <scope> <verb…>`, one line each with its title. Generated from the
//! catalog, so a hand-written scope help (cli/topology_help.rs) never drifts
//! from what the CLI runs: `cmux tab --help` once omitted all 57 `tab` app
//! verbs, `new-mac-screen` and `new-browser` among them. `cloud` keeps its own
//! grouped help (cli/cloud_help.rs), synced by its own test.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde_json::Value;

pub(super) const ACTIONS_JSON: &str =
    include_str!("../../../../../plans/cmux-next/action-surfaces.json");

/// Scopes whose help lists their app verbs another way.
const OWN_HELP: &[&str] = &["cloud"];

/// The widest verb column; a longer verb gets its title after two spaces.
const VERB_COLUMN: usize = 30;

/// The offered app verbs by scope (the CLI name's first word): verb (the rest
/// of the CLI name) and title, sorted by verb.
fn offered() -> &'static BTreeMap<String, Vec<(String, String)>> {
    static OFFERED: OnceLock<BTreeMap<String, Vec<(String, String)>>> = OnceLock::new();
    OFFERED.get_or_init(|| {
        let doc: Value = serde_json::from_str(ACTIONS_JSON).unwrap_or(Value::Null);
        let mut scopes: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for action in doc.get("actions").and_then(Value::as_array).into_iter().flatten() {
            if action.get("cli").and_then(Value::as_str) != Some("offered") {
                continue;
            }
            let Some((scope, verb)) = action
                .get("cli_name")
                .and_then(Value::as_str)
                .and_then(|name| name.split_once(' '))
            else {
                continue;
            };
            let title = action.get("title").and_then(Value::as_str).unwrap_or_default().to_owned();
            scopes.entry(scope.to_owned()).or_default().push((verb.to_owned(), title));
        }
        for verbs in scopes.values_mut() {
            verbs.sort();
            verbs.dedup_by(|a, b| a.0 == b.0);
        }
        scopes
    })
}

#[cfg(test)]
/// The offered app verbs of `scope`, sorted (empty for a scope with none).
pub(super) fn verbs(scope: &str) -> impl Iterator<Item = &'static str> {
    offered().get(scope).into_iter().flatten().map(|(verb, _)| verb.as_str())
}

#[cfg(test)]
/// Every scope with offered app verbs, `cloud` included.
pub(super) fn scopes() -> impl Iterator<Item = &'static str> {
    offered().keys().map(String::as_str)
}

/// Whether `scope` has app verbs this section lists: `cmux <scope> --help`
/// then prints them, never the root help.
pub(super) fn has_section(scope: &str) -> bool {
    !OWN_HELP.contains(&scope) && offered().contains_key(scope)
}

/// The APP ACTIONS section for `scope`, `None` when it has no offered verbs.
pub(super) fn section(scope: &str) -> Option<String> {
    if !has_section(scope) {
        return None;
    }
    let verbs = offered().get(scope)?;
    let width = verbs.iter().map(|(verb, _)| verb.len()).filter(|len| *len <= VERB_COLUMN).max();
    let width = width.unwrap_or(VERB_COLUMN);
    let mut text = format!(
        "APP ACTIONS\n  The cmux app runs these: cmux {scope} <verb> [--<argument> <value>]...\n  \
         `cmux action describe \"{scope} <verb>\"` lists a verb's arguments.\n"
    );
    for (verb, title) in verbs {
        if title.is_empty() {
            text.push_str(&format!("  {verb}\n"));
        } else if verb.len() <= width {
            text.push_str(&format!("  {verb:<width$}  {title}\n"));
        } else {
            text.push_str(&format!("  {verb}  {title}\n"));
        }
    }
    Some(text)
}

/// `text` with the APP ACTIONS section of `scope` after it, when it has one.
pub(crate) fn append(scope: &str, text: &str) -> Option<String> {
    let section = section(scope)?;
    let separator = if text.ends_with('\n') { "\n" } else { "\n\n" };
    Some(format!("{text}{separator}{section}"))
}

/// The usage line of a scope that only app actions answer (`remote`, `chief`,
/// `phone`, …), which [`append`] follows with the section: before it,
/// `cmux <scope> --help` printed the root help.
pub(super) fn scope_only_usage(scope: &str) -> Option<String> {
    has_section(scope).then(|| format!("USAGE\n  cmux {scope} <verb> [--<argument> <value>]...\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scope_lists_its_offered_verbs_one_line_each_with_the_title() {
        let text = section("tab").expect("tab has app verbs");
        let row = text.lines().find(|line| line.trim_start().starts_with("new-mac-screen "));
        let row = row.expect("new-mac-screen is listed");
        assert!(row.ends_with("Screen Sharing"), "{row}");
        assert!(text.lines().any(|line| line.trim_start().starts_with("new-browser ")));
        assert!(text.lines().any(|line| line.trim_start().starts_with("stop-mac-screen-viewing ")));
        assert_eq!(section("cloud"), None, "cloud keeps its own help");
        assert_eq!(section("no-such-scope"), None);
    }

    #[test]
    fn titles_start_in_one_column_per_scope() {
        for scope in scopes().filter(|scope| has_section(scope)) {
            let text = section(scope).expect("section");
            let rows = text.lines().skip(3).collect::<Vec<_>>();
            assert_eq!(rows.len(), verbs(scope).count(), "{scope}: one line per verb");
            // Rows follow the sorted verbs; a verb may be several words (`chat channel create`).
            let columns = rows
                .iter()
                .zip(offered()[scope].iter())
                .filter_map(|(line, (verb, title))| {
                    let rest = line.strip_prefix("  ")?.strip_prefix(verb.as_str())?;
                    (verb.len() <= VERB_COLUMN && !title.is_empty())
                        .then(|| 2 + verb.len() + rest.len() - rest.trim_start().len())
                })
                .collect::<std::collections::BTreeSet<_>>();
            assert!(columns.len() <= 1, "{scope}: titles start at columns {columns:?}");
        }
    }
}
