use std::collections::BTreeSet;

use super::*;

/// The catalog's offered `cloud …` verbs (the app answers them).
fn offered_verbs() -> BTreeSet<String> {
    let catalog: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../../../plans/cmux-next/action-surfaces.json"
    ))
    .expect("action-surfaces.json is valid JSON");
    catalog["actions"]
        .as_array()
        .expect("actions array")
        .iter()
        .filter(|action| action["cli"] == "offered")
        .filter_map(|action| action["cli_name"].as_str()?.strip_prefix("cloud ").map(str::to_owned))
        .collect()
}

fn listed_verbs() -> Vec<&'static str> {
    GROUPS.iter().flat_map(|group| group.verbs).map(|verb| verb.name).collect()
}

#[test]
fn help_lists_exactly_the_offered_cloud_verbs() {
    let listed = listed_verbs();
    let unique = listed.iter().map(|name| (*name).to_owned()).collect::<BTreeSet<_>>();
    assert_eq!(unique.len(), listed.len(), "a verb is listed twice: {listed:?}");
    let offered = offered_verbs();
    let missing = offered.difference(&unique).collect::<Vec<_>>();
    let stale = unique.difference(&offered).collect::<Vec<_>>();
    assert!(missing.is_empty(), "cloud help omits offered verbs: {missing:?}");
    assert!(stale.is_empty(), "cloud help lists verbs the catalog no longer offers: {stale:?}");
}

#[test]
fn every_row_starts_its_description_in_one_column() {
    for japanese in [false, true] {
        let text = overview(japanese);
        let columns = listed_verbs()
            .into_iter()
            .filter(|name| renamed(name).is_none())
            .map(|name| {
                let prefix = format!("  {name} ");
                let row = text
                    .lines()
                    .find(|line| line.starts_with(&prefix))
                    .unwrap_or_else(|| panic!("no row for {name}"));
                let after_name = &row[prefix.len() - 1..];
                prefix.len() - 1 + (after_name.len() - after_name.trim_start().len())
            })
            .collect::<BTreeSet<_>>();
        assert_eq!(columns.len(), 1, "descriptions start at columns {columns:?}");
    }
}

/// The verbs that act on no one machine, or pick or create it themselves:
/// every other verb's usage starts with the target (CloudActionCatalog.swift
/// gives those `targets: [.machine]`).
const TARGETLESS: &[&str] = &[
    "list-machines",
    "new-machine",
    "new-workspace",
    "start-session",
    "network-list",
    "tunnel-attach",
    "tunnel-detach",
    "tunnel-rotate-key",
    "firewall-list",
    "firewall-get",
    "firewall-create",
    "firewall-delete",
    "domain-list",
    "publication-list",
    "api-key-list",
    "api-key-revoke",
    "move",
    "bring-back",
    "move-to-machine",
    "sign-in",
    "sign-out",
    "diagnostics",
    "open-mobile-pairing",
];

#[test]
fn every_verb_has_both_languages_and_a_target_when_it_names_a_machine() {
    for verb in GROUPS.iter().flat_map(|group| group.verbs) {
        assert_eq!(
            verb.usage.starts_with("{target}"),
            !TARGETLESS.contains(&verb.name),
            "{}: usage {:?}",
            verb.name,
            verb.usage
        );
        assert!(!verb.en.is_empty() && !verb.ja.is_empty(), "{} lacks a description", verb.name);
        assert_ne!(verb.en, verb.ja, "{} is not translated", verb.name);
        let usage = usage_line(verb);
        assert!(!usage.contains("{target}"), "{usage}");
        assert!(usage.starts_with(&format!("cmux vm {}", verb.name)), "{usage}");
    }
    for group in GROUPS {
        assert_ne!(group.en, group.ja);
    }
}

#[test]
fn destructive_verbs_show_yes_in_the_list_and_their_help() {
    let destructive = GROUPS
        .iter()
        .flat_map(|group| group.verbs)
        .filter(|verb| verb.usage.contains("--yes"))
        .map(|verb| verb.name)
        .collect::<BTreeSet<_>>();
    assert_eq!(
        destructive,
        BTreeSet::from([
            "api-key-revoke",
            "delete-snapshot",
            "file-remove",
            "firewall-delete",
            "kill-machine"
        ])
    );
    let text = overview(false);
    for name in &destructive {
        let row = text.lines().find(|line| line.starts_with(&format!("  {name} "))).unwrap();
        assert!(row.ends_with("(--yes)"), "{row}");
        let help = verb_help(name, false).unwrap();
        assert!(help.contains("--yes") && !help.contains("--confirm"), "{help}");
    }
}

