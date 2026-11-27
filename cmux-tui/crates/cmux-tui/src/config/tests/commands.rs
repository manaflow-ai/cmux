//! Tests for user commands and the action catalog.

use super::*;

#[test]
fn raw_config_accepts_commands_section() {
    let raw: RawConfig = serde_json::from_value(json!({
        "commands": [
            {"id": "lazygit", "name": "LazyGit", "keys": "g", "run": ["lazygit"]},
            {"id": "scratch", "keys": ["alt+s"], "run": ["nvim", "/tmp/scratch.md"], "cwd": "/tmp"}
        ]
    }))
    .unwrap();
    assert_eq!(raw.commands.len(), 2);
}

#[test]
fn user_commands_bind_chords_and_resolve() {
    let mut keys = Keys::default();
    let raw = vec![
        RawUserCommand {
            id: Some("lazygit".to_string()),
            name: Some("LazyGit".to_string()),
            keys: Some(Value::String("g".to_string())),
            run: Some(vec!["lazygit".to_string()]),
            cwd: None,
        },
        RawUserCommand {
            id: Some("scratch".to_string()),
            name: None,
            // The prefix chord is reserved, so only alt+s binds.
            keys: Some(json!(["alt+s", "ctrl+b"])),
            run: Some(vec!["nvim".to_string(), "/tmp/scratch.md".to_string()]),
            cwd: Some("/tmp".to_string()),
        },
        RawUserCommand {
            id: Some("lazygit".to_string()),
            name: None,
            keys: Some(Value::String("y".to_string())),
            run: Some(vec!["true".to_string()]),
            cwd: None,
        },
        RawUserCommand {
            id: Some("empty-run".to_string()),
            name: None,
            keys: Some(Value::String("e".to_string())),
            run: Some(Vec::new()),
            cwd: None,
        },
        RawUserCommand {
            id: None,
            name: None,
            keys: Some(Value::String("i".to_string())),
            run: Some(vec!["true".to_string()]),
            cwd: None,
        },
    ];
    let (commands, key_values) = resolve_user_command_specs(raw);
    bind_user_command_chords(&mut keys, &commands, &key_values);
    assert_eq!(commands.len(), 2);
    assert_eq!(commands[0].id, "lazygit");
    // An ignored invalid entry does not reserve its id: a later valid
    // entry with the same id is accepted.
    let mut keys_retry = Keys::default();
    let retry = vec![
        RawUserCommand {
            id: Some("retry".to_string()),
            name: None,
            keys: None,
            run: Some(Vec::new()),
            cwd: None,
        },
        RawUserCommand {
            id: Some("retry".to_string()),
            name: None,
            keys: None,
            run: Some(vec!["true".to_string()]),
            cwd: Some("   ".to_string()),
        },
    ];
    let (retried, retried_keys) = resolve_user_command_specs(retry);
    bind_user_command_chords(&mut keys_retry, &retried, &retried_keys);
    assert_eq!(retried.len(), 1);
    assert_eq!(retried[0].id, "retry");
    assert_eq!(retried[0].cwd, None, "blank cwd is treated as absent");
    assert_eq!(commands[0].name, "LazyGit");
    assert_eq!(commands[0].run, ["lazygit"]);
    assert_eq!(commands[1].name, "scratch");
    assert_eq!(commands[1].cwd.as_deref(), Some("/tmp"));

    let lazygit = Action::user_command(0).unwrap();
    let scratch = Action::user_command(1).unwrap();
    // An explicit command chord steals the default chord it collides with.
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('g'), KeyModifiers::NONE)),
        Some(lazygit)
    );
    assert_eq!(keys.shortcut_labels(Action::NewPaneRight), Vec::<String>::new());
    // Alt chords are modeless, exactly like built-in Alt bindings.
    assert_eq!(
        keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('s'), KeyModifiers::ALT)),
        Some(scratch)
    );
    // The prefix chord stays reserved for send-prefix.
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)),
        Some(Action::SendPrefix)
    );
    // Rejected chords do not bind: `y`, `e`, and `i` keep their defaults.
    assert_ne!(
        keys.action_for(&KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE)),
        Some(Action::user_command(2).unwrap())
    );
    assert_eq!(keys.shortcut_labels(lazygit), ["Ctrl-b g"]);
    assert_eq!(keys.shortcut_labels(scratch), ["Alt-s"]);
}

#[test]
fn user_commands_stop_at_the_command_limit() {
    let mut keys = Keys::default();
    let raw = (0..MAX_USER_COMMANDS + 2)
        .map(|index| RawUserCommand {
            id: Some(format!("command-{index}")),
            name: None,
            keys: None,
            run: Some(vec!["true".to_string()]),
            cwd: None,
        })
        .collect();
    let (commands, key_values) = resolve_user_command_specs(raw);
    bind_user_command_chords(&mut keys, &commands, &key_values);
    assert_eq!(commands.len(), MAX_USER_COMMANDS);
    assert!(Action::user_command(MAX_USER_COMMANDS).is_none());
}

#[test]
fn default_backtab_accepts_crossterm_implied_shift() {
    let keys = Keys::default();
    assert_eq!(
        keys.action_for(&KeyEvent::new(KeyCode::BackTab, KeyModifiers::SHIFT)),
        Some(Action::PrevTab)
    );
}

#[test]
fn action_catalog_has_unique_actions_keys_and_complete_localized_labels() {
    let mut actions = HashSet::new();
    let mut keys = HashSet::new();
    for &definition in action_definitions() {
        assert!(actions.insert(definition.action), "duplicate action: {:?}", definition.action);
        assert!(keys.insert(definition.config_key), "duplicate key: {}", definition.config_key);
        assert!(!definition.label_en.is_empty());
        assert!(!definition.label_ja.is_empty());
        assert_eq!(definition.action.definition(), definition);
        let metadata = definition.action.metadata();
        let metadata_key = metadata.key;
        let _execution = metadata.execution();
        let resolved_metadata_key = match definition.action {
            Action::SelectTab(index) | Action::SelectScreen(index) => {
                metadata_key.replace("{number}", &index.get().to_string())
            }
            _ => metadata_key.to_string(),
        };
        assert_eq!(
            resolved_metadata_key, definition.config_key,
            "action catalog and programmability metadata disagree for {:?}",
            definition.action
        );
    }
    for (_, action) in Keys::default().bindings {
        assert!(actions.contains(&action), "default binding is not registered: {action:?}");
    }
    assert!(actions.contains(&Action::NewPaneSmart));
    assert!(actions.contains(&Action::ShowShortcuts));
}

#[test]
fn every_catalog_action_can_be_rebound() {
    for &definition in action_definitions() {
        let mut keys = Keys::default();
        let mut raw = HashMap::new();
        raw.insert(definition.config_key.to_string(), Value::String("f".to_string()));
        keys.apply(&raw);

        assert_eq!(
            keys.action_for(&KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
            Some(definition.action),
            "{} did not rebind through the central action catalog",
            definition.config_key
        );
    }
}
