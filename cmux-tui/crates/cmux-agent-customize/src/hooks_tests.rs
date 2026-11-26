use std::fs;
use std::path::Path;

use super::*;

struct Fixture {
    _root: tempfile::TempDir,
    paths: AgentPaths,
}

const CLAUDE_SETTINGS: &str = r#"{
  "env": {
    "FOO": "bar"
  },
  "permissions": {
    "allow": []
  },
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "guard-one"
          },
          {
            "type": "command",
            "command": "guard-two",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CMUX_TUI_HOOK:-:}\" claude Stop 2>/dev/null||:;echo {};#cmux-tui-journal-hook"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "status"
  },
  "alwaysThinkingEnabled": true
}
"#;

fn fixture() -> Fixture {
    let root = tempfile::tempdir().unwrap();
    let base = root.path().canonicalize().unwrap();
    let claude = base.join("claude");
    let codex = base.join("codex");
    let project = base.join("project");
    fs::create_dir_all(&claude).unwrap();
    fs::create_dir_all(&codex).unwrap();
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(claude.join("settings.json"), CLAUDE_SETTINGS).unwrap();
    fs::write(
        project.join(".claude/settings.local.json"),
        r#"{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"project-start"}]}]}}"#,
    )
    .unwrap();
    fs::write(
        codex.join("hooks.json"),
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "codex-a" },
          { "type": "command", "command": "codex-b", "timeout": 30 }
        ]
      },
      {
        "hooks": [ { "type": "command", "command": "codex-c" } ]
      }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/home/x/.cmux/hooks/cmux-codex-hook-1-persistent-stop.sh" } ] }
    ]
  }
}
"#,
    )
    .unwrap();
    let paths = AgentPaths {
        claude_dir: claude,
        codex_home: codex.clone(),
        codex_home_from_env: false,
        project: Some(project),
        claude_plugin_dirs: Vec::new(),
        store_dir: base.join("store"),
        edits: crate::write::Store::new(base.join("state")),
    };
    // Trust every Codex hook as it stands, the way codex's /hooks review does.
    let listing = list(&paths);
    let mut config =
        String::from("# my codex config\nmodel = \"gpt-5\"\n\n[features]\nhooks = true\n");
    for hook in listing.hooks.iter().filter(|hook| hook.agent == Agent::Codex) {
        config.push_str(&format!(
            "\n[hooks.state.\"{}\"]\ntrusted_hash = \"{}\"\n",
            hook.state_key.as_ref().unwrap(),
            codex_hash(hook).unwrap()
        ));
    }
    config.push_str("\n[profiles.fast]\nmodel = \"gpt-5-mini\" # keep\n");
    fs::write(codex.join("config.toml"), config).unwrap();
    Fixture { _root: root, paths }
}

fn by_command<'a>(listing: &'a HookList, command: &str) -> &'a HookEntry {
    listing
        .hooks
        .iter()
        .find(|hook| hook.command == command)
        .unwrap_or_else(|| panic!("no hook {command}"))
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap()
}

#[test]
fn list_shows_every_hook_with_scope_owner_and_trust() {
    let fixture = fixture();
    let listing = list(&fixture.paths);
    assert_eq!(listing.count(Agent::Claude), 4);
    assert_eq!(listing.count(Agent::Codex), 4);
    assert_eq!(listing.codex_hooks_feature, Some(true));
    let journal = listing
        .hooks
        .iter()
        .find(|hook| hook.agent == Agent::Claude && hook.event == "Stop")
        .unwrap();
    assert_eq!(journal.owner, Owner::Cmux);
    assert!(journal.read_only);
    let stop = listing
        .hooks
        .iter()
        .find(|hook| hook.agent == Agent::Codex && hook.event == "Stop")
        .unwrap();
    assert_eq!(stop.owner, Owner::Cmux);
    let project = by_command(&listing, "project-start");
    assert_eq!(project.scope, Scope::ProjectLocal);
    assert_eq!(project.matcher.as_deref(), Some("startup"));
    let b = by_command(&listing, "codex-b");
    assert_eq!(b.trust, Some("trusted"));
    assert_eq!(b.timeout, Some(30));
    assert!(b.state_key.as_ref().unwrap().ends_with("hooks.json:pre_tool_use:0:1"));
    // Ids are unique.
    let mut ids: Vec<_> = listing.hooks.iter().map(|hook| hook.id.clone()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), listing.hooks.len());
}