#[test]
fn verb_help_is_that_verb_only() {
    let help = verb_help("kill-machine", false).expect("kill-machine help");
    assert!(help.starts_with("usage: cmux vm kill-machine --target vm:VM_ID --yes\n"));
    assert!(help.contains("cmux action describe cloud kill-machine --json"));
    assert!(!help.contains("list-machines"), "{help}");
    let japanese = verb_help("kill-machine", true).expect("kill-machine ja help");
    assert!(japanese.starts_with("使い方: cmux vm kill-machine"), "{japanese}");
    assert_eq!(verb_help("no-such-verb", false), None);
}

#[test]
fn exec_usage_is_the_parse_error_text() {
    assert_eq!(usage("exec").as_deref(), Some("cmux vm exec --target vm:VM_ID --command COMMAND"));
}

/// `command` split as a shell would, for the single quotes the quick start uses.
fn shell_words(command: &str) -> Vec<String> {
    command
        .split('\'')
        .enumerate()
        .flat_map(|(index, part)| {
            if index % 2 == 1 {
                vec![part.to_owned()]
            } else {
                part.split_whitespace().map(str::to_owned).collect()
            }
        })
        .collect()
}

#[cfg(unix)]
#[test]
fn quick_start_commands_parse() {
    for japanese in [false, true] {
        let text = overview(japanese);
        let commands = text
            .lines()
            .map(str::trim)
            .filter(|line| {
                (line.starts_with("cmux vm ") || line.starts_with("cmux chat "))
                    && !line.contains('<')
                    && !line.contains(" | ")
            })
            // These run in this CLI, not through the app's catalog; `cloud env` lines parse in
            // `cloud_environment.rs` (`the_help_env_lines_parse`).
            .filter(|line| !line.contains("secret") && !line.contains("client-session"))
            .filter(|line| !line.starts_with("cmux vm env "))
            .collect::<Vec<_>>();
        // Two `cmux chat --on vm:` lines, the `cmux chat send` follow-up and eight machine lines,
        // most of them short verbs, and `vm new`. No line is a `vm start-chat` or `vm chat`.
        assert_eq!(commands.len(), 11, "{commands:?}");
        assert!(commands[0].starts_with("cmux chat --on vm:"), "the chat leads: {commands:?}");
        assert!(!text.contains("vm start-chat") && !text.contains("vm chat"), "{text}");
        for command in commands {
            if let Some(rest) = command.strip_prefix("cmux chat send ") {
                assert!(
                    matches!(
                        crate::cli::chat_send::parse(&shell_words(rest), true),
                        Ok(crate::cli::chat_send::Parsed::Run(_))
                    ),
                    "quick start command does not parse: {command}"
                );
                continue;
            }
            if let Some(rest) = command.strip_prefix("cmux chat ") {
                let words = shell_words(rest)
                    .into_iter()
                    .filter(|word| word != "--json")
                    .collect::<Vec<_>>();
                assert!(
                    matches!(
                        crate::cli::chat_start::parse(&words, None),
                        Ok(crate::cli::chat_start::Parsed::Run(_))
                    ),
                    "quick start command does not parse: {command}"
                );
                continue;
            }
            // A short verb (`vm pause dev`) runs the app's Cloud verb (vm_short.rs).
            let words = shell_words(command);
            if let Some(short) = crate::cli::vm_short::parse(&words[1..]) {
                assert!(find(short.cloud_verb).is_some(), "{command}");
                continue;
            }
            // `vm new` is the app's Cloud create when the app is here (vm.rs `new_route`).
            if words.get(2).map(String::as_str) == Some("new") {
                assert_eq!(
                    crate::cli::vm::new_route(&words[3..], true),
                    crate::cli::vm::NewRoute::App,
                    "{command}"
                );
                continue;
            }
            // `vm VERB` runs as `cloud VERB` (vm.rs `cloud_alias`).
            let alias = crate::cli::vm::cloud_alias(&shell_words(command)[1..]);
            let words = alias
                .unwrap_or_else(|| panic!("{command} is not a Cloud verb"))
                .into_iter()
                .filter(|word| word != "--json")
                .collect::<Vec<_>>();
            if words[1] == START_CHAT {
                assert!(
                    matches!(
                        crate::cli::cloud_start_chat::parse(&words[2..], || Err(String::new())),
                        Ok(crate::cli::cloud_start_chat::Parsed::Run(_))
                    ),
                    "quick start command does not parse: {command}"
                );
                continue;
            }
            assert!(find(&words[1]).is_some(), "{command}");
            assert!(
                matches!(crate::cli::app::parse(&words), Ok(Some(_))),
                "quick start command does not parse: {command}"
            );
        }
    }
}

