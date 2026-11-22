//! A cataloged CLI name that is not a CLI verb (plans/cmux-next/actions.md):
//! every catalog action has a `cli_name`, but only the actions the CLI offers
//! run as `cmux <noun> <verb>`. For the others (`cli` is an exemption, such as
//! guiOnly) the CLI tells the user to run them with `cmux action run <id>`,
//! instead of a bare usage error.

use std::collections::HashMap;
use std::sync::OnceLock;

use serde_json::Value;

use super::OutputMode;

const ACTIONS_JSON: &str = include_str!("../../../../../plans/cmux-next/action-surfaces.json");

/// EX_USAGE: the words named an action, but not as a verb.
pub(super) const EXIT_CODE: i32 = 64;

fn non_verbs() -> &'static HashMap<String, String> {
    static NON_VERBS: OnceLock<HashMap<String, String>> = OnceLock::new();
    NON_VERBS.get_or_init(|| {
        let doc: Value = serde_json::from_str(ACTIONS_JSON).unwrap_or(Value::Null);
        doc["actions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|action| action["cli"] != "offered")
            .filter_map(|action| {
                Some((action["cli_name"].as_str()?.to_owned(), action["id"].as_str()?.to_owned()))
            })
            .collect()
    })
}

/// The action id of `name` when the catalog has an action with that CLI
/// name that the CLI does not offer as a verb.
pub(super) fn non_verb_action(name: &str) -> Option<&'static str> {
    non_verbs().get(name).map(String::as_str)
}

pub(super) fn message(name: &str, id: &str) -> String {
    crate::localization::catalog()
        .app_control
        .not_a_verb
        .replace("{name}", name)
        .replace("{id}", id)
}

/// Prints the hint and returns its exit code, when `name` is such an action.
pub(super) fn report(name: &str, output: OutputMode) -> Option<i32> {
    let id = non_verb_action(name)?;
    Some(super::app::failure("usage.not_a_verb", &message(name, id), output, EXIT_CODE))
}
