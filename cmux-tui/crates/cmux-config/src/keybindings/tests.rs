use serde_json::json;

use super::edit::{self, Target};
use super::{Problem, parse, stroke};

const FILE: &str = r#"// my keys
[
  // save all
  { "key": "ctrl+k s", "command": "save" },
  { "key": "cmd+r", "command": "-renameTab" },
  { "key": "nope+x", "command": "bad" },
  { "key": "ctrl+tab", "command": "nextSurface", "when": "surfaceKind != terminal", "args": { "n": 1 } }
]
"#;

fn target(command: &str, key: &str, when: Option<&str>) -> Target {
    Target { command: command.into(), key: key.into(), when: when.map(Into::into) }
}

#[test]
fn strokes_normalize_like_the_app_parser() {
    assert_eq!(stroke::normalize("Ctrl+Shift+Cmd+P").as_deref(), Some("cmd+shift+ctrl+p"));
    assert_eq!(stroke::normalize("alt+ArrowLeft").as_deref(), Some("opt+left"));
    assert_eq!(stroke::normalize("cmd++").as_deref(), Some("cmd+plus"));
    assert_eq!(stroke::normalize("f5").as_deref(), Some("f5"));
    assert_eq!(stroke::normalize("ctrl+PageDown").as_deref(), Some("ctrl+pagedown"));
    assert_eq!(stroke::normalize("hyper+x"), None);
    assert_eq!(stroke::normalize("ctrl+ab"), None);
    assert_eq!(stroke::normalize("f21"), None);
}

#[test]
fn every_vector_key_is_a_valid_stroke() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../schemas/keybindings/keybinding-vectors.json"
    );
    let vectors: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    for vector in vectors["vectors"].as_array().unwrap() {
        for key in vector["keys"].as_array().unwrap() {
            let key = key.as_str().unwrap();
            assert!(stroke::normalize(key).is_some(), "{key}");
        }
        for binding in vector["bindings"]
            .as_array()
            .into_iter()
            .flatten()
            .chain(vector["removals"].as_array().into_iter().flatten())
        {
            for part in binding["key"].as_str().unwrap().split_whitespace() {
                assert!(stroke::normalize(part).is_some(), "{part}");
            }
        }
    }
}

#[test]
fn a_bad_entry_is_left_out_and_the_others_load() {
    let parsed = parse(FILE);
    assert_eq!(parsed.entries.len(), 3);
    assert_eq!(parsed.entries[0].keys, vec!["ctrl+k", "s"]);
    assert!(parsed.entries[1].removal);
    assert_eq!(parsed.entries[1].command, "renameTab");
    assert_eq!(parsed.entries[2].index, 3);
    assert_eq!(parsed.entries[2].when.as_deref(), Some("surfaceKind != terminal"));
    assert_eq!(parsed.entries[2].args, Some(json!({ "n": 1 })));
    assert_eq!(parsed.diagnostics.len(), 1);
    assert_eq!(parsed.diagnostics[0].index, Some(2));
    assert_eq!(parsed.diagnostics[0].problem, Problem::InvalidKey);
}

