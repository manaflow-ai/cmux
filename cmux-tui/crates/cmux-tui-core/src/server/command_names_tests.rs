use std::collections::BTreeSet;

use serde_json::json;

use super::{COMMANDS, Command, MethodClass};

fn kebab(variant: &str) -> String {
    let mut out = String::with_capacity(variant.len() + 8);
    for (index, ch) in variant.chars().enumerate() {
        if ch.is_ascii_uppercase() && index > 0 {
            out.push('-');
        }
        out.push(ch.to_ascii_lowercase());
    }
    out
}

/// The tags serde accepts, from its own "unknown variant" error.
fn serde_tags() -> BTreeSet<String> {
    let error = serde_json::from_value::<Command>(json!({"cmd": "no-such-command"}))
        .err()
        .expect("an unknown tag is refused")
        .to_string();
    let (_, expected) = error.split_once("expected one of ").expect("serde lists its tags");
    expected.split(", ").map(|tag| tag.trim_matches('`').to_owned()).collect()
}

#[test]
fn command_names_match_every_serde_tag() {
    let wires: BTreeSet<String> = COMMANDS.iter().map(|row| row.wire.to_owned()).collect();
    assert_eq!(wires.len(), COMMANDS.len(), "a wire name is listed twice");
    let accepted: BTreeSet<String> = COMMANDS
        .iter()
        .flat_map(|row| std::iter::once(row.wire).chain(row.aliases.iter().copied()))
        .map(str::to_owned)
        .collect();
    let serde = serde_tags();
    let unlisted: Vec<_> = serde.difference(&accepted).collect();
    assert!(unlisted.is_empty(), "tags serde accepts with no row: {unlisted:?}");
    let unknown: Vec<_> = wires.difference(&serde).collect();
    assert!(unknown.is_empty(), "rows serde does not list: {unknown:?}");
}

#[test]
fn command_names_deserialize_to_their_own_row() {
    for row in COMMANDS {
        for name in std::iter::once(row.wire).chain(row.aliases.iter().copied()) {
            match serde_json::from_value::<Command>(json!({"cmd": name})) {
                Ok(command) => {
                    assert_eq!(command.wire_name(), row.wire, "{name}");
                    assert_eq!(command.method_class(), row.class, "{name}");
                }
                Err(error) => {
                    let message = error.to_string();
                    assert!(
                        message.starts_with("missing field"),
                        "{name} must fail only on a missing field, got: {message}"
                    );
                }
            }
        }
    }
}

#[test]
fn command_names_are_the_kebab_case_variant() {
    for row in COMMANDS {
        assert_eq!(row.wire, kebab(row.variant), "{} has a renamed tag", row.variant);
    }
    let aliases: Vec<_> = COMMANDS.iter().flat_map(|row| row.aliases.iter()).collect();
    let unique: BTreeSet<_> = aliases.iter().collect();
    assert_eq!(unique.len(), aliases.len(), "an alias is listed twice");
}

#[test]
fn command_names_known_rows_have_their_class() {
    let class_of = |wire: &str| COMMANDS.iter().find(|row| row.wire == wire).map(|row| row.class);
    assert_eq!(class_of("send"), Some(MethodClass::TerminalIo));
    assert_eq!(class_of("list-workspaces"), Some(MethodClass::Query));
    assert_eq!(class_of("new-tab"), Some(MethodClass::Create));
    assert_eq!(class_of("move-tab"), Some(MethodClass::Topology));
    assert_eq!(class_of("browser-navigate"), Some(MethodClass::Browser));
    assert_eq!(class_of("conversation-op"), Some(MethodClass::Agent));
    assert_eq!(class_of("cloud-inbox-list"), Some(MethodClass::Cloud));
    assert_eq!(class_of("wait-for"), Some(MethodClass::Other));
    assert_eq!(class_of("terminal-resume-command"), Some(MethodClass::TerminalIo));
}

/// Handlers that wait on a child process or the network must be in a class
/// that may wait, so the hang watcher lets them mark the wait.
#[test]
fn command_names_waiting_commands_may_wait() {
    // machine-listening-tcp runs ss and netstat; terminal-ports probes up to
    // 32 loopback ports with a connect timeout each.
    for wire in ["machine-listening-tcp", "terminal-ports"] {
        let row = COMMANDS.iter().find(|row| row.wire == wire).expect(wire);
        assert!(row.class.may_wait(), "{wire} waits but is {}", row.class.as_str());
        assert_ne!(row.class, MethodClass::Query, "{wire} is not a plain read");
    }
}

#[test]
fn command_names_method_classes_are_complete_and_bounded() {
    let names: BTreeSet<_> = MethodClass::ALL.iter().map(|class| class.as_str()).collect();
    assert_eq!(names.len(), MethodClass::ALL.len());
    for class in MethodClass::ALL {
        // An exhaustive match: a new class fails here until ALL has it.
        let listed = match class {
            MethodClass::Topology
            | MethodClass::TerminalIo
            | MethodClass::Create
            | MethodClass::Query
            | MethodClass::Browser
            | MethodClass::Agent
            | MethodClass::Cloud
            | MethodClass::Other => MethodClass::ALL.contains(&class),
        };
        assert!(listed);
        let deadline = class.hang_deadline();
        assert!(deadline.as_secs() >= 1 && deadline.as_secs() <= 10, "{}", class.as_str());
        if !class.may_wait() {
            assert!(deadline.as_secs() <= 2, "{} never waits", class.as_str());
        }
        assert!(COMMANDS.iter().any(|row| row.class == class), "{} has no command", class.as_str());
    }
}
