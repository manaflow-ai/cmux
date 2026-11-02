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
        assert!(usage.starts_with(&format!("cmux cloud {}", verb.name)), "{usage}");
    }
    for group in GROUPS {
        assert_ne!(group.en, group.ja);
    }
}

#[test]
fn destructive_verbs_show_confirm_in_the_list_and_their_help() {
    let destructive = GROUPS
        .iter()
        .flat_map(|group| group.verbs)
        .filter(|verb| verb.usage.contains("--confirm"))
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
        assert!(row.ends_with("(--confirm)"), "{row}");
        let help = verb_help(name, false).unwrap();
        assert!(help.contains("--confirm"), "{help}");
    }
}

#[test]
fn verb_help_is_that_verb_only() {
    let help = verb_help("kill-machine", false).expect("kill-machine help");
    assert!(
        help.starts_with("usage: cmux cloud kill-machine --target machine:MACHINE_ID --confirm\n")
    );
    assert!(help.contains("cmux action describe cloud kill-machine --json"));
    assert!(!help.contains("list-machines"), "{help}");
    let japanese = verb_help("kill-machine", true).expect("kill-machine ja help");
    assert!(japanese.starts_with("使い方: cmux cloud kill-machine"), "{japanese}");
    assert_eq!(verb_help("no-such-verb", false), None);
}

#[test]
fn exec_usage_is_the_parse_error_text() {
    assert_eq!(
        usage("exec").as_deref(),
        Some("cmux cloud exec --target machine:MACHINE_ID --command COMMAND")
    );
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
            .filter(|line| line.starts_with("cmux cloud ") && !line.contains('<'))
            .filter(|line| !line.contains("secret") && !line.contains("client-session"))
            .collect::<Vec<_>>();
        assert_eq!(commands.len(), 6, "{commands:?}");
        for command in commands {
            let words = shell_words(command)
                .into_iter()
                .skip(1)
                .filter(|word| word != "--json")
                .collect::<Vec<_>>();
            assert!(find(&words[1]).is_some(), "{command}");
            assert!(
                matches!(crate::cli::app::parse(&words), Ok(Some(_))),
                "quick start command does not parse: {command}"
            );
        }
    }
}