/// `cloud new-machine` is `cmux vm new`'s old name: the overview shows
/// only `vm new`, and the old verb's own help names it.
#[test]
fn renamed_verbs_are_hidden_and_point_at_their_new_name() {
    for japanese in [false, true] {
        let text = overview(japanese);
        assert!(!text.lines().any(|line| line.starts_with("  new-machine ")), "{text}");
        assert!(!text.contains("cmux vm new-machine"), "{text}");
        // The quick start makes a Cloud VM with `vm new` (the app's create, as `machine new` was).
        assert!(text.contains("cmux vm new --size"), "{text}");
        let help = verb_help("new-machine", japanese).unwrap();
        assert!(help.contains("cmux vm new"), "{help}");
        assert!(help.contains("cmux vm new-machine [--size"), "{help}");
    }
    for (old, _) in HIDDEN {
        assert!(find(old).is_some(), "{old} is hidden but not a verb");
    }
}

#[cfg(unix)]
#[test]
fn start_chat_help_is_its_usage_and_its_examples_parse() {
    for japanese in [false, true] {
        assert_eq!(verb_help(START_CHAT, japanese).as_deref(), Some(START_CHAT_USAGE));
    }
    assert!(START_CHAT_USAGE.starts_with("usage: cmux cloud start-chat [--prompt TEXT]"));
    // The start matrix runs its no-name row only on a build whose help names new_machine (cmuxterm-hq#7406).
    assert!(START_CHAT_USAGE.contains("new_machine: true"));
    let examples = START_CHAT_USAGE
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with("cmux cloud start-chat "))
        .collect::<Vec<_>>();
    assert_eq!(examples.len(), 3, "{examples:?}");
    for example in examples {
        let words =
            shell_words(example).into_iter().skip(3).filter(|w| w != "--json").collect::<Vec<_>>();
        assert!(
            matches!(
                crate::cli::cloud_start_chat::parse(&words, || Err(String::new())),
                Ok(crate::cli::cloud_start_chat::Parsed::Run(_))
            ),
            "{example}"
        );
    }
}

/// Each flag a verb's usage shows is an argument its catalog action takes, and
/// each argument the action takes is in its usage. `--target`,
/// `--focus` and `--arg` are the CLI's own, on every action.
#[test]
fn every_usage_flag_is_a_catalog_argument_and_back() {
    let catalog: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../../../plans/cmux-next/action-surfaces.json"
    ))
    .expect("action-surfaces.json is valid JSON");
    let camel = |flag: &str| {
        let mut parts = flag.split('-');
        let mut name = parts.next().unwrap_or_default().to_owned();
        for part in parts {
            let mut chars = part.chars();
            if let Some(first) = chars.next() {
                name.extend(first.to_uppercase());
                name.push_str(chars.as_str());
            }
        }
        name
    };
    for verb in GROUPS.iter().flat_map(|group| group.verbs) {
        let action = catalog["actions"]
            .as_array()
            .expect("actions array")
            .iter()
            .find(|action| action["cli_name"] == format!("cloud {}", verb.name))
            .unwrap_or_else(|| panic!("{} has no catalog action", verb.name));
        let args = action["args"]
            .as_array()
            .map(|args| {
                args.iter().filter_map(|arg| arg["name"].as_str().map(str::to_owned)).collect()
            })
            .unwrap_or_else(BTreeSet::new);
        let flags = verb
            .usage
            .split(|c: char| c.is_whitespace() || "[]()|'".contains(c))
            .filter_map(|word| {
                if word.starts_with("path=") {
                    return Some("path".to_owned());
                }
                let flag = word.strip_prefix("--")?;
                // `--yes` reaches the app as its `--confirm` (vm.rs `yes_as_confirm`).
                let flag = if flag == "yes" { "confirm" } else { flag };
                (!["target", "focus", "arg"].contains(&flag)).then(|| camel(flag))
            })
            .collect::<BTreeSet<_>>();
        assert_eq!(flags, args, "{}: usage {:?}", verb.name, verb.usage);
    }
}

#[test]
fn verbs_cloud_refuses_are_marked_in_the_list_and_their_help() {
    for name in NOT_ON_CLOUD_YET {
        assert!(find(name).is_some(), "{name} is not a verb");
    }
    for japanese in [false, true] {
        let text = overview(japanese);
        for verb in GROUPS.iter().flat_map(|group| group.verbs) {
            let row = text.lines().find(|line| line.starts_with(&format!("  {} ", verb.name)));
            let Some(row) = row else { continue };
            let marked =
                row.contains(if japanese { "Cloud では未対応" } else { "not on Cloud yet" });
            assert_eq!(marked, NOT_ON_CLOUD_YET.contains(&verb.name), "{row}");
        }
    }
    let help = verb_help("firewall-delete", false).unwrap();
    assert!(help.starts_with("Cloud does not offer this yet"), "{help}");
    assert!(help.contains("--yes"), "{help}");
    assert!(!verb_help("kill-machine", false).unwrap().contains("does not offer"));
}
