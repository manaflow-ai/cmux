//! A cataloged CLI name that is not a CLI verb (plans/cmux-next/actions.md):
//! every catalog action has a `cli_name`, but only the actions the CLI offers
//! run as `cmux <noun> <verb>`. For the others (`cli` is an exemption, such as
//! guiOnly) the CLI tells the user to run them with `cmux action run <id>`,
//! instead of a bare usage error.

use std::collections::HashMap;
use std::sync::OnceLock;

use cmux_tui_core::packed_catalogs::ACTION_SURFACES;
use serde_json::Value;

use super::OutputMode;

/// EX_USAGE: the words named an action, but not as a verb.
pub(super) const EXIT_CODE: i32 = 64;

fn non_verbs() -> &'static HashMap<String, String> {
    static NON_VERBS: OnceLock<HashMap<String, String>> = OnceLock::new();
    NON_VERBS.get_or_init(|| {
        let doc: Value = serde_json::from_str(&ACTION_SURFACES.inflate()).unwrap_or(Value::Null);
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

/// Whether the app action named `action` (its id or its CLI name) takes an argument called `argument`
/// (plans/cmux-next/action-surfaces.json `args`).
pub(super) fn action_takes_argument(action: &str, argument: &str) -> bool {
    static ARGS: OnceLock<HashMap<String, Vec<String>>> = OnceLock::new();
    ARGS.get_or_init(|| {
        let doc: Value = serde_json::from_str(&ACTION_SURFACES.inflate()).unwrap_or(Value::Null);
        let mut map = HashMap::new();
        for action in doc.get("actions").and_then(Value::as_array).into_iter().flatten() {
            let names: Vec<String> = action
                .get("args")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|arg| arg.get("name").and_then(Value::as_str).map(str::to_owned))
                .collect();
            for key in ["id", "cli_name"].into_iter().filter_map(|key| action.get(key)?.as_str()) {
                map.insert(key.to_owned(), names.clone());
            }
        }
        map
    })
    .get(action)
    .is_some_and(|names| names.iter().any(|name| name == argument))
}

/// `cmux <noun> <verb> VALUE…` for an offered app action: the action's CLI name
/// and its flags, each VALUE given as `--<argument> VALUE` for the action's
/// required arguments in order (`apps install REF` is `apps install --app REF`).
/// The app resolves CLI names exactly and takes arguments only by name, so a
/// positional REF read as part of the name ("No CLI command 'apps install
/// REF'"); `cmux setup install`'s extension step, `ext dev` and `ext share`
/// all ran it that way (ask-b6bc62ad66). `None` when no leading run of
/// `words` is an offered CLI name, or more values follow than it requires.
pub(super) fn positional_action(words: &[String]) -> Option<(String, Vec<String>)> {
    if offered_app_action(&words.join(" ")) {
        return None;
    }
    (1..words.len()).rev().find_map(|n| {
        let name = words[..n].join(" ");
        if !offered_app_action(&name) {
            return None;
        }
        let required = required_arguments(&name);
        let values = &words[n..];
        if values.len() > required.len() {
            return None;
        }
        let flags = required
            .iter()
            .zip(values)
            .flat_map(|(argument, value)| [format!("--{argument}"), value.clone()])
            .collect();
        Some((name, flags))
    })
}

/// The required argument names of the offered action with CLI name `name`, in schema order.
fn required_arguments(name: &str) -> Vec<String> {
    let doc: Value = serde_json::from_str(&ACTION_SURFACES.inflate()).unwrap_or(Value::Null);
    doc.get("actions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|action| action.get("cli_name").and_then(Value::as_str) == Some(name))
        .and_then(|action| action.get("args").and_then(Value::as_array))
        .into_iter()
        .flatten()
        .filter(|arg| arg.get("required").and_then(Value::as_bool) == Some(true))
        .filter_map(|arg| arg.get("name").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// Whether the catalog has an app action that the CLI offers as `cmux <name>`.
pub(super) fn offered_app_action(name: &str) -> bool {
    static OFFERED: OnceLock<std::collections::HashSet<String>> = OnceLock::new();
    OFFERED
        .get_or_init(|| {
            let doc: Value =
                serde_json::from_str(&ACTION_SURFACES.inflate()).unwrap_or(Value::Null);
            doc.get("actions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|action| action.get("cli").and_then(Value::as_str) == Some("offered"))
                .filter_map(|action| action.get("cli_name").and_then(Value::as_str))
                .map(str::to_owned)
                .collect()
        })
        .contains(name)
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

/// Whether `word` starts a built-in command the CLI routes after the mux grammar:
/// the first word of any catalog action's CLI name (`share` of `share revoke`),
/// and `agent view`. An installed app's `cli.name` never shadows one of these.
pub(super) fn builtin_first_word(word: &str) -> bool {
    static FIRST: OnceLock<std::collections::HashSet<String>> = OnceLock::new();
    FIRST
        .get_or_init(|| {
            let doc: Value =
                serde_json::from_str(&ACTION_SURFACES.inflate()).unwrap_or(Value::Null);
            let mut words: std::collections::HashSet<String> = doc
                .get("actions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|action| action["cli_name"].as_str()?.split(' ').next())
                .map(str::to_owned)
                .collect();
            words.extend(["share", "agent"].map(str::to_owned));
            words
        })
        .contains(word)
}

#[cfg(test)]
mod positional_tests {
    use super::positional_action;

    fn words(text: &str) -> Vec<String> {
        text.split(' ').map(str::to_owned).collect()
    }

    #[test]
    fn a_positional_value_is_the_actions_required_argument() {
        // `cmux setup install`'s extension step runs `cmux apps install REF`.
        let (name, flags) =
            positional_action(&words("apps install github.com/manaflow-ai/cmux-extension-sample"))
                .expect("apps install REF");
        assert_eq!(name, "apps install");
        assert_eq!(flags, ["--app", "github.com/manaflow-ai/cmux-extension-sample"]);
        assert_eq!(
            positional_action(&words("apps remove acme/tool")),
            Some(("apps remove".to_owned(), vec!["--app".to_owned(), "acme/tool".to_owned()]))
        );
    }

    #[test]
    fn exact_names_extra_values_and_unknown_words_are_left_alone() {
        assert_eq!(positional_action(&words("apps install")), None);
        assert_eq!(positional_action(&words("apps remove a b")), None);
        assert_eq!(positional_action(&words("workspace frobnicate")), None);
        assert_eq!(positional_action(&words("frobnicate install x")), None);
    }
}