#[test]
fn claude_disable_parks_the_handler_and_enable_restores_the_file_byte_for_byte() {
    let fixture = fixture();
    let settings = fixture.paths.claude_dir.join("settings.json");
    let id = by_command(&list(&fixture.paths), "guard-one").id.clone();
    let hook = set_enabled(&fixture.paths, &id, false, false).unwrap();
    assert!(!hook.enabled);
    let text = read(&settings);
    assert!(!text.contains("guard-one"));
    assert!(text.contains("guard-two"));
    // Unrelated keys keep their order.
    let order: Vec<_> = [
        "\"env\"",
        "\"permissions\"",
        "\"model\"",
        "\"hooks\"",
        "\"statusLine\"",
        "\"alwaysThinkingEnabled\"",
    ]
    .iter()
    .map(|key| text.find(key).unwrap())
    .collect();
    assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{text}");
    assert!(read(&disabled_store_path(&fixture.paths)).contains("guard-one"));
    // Same id, listed as disabled.
    let listed = list(&fixture.paths);
    assert_eq!(listed.count(Agent::Claude), 4);
    assert!(!by_command(&listed, "guard-one").enabled);
    set_enabled(&fixture.paths, &id, true, false).unwrap();
    assert_eq!(read(&settings), CLAUDE_SETTINGS);
    assert!(!read(&disabled_store_path(&fixture.paths)).contains("guard-one"));
    // The prior file is backed up in the shared store, as a settings edit backs it up: the
    // original before cmux's first edit, and the file before its latest one.
    assert_eq!(read(&fixture.paths.edits.backup_path(&settings)), CLAUDE_SETTINGS);
    assert!(fixture.paths.edits.last_backup_path(&settings).exists());
}

#[test]
fn a_hooks_edit_waits_for_a_settings_edit_of_the_same_file() {
    let fixture = fixture();
    let settings = fixture.paths.claude_dir.join("settings.json");
    let id = by_command(&list(&fixture.paths), "guard-one").id.clone();
    // A settings edit holds the file's lock (crate::settings takes Store::lock the same way).
    let held = fixture.paths.edits.lock(&settings).unwrap();
    let paths = fixture.paths;
    let waiting = std::thread::spawn(move || set_enabled(&paths, &id, false, false));
    std::thread::sleep(std::time::Duration::from_millis(300));
    // The hooks edit has not written while the lock is held.
    assert_eq!(read(&settings), CLAUDE_SETTINGS);
    drop(held);
    let hook = waiting.join().unwrap().unwrap();
    assert!(!hook.enabled);
    assert!(!read(&settings).contains("guard-one"));
}

#[test]
fn claude_disable_of_a_whole_group_and_back() {
    let fixture = fixture();
    let settings = fixture.paths.claude_dir.join("settings.json");
    for command in ["guard-one", "guard-two"] {
        let id = by_command(&list(&fixture.paths), command).id.clone();
        set_enabled(&fixture.paths, &id, false, false).unwrap();
    }
    assert!(!read(&settings).contains("PreToolUse"));
    for command in ["guard-one", "guard-two"] {
        let id = by_command(&list(&fixture.paths), command).id.clone();
        set_enabled(&fixture.paths, &id, true, false).unwrap();
    }
    let root = OJson::parse(&read(&settings)).unwrap();
    let handlers = root.get("hooks").unwrap().get("PreToolUse").unwrap().as_array().unwrap()[0]
        .get("hooks")
        .unwrap()
        .as_array()
        .unwrap()
        .clone();
    let commands: Vec<_> = handlers
        .iter()
        .map(|handler| handler.get("command").unwrap().as_str().unwrap().to_owned())
        .collect();
    assert_eq!(commands, ["guard-one", "guard-two"]);
}

#[test]
fn cmux_hooks_refuse_edits_unless_allowed() {
    let fixture = fixture();
    let listing = list(&fixture.paths);
    let journal = listing
        .hooks
        .iter()
        .find(|hook| hook.owner == Owner::Cmux && hook.agent == Agent::Claude)
        .unwrap();
    let error = set_enabled(&fixture.paths, &journal.id, false, false).unwrap_err();
    assert!(error.to_string().contains("--allow-cmux"), "{error}");
    assert!(remove(&fixture.paths, &journal.id, false).is_err());
    set_enabled(&fixture.paths, &journal.id, false, true).unwrap();
    set_enabled(&fixture.paths, &journal.id, true, true).unwrap();
    assert_eq!(read(&fixture.paths.claude_dir.join("settings.json")), CLAUDE_SETTINGS);
}