#[test]
fn entry_problems_are_named() {
    let problems = |text: &str| {
        parse(text).diagnostics.iter().map(|diagnostic| diagnostic.problem).collect::<Vec<_>>()
    };
    assert_eq!(problems("[1]"), vec![Problem::NotAnObject]);
    assert_eq!(problems(r#"[{"key": "ctrl+k"}]"#), vec![Problem::MissingCommand]);
    assert_eq!(problems(r#"[{"command": "x"}]"#), vec![Problem::MissingKey]);
    assert_eq!(
        problems(r#"[{"key": "ctrl+a b c d e", "command": "x"}]"#),
        vec![Problem::TooManyKeys]
    );
    assert_eq!(
        problems(r#"[{"key": "k", "command": "x"}]"#),
        vec![Problem::FirstKeyNeedsCommandOrControl]
    );
    assert_eq!(
        problems(r#"[{"key": "ctrl+k", "command": "x", "when": 3}]"#),
        vec![Problem::InvalidWhen]
    );
    assert_eq!(
        problems(r#"[{"key": "ctrl+k", "command": "x", "args": [1]}]"#),
        vec![Problem::InvalidArgs]
    );
    assert_eq!(problems(r#"{"key": "ctrl+k"}"#), vec![Problem::UnreadableFile]);
    assert_eq!(problems("[ {"), vec![Problem::UnreadableFile]);
    assert!(parse("").entries.is_empty() && parse("// nothing\n").diagnostics.is_empty());
    assert!(
        parse(r#"[{"command": "-x"}]"#).entries[0].keys.is_empty(),
        "a removal without keys removes every key"
    );
}

#[test]
fn set_appends_and_keeps_comments() {
    let out =
        edit::set(FILE, &target("toggleSidebar", "Ctrl+K  ctrl+B", None), None, None).unwrap();
    assert!(out.starts_with("// my keys\n[\n  // save all\n"));
    let parsed = parse(&out);
    let last = parsed.entries.last().unwrap();
    assert_eq!(
        (last.command.as_str(), last.keys.clone()),
        ("toggleSidebar", vec!["ctrl+k".to_string(), "ctrl+b".to_string()])
    );
    assert_eq!(parsed.diagnostics.len(), 1, "the bad entry stays as the user wrote it");
}

#[test]
fn set_with_replaces_edits_the_users_entry_or_removes_a_default() {
    let own = edit::set(
        FILE,
        &target("save", "ctrl+k ctrl+s", None),
        None,
        Some(&target("save", "ctrl+k s", None)),
    )
    .unwrap();
    let parsed = parse(&own);
    assert_eq!(parsed.entries[0].keys, vec!["ctrl+k", "ctrl+s"], "replaced in place");
    assert_eq!(parsed.entries.len(), 3);
    assert!(own.contains("// save all"));

    let default = edit::set(
        FILE,
        &target("closeTab", "ctrl+w", None),
        None,
        Some(&target("closeTab", "cmd+w", None)),
    )
    .unwrap();
    let parsed = parse(&default);
    let tail: Vec<_> = parsed
        .entries
        .iter()
        .rev()
        .take(2)
        .map(|entry| (entry.command.clone(), entry.removal))
        .collect();
    assert_eq!(tail, vec![("closeTab".to_string(), false), ("closeTab".to_string(), true)]);
}

#[test]
fn remove_and_reset() {
    let removed = edit::remove(FILE, &target("save", "ctrl+k s", None)).unwrap();
    assert!(parse(&removed).entries.iter().all(|entry| entry.command != "save"));
    assert!(!removed.contains("\"save\""));

    let default = edit::remove(FILE, &target("closeTab", "cmd+w", None)).unwrap();
    assert!(parse(&default).entries.last().unwrap().removal);

    let reset = edit::reset(&default, "closeTab").unwrap();
    assert_eq!(parse(&reset).entries, parse(FILE).entries);
    let reset_all = edit::reset(FILE, "renameTab").unwrap();
    assert!(parse(&reset_all).entries.iter().all(|entry| entry.command != "renameTab"));
}

#[test]
fn edits_start_an_empty_file_and_refuse_an_unreadable_one() {
    let out =
        edit::set("", &target("x", "cmd+k", None), Some(&json!({ "a": true })), None).unwrap();
    assert_eq!(parse(&out).entries[0].args, Some(json!({ "a": true })));
    let out = edit::set("[]", &target("x", "cmd+k", Some("a && b")), None, None).unwrap();
    assert_eq!(parse(&out).entries[0].when.as_deref(), Some("a && b"));
    assert!(matches!(
        edit::set("{", &target("x", "cmd+k", None), None, None),
        Err(edit::EditError::Unreadable(_))
    ));
    assert!(matches!(
        edit::set("[]", &target("x", "hyper+k", None), None, None),
        Err(edit::EditError::InvalidKey(_))
    ));
}
