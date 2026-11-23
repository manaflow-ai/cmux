//! Where a profile's settings key writes: a schema row (`sidebar.sections.order`),
//! or one member of a row whose value is an object keyed by id
//! (`actions.deploy`, `palette.aliases.vs`). A member travels, validates and
//! stacks as its own key, so two palette packs that each bring actions both
//! apply, and turning one off takes back only its own.

use cmux_config::Schema;
use cmux_config::schema::{DomainKind, Kind, Row, Validation};
use serde_json::{Map, Value};

use crate::engine::AGENT_ORIGIN;

/// A settings key a profile may name, resolved.
pub(crate) struct Key {
    pub row: &'static Row,
    /// Where the value goes in the settings file.
    pub path: Vec<String>,
    /// The member id for a member of a keyed row (`deploy` of `actions.deploy`).
    pub member: Option<String>,
}

impl Key {
    /// Whether the row it writes would take `value` there.
    pub fn accepts(&self, value: &Value) -> bool {
        let whole = match &self.member {
            Some(member) => Value::Object(Map::from_iter([(member.clone(), value.clone())])),
            None => value.clone(),
        };
        cmux_config::schema::accepts(self.row, &whole, &Default::default()).is_ok()
    }

    /// Whether `origin` may write it from a profile: a key an agent may set,
    /// or a key [`person_carried`] when the person applies the profile.
    pub fn writable_by(&self, origin: &str) -> bool {
        self.row.agent_settable || (person_carried(self.row) && origin != AGENT_ORIGIN)
    }
}

/// A row whose value is an object of members by id, each customizable alone.
pub(crate) fn keyed(row: &Row) -> bool {
    matches!(row.kind, Kind::StringMap | Kind::SoundRules)
        || row.validation == Validation::Domain(DomainKind::ConfigActions)
}

/// Rows only the person may set that a profile still carries, applied only
/// when the person applies it (never over MCP): their own palette commands.
/// Every other person-only row (accounts, policy, this machine) stays out of
/// profiles.
pub(crate) fn person_carried(row: &Row) -> bool {
    row.validation == Validation::Domain(DomainKind::ConfigActions)
}

/// The row and place `key` writes, or `None` when this cmux has no such
/// setting. An exact row wins; else the longest row key that is a keyed
/// row's, with the rest as one member id (ids may hold dots).
pub(crate) fn resolve(key: &str) -> Option<Key> {
    let schema = Schema::embedded();
    if let Some(row) = schema.row(key) {
        return Some(Key { row, path: row.path.clone(), member: None });
    }
    // The longest head first: the first row found on the way decides.
    let (head, member) = key
        .rmatch_indices('.')
        .filter_map(|(dot, _)| Some((key.get(..dot)?, key.get(dot + 1..)?)))
        .find(|(head, _)| schema.row(head).is_some())?;
    let row = schema.row(head)?;
    if !keyed(row) || member.is_empty() {
        return None;
    }
    let mut path = row.path.clone();
    path.push(member.to_owned());
    Some(Key { row, path, member: Some(member.to_owned()) })
}

/// The value of `key` in a parsed settings file.
pub(crate) fn value_in(file: &Value, key: &str) -> Option<Value> {
    let key = resolve(key)?;
    cmux_config::value::value_at(file, &key.path).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_action_is_its_own_key_under_actions() {
        let key = resolve("actions.deploy").expect("actions.deploy");
        assert_eq!(key.row.key, "actions");
        assert_eq!(key.path, ["actions", "deploy"]);
        assert!(key.accepts(&json!({"title": "Deploy", "command": "make deploy"})));
        assert!(!key.accepts(&json!({"title": "Deploy"})));
        assert!(!key.accepts(&json!("make deploy")));
        // An id with dots is one member.
        assert_eq!(resolve("actions.git.push").expect("dotted").path, ["actions", "git.push"]);
    }

    #[test]
    fn only_the_person_writes_an_action_from_a_profile() {
        let key = resolve("actions.deploy").expect("actions.deploy");
        assert!(key.writable_by("cli"));
        assert!(!key.writable_by(AGENT_ORIGIN));
    }

    #[test]
    fn sidebar_sections_are_rows_and_a_leaf_row_takes_no_member() {
        let key = resolve("sidebar.sections.hidden").expect("sidebar.sections.hidden");
        assert_eq!(key.member, None);
        assert!(key.accepts(&json!(["recents"])));
        assert!(!key.accepts(&json!(["recents", "recents"])));
        assert!(key.writable_by(AGENT_ORIGIN));
        assert!(resolve("sidebar.sections.hidden.x").is_none());
        assert!(resolve("actions.").is_none());
        assert!(resolve("no.such.setting").is_none());
    }
}