#[test]
fn codex_disable_writes_enabled_false_and_enable_takes_it_out() {
    let fixture = fixture();
    let config = fixture.paths.codex_home.join("config.toml");
    let before = read(&config);
    let id = by_command(&list(&fixture.paths), "codex-b").id.clone();
    set_enabled(&fixture.paths, &id, false, false).unwrap();
    let text = read(&config);
    assert!(text.contains("enabled = false"), "{text}");
    assert!(text.contains("# my codex config") && text.contains("# keep"));
    assert!(!by_command(&list(&fixture.paths), "codex-b").enabled);
    set_enabled(&fixture.paths, &id, true, false).unwrap();
    assert_eq!(read(&config), before);
}

#[test]
fn codex_disable_enable_without_a_state_entry_gives_back_the_file() {
    let fixture = fixture();
    let config = fixture.paths.codex_home.join("config.toml");
    let id = by_command(&list(&fixture.paths), "codex-b").id.clone();
    // No state entry for any hook: with other hooks tables, and with none at all.
    for before in [
        "# my codex config\nmodel = \"gpt-5\"\n\n[hooks]\nfoo = 1\n\n[profiles.fast]\nmodel = \"gpt-5-mini\" # keep\n",
        "# my codex config\nmodel = \"gpt-5\"\n\n[features]\nhooks = true\n\n[profiles.fast]\nmodel = \"gpt-5-mini\" # keep\n",
    ] {
        fs::write(&config, before).unwrap();
        set_enabled(&fixture.paths, &id, false, false).unwrap();
        let text = read(&config);
        assert!(text.contains("enabled = false"), "{text}");
        assert!(!by_command(&list(&fixture.paths), "codex-b").enabled);
        set_enabled(&fixture.paths, &id, true, false).unwrap();
        assert_eq!(read(&config), before);
        assert!(by_command(&list(&fixture.paths), "codex-b").enabled);
    }
}

#[test]
fn codex_add_appends_a_trusted_group() {
    let fixture = fixture();
    let hook = add(
        &fixture.paths,
        &NewHook {
            agent: Agent::Codex,
            scope: Scope::User,
            event: "SessionStart".into(),
            matcher: Some("startup".into()),
            command: "echo hi".into(),
            timeout: Some(9),
        },
    )
    .unwrap();
    assert_eq!(hook.trust, Some("trusted"));
    assert!(hook.enabled);
    assert_eq!(hook.owner, Owner::User);
    assert!(read(&fixture.paths.codex_home.join("hooks.json")).contains("echo hi"));
    // Every earlier hook keeps its trust.
    assert!(
        list(&fixture.paths)
            .hooks
            .iter()
            .filter(|hook| hook.agent == Agent::Codex)
            .all(|hook| hook.trust == Some("trusted"))
    );
}

#[test]
fn codex_remove_moves_later_handlers_state_with_them() {
    let fixture = fixture();
    // Disable codex-c (group 1) first, so its state is not just a hash.
    let c = by_command(&list(&fixture.paths), "codex-c").id.clone();
    set_enabled(&fixture.paths, &c, false, false).unwrap();
    let a = by_command(&list(&fixture.paths), "codex-a").id.clone();
    remove(&fixture.paths, &a, false).unwrap();
    let listing = list(&fixture.paths);
    assert_eq!(listing.count(Agent::Codex), 3);
    let b = by_command(&listing, "codex-b");
    assert!(b.state_key.as_ref().unwrap().ends_with(":pre_tool_use:0:0"));
    assert_eq!(b.trust, Some("trusted"));
    let c_entry = by_command(&listing, "codex-c");
    assert!(!c_entry.enabled);
    assert_eq!(c_entry.trust, Some("trusted"));
    // Now empty group 0 entirely: codex-c moves to group 0.
    remove(&fixture.paths, &b.id.clone(), false).unwrap();
    let listing = list(&fixture.paths);
    let c_entry = by_command(&listing, "codex-c");
    assert!(c_entry.state_key.as_ref().unwrap().ends_with(":pre_tool_use:0:0"));
    assert!(!c_entry.enabled);
    assert_eq!(c_entry.trust, Some("trusted"));
}

#[test]
fn claude_add_and_remove_round_trip() {
    let fixture = fixture();
    let settings = fixture.paths.claude_dir.join("settings.json");
    let hook = add(
        &fixture.paths,
        &NewHook {
            agent: Agent::Claude,
            scope: Scope::User,
            event: "PostToolUse".into(),
            matcher: Some("Write|Edit".into()),
            command: "fmt".into(),
            timeout: None,
        },
    )
    .unwrap();
    assert_eq!(hook.matcher.as_deref(), Some("Write|Edit"));
    assert!(read(&settings).contains("\"fmt\""));
    remove(&fixture.paths, &hook.id, false).unwrap();
    assert_eq!(read(&settings), CLAUDE_SETTINGS);
}

