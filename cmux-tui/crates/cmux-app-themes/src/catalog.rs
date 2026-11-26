//! Swift `ThemeCatalog.accepts`: whether a typed theme spec names themes the
//! catalog lists (or theme files by absolute path, which the app stats).

use std::collections::BTreeSet;

use serde::Serialize;

use crate::theme_spec::ThemeSpec;

/// What the catalog says about a typed spec.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "verdict", rename_all = "camelCase")]
pub enum Acceptance {
    Accept,
    Refuse,
    /// Accept when every one of these absolute paths exists (the app stats them).
    AcceptIfFiles {
        paths: Vec<String>,
    },
}

/// `known` is the catalog's names; empty until it has listed them, and then
/// any well-formed spec is accepted.
pub fn accepts(text: &str, known: &BTreeSet<String>) -> Acceptance {
    let Some(spec) = ThemeSpec::parse(text) else { return Acceptance::Refuse };
    if known.is_empty() {
        return Acceptance::Accept;
    }
    let names: BTreeSet<String> = [spec.light, spec.dark].into();
    let unknown: Vec<String> = names.into_iter().filter(|name| !known.contains(name)).collect();
    if unknown.is_empty() {
        Acceptance::Accept
    } else if unknown.iter().all(|name| name.starts_with('/')) {
        Acceptance::AcceptIfFiles { paths: unknown }
    } else {
        Acceptance::Refuse
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn a_malformed_spec_is_refused_even_before_the_list() {
        assert_eq!(accepts("a=b", &known(&[])), Acceptance::Refuse);
        assert_eq!(accepts("", &known(&["Nord"])), Acceptance::Refuse);
    }

    #[test]
    fn before_the_list_any_spec_passes() {
        assert_eq!(accepts("Anything", &known(&[])), Acceptance::Accept);
    }

    #[test]
    fn every_side_must_be_known_or_an_absolute_path() {
        let names = known(&["Nord", "Dracula"]);
        assert_eq!(accepts("Nord", &names), Acceptance::Accept);
        assert_eq!(accepts("light:Nord,dark:Dracula", &names), Acceptance::Accept);
        assert_eq!(accepts("light:Nord,dark:Nope", &names), Acceptance::Refuse);
        assert_eq!(accepts("nord", &names), Acceptance::Refuse);
        assert_eq!(
            accepts("light:/tmp/a,dark:Nord", &names),
            Acceptance::AcceptIfFiles { paths: vec!["/tmp/a".to_owned()] }
        );
        assert_eq!(accepts("light:/tmp/a,dark:Nope", &names), Acceptance::Refuse);
        // A theme spec has no `:` in a plain name, so a path comes as a pair side.
        assert_eq!(
            accepts("/tmp/b", &names),
            Acceptance::AcceptIfFiles { paths: vec!["/tmp/b".to_owned()] }
        );
    }
}
