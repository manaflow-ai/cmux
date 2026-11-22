//! Search filters: `in:tabs`, `-in:history`, `kind:settings,commands` in a palette query.
//!
//! Leo (2026-11-18): "do we have any kind of filtering mechanism for the searching? Presumably,
//! some people don't necessarily want to be ... looking through the entirety of the universe".
//! A page that searches many kinds of rows (Search Everything) sends the names of its sections
//! ([`crate::RankRequest::section_names`]); a query token `in:NAME`, `kind:NAME` or `is:NAME`
//! keeps only the rows of the sections NAME names, and `-in:NAME` (`-kind:`, `-is:`) drops them.
//! NAME names a section when one of the section's words starts with it, so `in:tab`, `in:tabs`
//! and `in:t` all name Tabs; a comma lists several (`in:tabs,history`). A token whose name
//! names no section stays in the query as text, and a bare `in:` (still being typed) filters
//! nothing.

use crate::Entry;
use serde::Serialize;
use std::collections::BTreeSet;

/// The filter a query asks for, and the query without its filter tokens.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryFilter {
    /// The query with the filter tokens removed (words joined by one space).
    pub rest: String,
    /// Section indexes to keep; empty keeps every section not excluded.
    pub include: Vec<i64>,
    /// Section indexes to drop.
    pub exclude: Vec<i64>,
    /// Whether the query had any filter token (even a bare `in:`).
    pub applied: bool,
}

impl QueryFilter {
    /// Whether rows of section `section` pass the filter.
    pub fn allows(&self, section: i64) -> bool {
        (self.include.is_empty() || self.include.contains(&section))
            && !self.exclude.contains(&section)
    }

    /// Whether the filter keeps or drops any section (a bare `in:` does neither).
    pub fn restricts(&self) -> bool {
        !self.include.is_empty() || !self.exclude.is_empty()
    }

    /// Whether `entry`'s rows pass: the section it shows in while the user types.
    pub(crate) fn allows_entry(&self, entry: &Entry) -> bool {
        self.allows(entry.typing_section_index.or(entry.section_index).unwrap_or(0))
    }
}

const OPERATORS: [&str; 3] = ["in", "kind", "is"];

fn words(name: &str) -> impl Iterator<Item = String> + '_ {
    name.split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
}

/// The sections `value` names (see the module docs).
fn named(value: &str, section_names: &[Vec<String>]) -> BTreeSet<i64> {
    let value = value.to_lowercase();
    // `in:tabs` also names a section whose word is "tab", and `in:chats` one named "chat".
    let singular = value.strip_suffix('s').filter(|stem| !stem.is_empty());
    let mut found = BTreeSet::new();
    for (index, names) in section_names.iter().enumerate() {
        let hit = names.iter().flat_map(|name| words(name)).any(|word| {
            word.starts_with(&value) || singular.is_some_and(|stem| word.starts_with(stem))
        });
        if hit && let Ok(index) = i64::try_from(index) {
            found.insert(index);
        }
    }
    found
}

/// Reads the filter tokens of `query` against the page's `section_names` (one list of names per
/// section index: its title, its id).
pub fn parse(query: &str, section_names: &[Vec<String>]) -> QueryFilter {
    let mut include = BTreeSet::new();
    let mut exclude = BTreeSet::new();
    let mut rest: Vec<&str> = Vec::new();
    let mut applied = false;
    for token in query.split_whitespace() {
        let (negated, body) = match token.strip_prefix('-') {
            Some(body) => (true, body),
            None => (false, token),
        };
        let Some((operator, value)) = body.split_once(':') else {
            rest.push(token);
            continue;
        };
        if !OPERATORS.iter().any(|known| operator.eq_ignore_ascii_case(known)) {
            rest.push(token);
            continue;
        }
        let names: Vec<&str> = value.split(',').filter(|name| !name.is_empty()).collect();
        if names.is_empty() {
            // `in:` while the name is still being typed.
            applied = true;
            continue;
        }
        let mut found = BTreeSet::new();
        for name in names {
            found.extend(named(name, section_names));
        }
        if found.is_empty() {
            // Names no section: plain text, so a title with a colon still matches.
            rest.push(token);
            continue;
        }
        applied = true;
        if negated { exclude.extend(found) } else { include.extend(found) }
    }
    QueryFilter {
        rest: rest.join(" "),
        include: include.into_iter().collect(),
        exclude: exclude.into_iter().collect(),
        applied,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names() -> Vec<Vec<String>> {
        [
            ("Workspaces", "workspaces"),
            ("Tabs", "navigation"),
            ("History", "search.history"),
            ("Settings", "settings"),
            ("Commands", "search.commands"),
            ("Chats & agents", "search.chats"),
        ]
        .iter()
        .map(|(title, id)| vec![title.to_string(), id.to_string()])
        .collect()
    }

    #[test]
    fn in_keeps_the_named_section_and_removes_the_token() {
        let filter = parse("in:tabs deploy", &names());
        assert_eq!(filter.rest, "deploy");
        assert_eq!(filter.include, vec![1]);
        assert!(filter.exclude.is_empty());
        assert!(filter.applied && filter.restricts());
    }

    #[test]
    fn a_singular_a_prefix_and_any_case_name_the_same_section() {
        for query in ["in:tab x", "in:TA x", "IN:Tabs x", "kind:tab x", "is:tabs x"] {
            assert_eq!(parse(query, &names()).include, vec![1], "{query}");
        }
    }

    #[test]
    fn negation_excludes_and_commas_list_several() {
        let filter = parse("-in:history,settings foo", &names());
        assert_eq!(filter.exclude, vec![2, 3]);
        assert!(filter.include.is_empty());
        assert!(!filter.allows(2) && filter.allows(1));
        let filter = parse("foo in:tabs in:chats bar", &names());
        assert_eq!(filter.include, vec![1, 5]);
        assert_eq!(filter.rest, "foo bar");
    }

    #[test]
    fn a_word_of_a_title_or_id_names_the_section() {
        // "agents" is the second word of "Chats & agents".
        assert_eq!(parse("in:agents", &names()).include, vec![5]);
        assert_eq!(parse("in:history", &names()).include, vec![2]);
    }

    #[test]
    fn a_name_of_no_section_is_text_and_a_bare_operator_filters_nothing() {
        let filter = parse("in:nowhere foo", &names());
        assert_eq!(filter.rest, "in:nowhere foo");
        assert!(!filter.applied);
        let filter = parse("foo in:", &names());
        assert_eq!(filter.rest, "foo");
        assert!(filter.applied && !filter.restricts());
        let filter = parse("http://example.com", &names());
        assert_eq!(filter.rest, "http://example.com");
        assert!(!filter.applied);
    }
}