#[test]
fn add_refuses_unknown_events_and_missing_project() {
    let fixture = fixture();
    let mut new = NewHook {
        agent: Agent::Codex,
        scope: Scope::User,
        event: "Notification".into(),
        matcher: None,
        command: "x".into(),
        timeout: None,
    };
    assert!(add(&fixture.paths, &new).is_err());
    new.agent = Agent::Claude;
    new.scope = Scope::Project;
    let mut no_project = fixture.paths;
    no_project.project = None;
    assert!(add(&no_project, &new).is_err());
}

#[test]
fn a_hook_changed_on_disk_after_listing_is_not_removed() {
    let fixture = fixture();
    let settings = fixture.paths.claude_dir.join("settings.json");
    let id = by_command(&list(&fixture.paths), "guard-one").id.clone();
    fs::write(&settings, CLAUDE_SETTINGS.replace("guard-one", "guard-zero")).unwrap();
    assert!(remove(&fixture.paths, &id, false).is_err());
}

/// Turning every hook off and back on, in any order, leaves the file as it
/// was, even with two groups of one matcher (where "the first group with that
/// matcher" would merge them) and events that empty out.
#[test]
fn claude_disable_enable_any_order_round_trips() {
    const SETTINGS: &str = r#"{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "a" }, { "type": "command", "command": "b" } ] },
      { "hooks": [ { "type": "command", "command": "c" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "d" } ] }
    ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "e" } ] } ],
    "PostToolUse": [ { "hooks": [ { "type": "command", "command": "f" } ] } ]
  },
  "theme": "dark"
}
"#;
    let commands = ["a", "b", "c", "d", "e", "f"];
    // Disable orders x enable orders: forward, reverse, and two interleavings.
    let orders: [[usize; 6]; 4] =
        [[0, 1, 2, 3, 4, 5], [5, 4, 3, 2, 1, 0], [1, 3, 0, 5, 2, 4], [2, 0, 4, 1, 5, 3]];
    for disable_order in &orders {
        for enable_order in &orders {
            let fixture = fixture();
            let paths = AgentPaths { project: None, ..fixture.paths };
            let file = paths.claude_dir.join("settings.json");
            fs::write(&file, SETTINGS).unwrap();
            let normalized = OJson::parse(SETTINGS).unwrap().to_pretty();
            fs::write(&file, &normalized).unwrap();
            for &at in disable_order {
                let listing = list(&paths);
                let id = by_command(&listing, commands[at]).id.clone();
                set_enabled(&paths, &id, false, false).unwrap();
            }
            let off = fs::read_to_string(&file).unwrap();
            assert!(!commands.iter().any(|c| off.contains(&format!("\"command\": \"{c}\""))));
            assert!(off.contains("\"hooks\": {}"), "{off}");
            for &at in enable_order {
                let listing = list(&paths);
                let id = by_command(&listing, commands[at]).id.clone();
                set_enabled(&paths, &id, true, false).unwrap();
            }
            assert_eq!(
                fs::read_to_string(&file).unwrap(),
                normalized,
                "disable {disable_order:?} then enable {enable_order:?}"
            );
            assert!(read_disabled_store(&disabled_store_path(&paths)).unwrap().is_empty());
        }
    }
}

/// Adding a hook to a file with no `hooks` and removing it leaves the file
/// byte for byte as it was (no `"hooks": {}` left behind).
#[test]
fn claude_add_remove_into_file_without_hooks() {
    let fixture = fixture();
    let paths = AgentPaths { project: None, ..fixture.paths };
    let file = paths.claude_dir.join("settings.json");
    let before = "{\n  \"model\": \"opus\",\n  \"theme\": \"dark\"\n}\n";
    fs::write(&file, before).unwrap();
    let new = NewHook {
        agent: Agent::Claude,
        scope: Scope::User,
        event: "UserPromptSubmit".into(),
        matcher: None,
        command: "echo hi".into(),
        timeout: None,
    };
    let hook = add(&paths, &new).unwrap();
    set_enabled(&paths, &hook.id, false, false).unwrap();
    let listing = list(&paths);
    let id = by_command(&listing, "echo hi").id.clone();
    set_enabled(&paths, &id, true, false).unwrap();
    let listing = list(&paths);
    let id = by_command(&listing, "echo hi").id.clone();
    remove(&paths, &id, false).unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), before);
}
