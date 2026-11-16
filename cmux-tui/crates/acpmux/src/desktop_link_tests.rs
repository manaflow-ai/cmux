//! `acpmux desktop link`: each app's entry over a scratch home.

use super::*;

/// A scratch home where Claude desktop and Codex are installed (their config folders exist) and
/// Claude Code's CLI is `claude_cli`.
fn env(dir: &Path, claude_cli: Option<PathBuf>) -> Env {
    let env = Env {
        home: dir.to_path_buf(),
        claude_config_dir: None,
        codex_home: None,
        xdg_config_home: None,
        pi_dir: None,
        gemini_home: None,
        exe: PathBuf::from("/opt/cmux/bin/acpmux"),
        args: vec!["acpmux-mcp".to_owned()],
        acpmux_home: None,
        claude_cli,
    };
    std::fs::create_dir_all(env.config_path(App::ClaudeDesktop).parent().unwrap()).unwrap();
    std::fs::create_dir_all(env.config_path(App::Codex).parent().unwrap()).unwrap();
    env
}

#[test]
fn every_app_has_an_id_the_cli_takes_back() {
    for app in App::ALL {
        assert_eq!(App::parse(app.id()), Some(app));
    }
    assert_eq!(apps(None).unwrap(), App::ALL.to_vec());
    assert_eq!(apps(Some("codex")).unwrap(), vec![App::Codex]);
    assert!(
        apps(Some("chat")).unwrap_err().to_string().contains("claude-desktop, claude-code, codex")
    );
}

#[test]
fn claude_desktop_gets_the_entry_beside_the_persons_own_servers() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    std::fs::write(
        &path,
        r#"{"mcpServers": {"files": {"command": "npx", "args": ["fs"]}}, "globalShortcut": "Alt+Space"}"#,
    )
    .unwrap();
    assert_eq!(status(&env, App::ClaudeDesktop).state, State::NotLinked);
    let dry = link(&env, App::ClaudeDesktop, true);
    assert_eq!((dry.state, dry.note.as_deref()), (State::NotLinked, Some("would link")));

    let row = link(&env, App::ClaudeDesktop, false);
    assert_eq!(row.state, State::Linked, "{:?}", row.note);
    assert!(row.note.unwrap().contains("reopen Claude desktop"));
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(doc["globalShortcut"], "Alt+Space");
    assert_eq!(doc["mcpServers"]["files"]["command"], "npx");
    let entry = &doc["mcpServers"]["cmux"];
    assert_eq!(entry["command"], "/opt/cmux/bin/acpmux");
    assert_eq!(entry["args"], json!(["acpmux-mcp"]));
    assert_eq!(entry["env"][GUEST_ENV], "claude-desktop");
    assert_eq!(link(&env, App::ClaudeDesktop, false).note.as_deref(), Some("already linked"));

    let row = unlink(&env, App::ClaudeDesktop, false);
    assert_eq!(row.state, State::NotLinked);
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(doc["mcpServers"].get("cmux").is_none());
    assert_eq!(doc["mcpServers"]["files"]["command"], "npx");
}

#[test]
fn claude_desktop_keeps_the_persons_key_order() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    std::fs::write(
        &path,
        r#"{"zoom": 1, "mcpServers": {"zeta": {"command": "z"}, "files": {"command": "f"}}, "alpha": true}"#,
    )
    .unwrap();
    let at = |text: &str, key: &str| text.find(&format!("\"{key}\"")).unwrap();
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(at(&text, "zoom") < at(&text, "mcpServers"), "{text}");
    assert!(at(&text, "mcpServers") < at(&text, "alpha"), "{text}");
    assert!(at(&text, "zeta") < at(&text, "files"), "{text}");
    assert!(at(&text, "files") < at(&text, "cmux"), "{text}");

    assert_eq!(unlink(&env, App::ClaudeDesktop, false).state, State::NotLinked);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(!text.contains("\"cmux\""), "{text}");
    assert!(at(&text, "zoom") < at(&text, "mcpServers"), "{text}");
    assert!(at(&text, "zeta") < at(&text, "files"), "{text}");
    let doc: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        doc,
        json!({"zoom": 1, "mcpServers": {"zeta": {"command": "z"}, "files": {"command": "f"}}, "alpha": true})
    );
}

#[test]
fn the_cmux_binary_runs_the_server_under_its_acp_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    let me = crate::self_command::SelfCommand::new(
        PathBuf::from("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"),
        vec!["acp".into()],
    );
    env.args = me.args_lossy(&["acpmux-mcp"]);
    env.exe = me.exe;
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    let doc: toml::Table =
        toml::from_str(&std::fs::read_to_string(env.config_path(App::Codex)).unwrap()).unwrap();
    let args: Vec<&str> = doc["mcp_servers"]["cmux"]["args"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|a| a.as_str())
        .collect();
    assert_eq!(args, ["acp", "acpmux-mcp"]);
    // The same binary under its own name has no prefix: that entry is another binary's.
    env.args = vec!["acpmux-mcp".to_owned()];
    assert_eq!(status(&env, App::Codex).state, State::Stale);
}

#[test]
fn a_missing_config_file_is_made_with_only_the_entry() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    let doc: Value = serde_json::from_str(
        &std::fs::read_to_string(env.config_path(App::ClaudeDesktop)).unwrap(),
    )
    .unwrap();
    assert_eq!(doc["mcpServers"].as_object().unwrap().len(), 1);
}

#[test]
fn an_entry_cmux_did_not_write_is_never_replaced_or_removed() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    let mine = r#"{"mcpServers": {"cmux": {"command": "/usr/local/bin/my-cmux", "args": []}}}"#;
    std::fs::write(&path, mine).unwrap();
    assert_eq!(status(&env, App::ClaudeDesktop).state, State::Foreign);
    let row = link(&env, App::ClaudeDesktop, false);
    assert_eq!(row.state, State::Foreign);
    assert!(row.note.unwrap().contains("left alone"));
    assert_eq!(unlink(&env, App::ClaudeDesktop, false).state, State::Foreign);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), mine);
}

#[test]
fn an_entry_of_ours_for_another_binary_is_stale_and_relinked() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    env.exe = PathBuf::from("/Applications/cmux NEXT.app/Contents/Resources/bin/acpmux");
    assert_eq!(status(&env, App::ClaudeDesktop).state, State::Stale);
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    let doc: Value = serde_json::from_str(
        &std::fs::read_to_string(env.config_path(App::ClaudeDesktop)).unwrap(),
    )
    .unwrap();
    assert_eq!(doc["mcpServers"]["cmux"]["command"], env.exe.to_string_lossy().as_ref());
}

/// Review F4 (#39320): an entry for another acpmux home reaches another daemon, so it is stale
/// and link points it at this one.
#[test]
fn an_entry_for_another_acpmux_home_is_stale_and_relinked() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    env.acpmux_home = Some(PathBuf::from("/tmp/acpmux-a"));
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    env.acpmux_home = Some(PathBuf::from("/tmp/acpmux-b"));
    assert_eq!(status(&env, App::Codex).state, State::Stale);
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    let doc: toml::Table =
        toml::from_str(&std::fs::read_to_string(env.config_path(App::Codex)).unwrap()).unwrap();
    assert_eq!(doc["mcp_servers"]["cmux"]["env"]["ACPMUX_HOME"].as_str(), Some("/tmp/acpmux-b"));
    env.acpmux_home = None;
    assert_eq!(status(&env, App::Codex).state, State::Stale);
}

#[test]
fn codex_gets_a_table_and_keeps_the_persons_comments_and_order() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    env.acpmux_home = Some(PathBuf::from("/tmp/acpmux-dev"));
    let path = env.config_path(App::Codex);
    let before =
        "# my settings\nmodel = \"gpt-5.5\"\n\n[mcp_servers.docs]\ncommand = \"docs-mcp\" # mine\n";
    std::fs::write(&path, before).unwrap();
    assert_eq!(status(&env, App::Codex).state, State::NotLinked);
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    let after = std::fs::read_to_string(&path).unwrap();
    assert!(after.starts_with(before), "{after}");
    let doc: toml::Table = toml::from_str(&after).unwrap();
    let entry = &doc["mcp_servers"]["cmux"];
    assert_eq!(entry["command"].as_str(), Some("/opt/cmux/bin/acpmux"));
    assert_eq!(entry["env"][GUEST_ENV].as_str(), Some("codex"));
    assert_eq!(entry["env"]["ACPMUX_HOME"].as_str(), Some("/tmp/acpmux-dev"));
    assert_eq!(status(&env, App::Codex).state, State::Linked);

    assert_eq!(unlink(&env, App::Codex, false).state, State::NotLinked);
    let doc: toml::Table = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(doc["mcp_servers"].get("cmux").is_none());
    assert_eq!(doc["mcp_servers"]["docs"]["command"].as_str(), Some("docs-mcp"));
    // Unlink takes back exactly what link wrote.
    assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
}

/// Review (#39320): a Codex link waits for the lock every cmux writer of config.toml takes
/// (`cmux_tui_platform::codex_config_lock`). The test plays the Cloud devbox provider merge: it
/// holds the lock, writes its block while the link waits, and releases; the link then keeps it.
#[cfg(unix)]
#[test]
fn a_codex_link_waits_for_the_config_lock_and_keeps_the_other_writers_change() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::Codex);
    std::fs::write(&path, "# my settings\n").unwrap();
    let lock_path = path.with_file_name(cmux_tui_platform::codex_config_lock::LOCK_FILE);
    let lock = std::fs::OpenOptions::new().create(true).append(true).open(&lock_path).unwrap();
    lock.lock().unwrap();
    std::thread::scope(|scope| {
        let linking = scope.spawn(|| link(&env, App::Codex, false));
        // A bound on how long the link must not finish, not a wait for it.
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert!(!linking.is_finished(), "the link wrote while another writer held the lock");
        let merged = "# my settings\n[model_providers.cmux]\nname = \"cmux\"\n";
        std::fs::write(&path, merged).unwrap();
        drop(lock);
        assert_eq!(linking.join().unwrap().state, State::Linked);
    });
    let doc: toml::Table = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(doc["model_providers"]["cmux"]["name"].as_str(), Some("cmux"));
    assert_eq!(doc["mcp_servers"]["cmux"]["env"][GUEST_ENV].as_str(), Some("codex"));
}

/// The edit `ours` adds to a config.toml, counting its renders.
fn ours_into<'a>(
    path: &'a Path,
    renders: &'a std::cell::Cell<u32>,
) -> impl Fn(&str) -> Result<String> + 'a {
    move |text: &str| {
        renders.set(renders.get().saturating_add(1));
        render_toml(path, text, &|servers: &mut toml_edit::Table| {
            servers.insert(SERVER_KEY, toml_edit::value("ours"));
            Ok(())
        })
    }
}

/// Another writer's file renamed over `path`, as an app that writes through a temp file does.
fn rename_over(path: &Path, text: &str) {
    let theirs = path.with_extension("theirs");
    std::fs::write(&theirs, text).unwrap();
    std::fs::rename(&theirs, path).unwrap();
}

/// Review (#39320): a writer outside the lock (Codex itself) that writes into config.toml in place
/// after the last compare, before the new text goes in, is not lost: the edit is done again on
/// its text.
#[test]
fn a_write_in_place_between_the_compare_and_the_swap_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("config.toml");
    std::fs::write(&path, "model = \"a\"\n").unwrap();
    let renders = std::cell::Cell::new(0);
    let mut first = true;
    let mut codex = || {
        if std::mem::take(&mut first) {
            std::fs::write(&path, "model = \"a\"\ntrusted = true\n").unwrap();
        }
    };
    write::edit_file_raced(&path, None, ours_into(&path, &renders), &mut codex).unwrap();
    assert_eq!(renders.get(), 2);
    let doc: toml::Table = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(doc["trusted"].as_bool(), Some(true));
    assert_eq!(doc["mcp_servers"][SERVER_KEY].as_str(), Some("ours"));
}

/// The same for a writer that renames its own file in at that moment: the swap brings out its
/// file, and the edit is done again on it.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn a_rename_over_the_file_between_the_compare_and_the_swap_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("config.toml");
    std::fs::write(&path, "model = \"a\"\n").unwrap();
    let renders = std::cell::Cell::new(0);
    let mut first = true;
    let mut codex = || {
        if std::mem::take(&mut first) {
            rename_over(&path, "model = \"b\"\n");
        }
    };
    write::edit_file_raced(&path, None, ours_into(&path, &renders), &mut codex).unwrap();
    assert_eq!(renders.get(), 2);
    let doc: toml::Table = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(doc["model"].as_str(), Some("b"));
    assert_eq!(doc["mcp_servers"][SERVER_KEY].as_str(), Some("ours"));
}

/// A writer that races every round, in place or by a rename, ends the edit refused, with its own
/// last text in the file.
#[test]
fn a_writer_that_keeps_racing_is_refused_with_its_text_kept() {
    let renames = cfg!(any(target_os = "linux", target_os = "macos"));
    for swap in [false, true].into_iter().filter(|r| !r || renames) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(&path, "edit = 0\n").unwrap();
        let renders = std::cell::Cell::new(0);
        let mut n = 0;
        let mut always = || {
            n += 1;
            let text = format!("edit = {n}\n");
            if swap { rename_over(&path, &text) } else { std::fs::write(&path, text).unwrap() }
        };
        let e = write::edit_file_raced(&path, None, ours_into(&path, &renders), &mut always)
            .unwrap_err();
        assert!(e.to_string().contains("kept changing"), "{e}");
        let last = format!("edit = {}\n", write::EDIT_TRIES);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), last, "by rename: {swap}");
    }
}

/// Holds Codex's config lock while `edit` runs on another thread, writes `theirs` into the file
/// while the edit waits for the lock (after its `status` read the file), then lets it go: the
/// edit's row.
#[cfg(unix)]
fn while_the_lock_is_held(path: &Path, theirs: &str, edit: impl FnOnce() -> Row + Send) -> Row {
    let lock_path = path.with_file_name(cmux_tui_platform::codex_config_lock::LOCK_FILE);
    let lock = std::fs::OpenOptions::new().create(true).append(true).open(&lock_path).unwrap();
    lock.lock().unwrap();
    std::thread::scope(|scope| {
        let editing = scope.spawn(edit);
        // A bound on how long the edit must not finish, not a wait for it.
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert!(!editing.is_finished(), "the edit wrote while another writer held the lock");
        std::fs::write(path, theirs).unwrap();
        drop(lock);
        editing.join().unwrap()
    })
}

/// Another tool's own `cmux` server in Codex's config, which this command did not write.
const FOREIGN_TOML: &str = "# theirs\n[mcp_servers.cmux]\ncommand = \"/usr/local/bin/my-cmux\"\n";

/// Review F2 (#39320): ownership is checked on the text the edit is built on, not only by the
/// `status` read before the lock. A foreign `cmux` written while link or unlink waits for the
/// lock is neither replaced nor removed, and the row says so.
#[cfg(unix)]
#[test]
fn a_foreign_entry_written_while_the_edit_waits_for_the_lock_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::Codex);
    std::fs::write(&path, "# my settings\n").unwrap();
    let row = while_the_lock_is_held(&path, FOREIGN_TOML, || link(&env, App::Codex, false));
    assert_eq!(row.state, State::Foreign, "{:?}", row.note);
    assert!(row.note.unwrap().contains("left alone"));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), FOREIGN_TOML);

    std::fs::write(&path, "# my settings\n").unwrap();
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    let row = while_the_lock_is_held(&path, FOREIGN_TOML, || unlink(&env, App::Codex, false));
    assert_eq!(row.state, State::Foreign, "{:?}", row.note);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), FOREIGN_TOML);
}

/// Review F2 and F3 (#39320): a foreign `cmux` that another writer (outside the lock) puts in
/// between the compare and the swap is met by the next round, which refuses it; the file ends
/// with exactly that writer's bytes, for link and unlink, in place or by a rename.
#[test]
fn a_foreign_entry_written_during_a_retry_is_left_alone_with_its_bytes() {
    let renames = cfg!(any(target_os = "linux", target_os = "macos"));
    for by_rename in [false, true].into_iter().filter(|r| !r || renames) {
        for unlinking in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let env = env(dir.path(), None);
            let path = env.config_path(App::Codex);
            std::fs::write(&path, "# my settings\n").unwrap();
            if unlinking {
                assert_eq!(link(&env, App::Codex, false).state, State::Linked);
            }
            let mut first = true;
            let mut other = || {
                if std::mem::take(&mut first) {
                    if by_rename {
                        rename_over(&path, FOREIGN_TOML);
                    } else {
                        std::fs::write(&path, FOREIGN_TOML).unwrap();
                    }
                }
            };
            let linking = link_toml(&env, App::Codex);
            let render = |text: &str| {
                if unlinking {
                    render_toml(&path, text, &unlink_toml)
                } else {
                    render_toml(&path, text, &linking)
                }
            };
            let e = write::edit_file_raced(&path, None, render, &mut other).unwrap_err();
            assert!(e.downcast_ref::<ForeignEntry>().is_some(), "{e:#}");
            let case = format!("by rename: {by_rename}, unlink: {unlinking}");
            assert_eq!(std::fs::read_to_string(&path).unwrap(), FOREIGN_TOML, "{case}");
        }
    }
}

/// Review F3 (#39320): another writer's text that came out of the swap goes back on every way
/// out of the edit. Here that writer saves half a JSON file, so the next round's render fails:
/// the file ends with exactly its bytes, not our text built on the older one.
#[test]
fn a_racing_writer_whose_text_fails_the_render_keeps_its_bytes() {
    let renames = cfg!(any(target_os = "linux", target_os = "macos"));
    for by_rename in [false, true].into_iter().filter(|r| !r || renames) {
        let dir = tempfile::tempdir().unwrap();
        let env = env(dir.path(), None);
        let path = env.config_path(App::ClaudeDesktop);
        std::fs::write(&path, r#"{"globalShortcut": "Alt+Space"}"#).unwrap();
        let half = r#"{"globalShortcut": "Alt+Sp"#;
        let mut first = true;
        let mut claude = || {
            if std::mem::take(&mut first) {
                if by_rename {
                    rename_over(&path, half);
                } else {
                    std::fs::write(&path, half).unwrap();
                }
            }
        };
        let linking = link_json(&env, App::ClaudeDesktop);
        let render = |text: &str| render_json(&path, SERVERS_KEY, text, &linking);
        let e = write::edit_file_raced(&path, None, render, &mut claude).unwrap_err();
        assert!(format!("{e:#}").contains("is not JSON"), "{e:#}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), half, "by rename: {by_rename}");
        // Nothing of ours is left beside it.
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["claude_desktop_config.json"], "by rename: {by_rename}");
    }
}

#[test]
fn an_app_that_is_not_here_is_not_linked() {
    let dir = tempfile::tempdir().unwrap();
    let env = Env {
        home: dir.path().to_path_buf(),
        claude_config_dir: None,
        codex_home: None,
        xdg_config_home: None,
        pi_dir: None,
        gemini_home: None,
        exe: PathBuf::from("/opt/acpmux"),
        args: vec!["acpmux-mcp".to_owned()],
        acpmux_home: None,
        claude_cli: None,
    };
    for app in App::ALL {
        let row = link(&env, app, false);
        assert_eq!(row.state, State::NotInstalled, "{app:?}");
        assert!(!row.config.exists());
    }
}

#[test]
fn a_config_that_is_not_json_is_named_and_left_as_it_is() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    std::fs::write(&path, "{ not json").unwrap();
    let row = link(&env, App::ClaudeDesktop, false);
    assert_ne!(row.state, State::Linked);
    assert!(row.note.unwrap().contains("is not JSON"));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
}

/// A stand-in `claude` CLI that writes `~/.claude.json` the way `claude mcp add-json` and
/// `claude mcp remove` do, and logs its argv.
#[cfg(unix)]
fn fake_claude(dir: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let cli = dir.join("claude");
    let script = format!(
        r#"#!/usr/bin/env python3
import json, sys
log = open({log:?}, "a"); log.write(" ".join(sys.argv[1:]) + "\n")
path = {config:?}
try: doc = json.load(open(path))
except Exception: doc = {{}}
servers = doc.setdefault("mcpServers", {{}})
args = sys.argv[1:]
if args[:2] == ["mcp", "add-json"]:
    if args[4] in servers: sys.exit("MCP server cmux already exists in user config")
    servers[args[4]] = json.loads(args[5])
elif args[:2] == ["mcp", "remove"]:
    servers.pop(args[4], None)
json.dump(doc, open(path, "w"))
"#,
        log = dir.join("claude.log").to_string_lossy(),
        config = dir.join(".claude.json").to_string_lossy(),
    );
    std::fs::write(&cli, script).unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    cli
}

#[cfg(unix)]
#[test]
fn claude_code_is_linked_through_its_own_cli() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), Some(fake_claude(dir.path())));
    assert_eq!(status(&env, App::ClaudeCode).state, State::NotLinked);
    let row = link(&env, App::ClaudeCode, false);
    assert_eq!(row.state, State::Linked, "{:?}", row.note);
    assert_eq!(status(&env, App::ClaudeCode).state, State::Linked);

    // A moved binary: the old entry is removed first, since add-json refuses a taken name.
    env.exe = PathBuf::from("/elsewhere/acpmux");
    assert_eq!(link(&env, App::ClaudeCode, false).state, State::Linked);
    assert_eq!(unlink(&env, App::ClaudeCode, false).state, State::NotLinked);
    let log = std::fs::read_to_string(dir.path().join("claude.log")).unwrap();
    let verbs: Vec<&str> = log.lines().map(|l| l.split(' ').nth(1).unwrap()).collect();
    assert_eq!(verbs, ["add-json", "remove", "add-json", "remove"]);
    assert!(log.lines().all(|l| l.contains("--scope user cmux")), "{log}");
}

#[test]
fn claude_code_without_its_cli_names_the_command_to_run() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    std::fs::write(env.config_path(App::ClaudeCode), "{}").unwrap();
    let row = link(&env, App::ClaudeCode, false);
    assert_eq!(row.state, State::NotLinked);
    let note = row.note.unwrap();
    assert!(note.contains("claude mcp add-json --scope user cmux"), "{note}");
}

/// Make `app` installed in the scratch home: its config folder exists.
fn install(env: &Env, app: App) {
    let dir = match app {
        App::Pi => env.home.join(".pi/agent"),
        _ => env.config_path(app).parent().unwrap().to_path_buf(),
    };
    std::fs::create_dir_all(dir).unwrap();
}

#[test]
fn an_app_whose_config_folder_is_missing_is_not_installed_and_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    for app in [App::OpenCode, App::GeminiCli, App::QwenCode, App::Pi] {
        let row = link(&env, app, false);
        assert_eq!(row.state, State::NotInstalled, "{app:?}");
        assert!(!env.config_path(app).exists(), "{app:?}");
    }
}

#[test]
fn opencode_gets_a_local_server_with_one_command_array_beside_the_persons_own() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    install(&env, App::OpenCode);
    let path = env.config_path(App::OpenCode);
    assert!(path.ends_with(".config/opencode/opencode.json"));
    std::fs::write(
        &path,
        r#"{"theme": "tokyonight", "mcp": {"zeta": {"type": "remote", "url": "https://x"}}, "model": "opencode-go/deepseek-v4-pro"}"#,
    )
    .unwrap();
    assert_eq!(status(&env, App::OpenCode).state, State::NotLinked);
    assert_eq!(link(&env, App::OpenCode, false).state, State::Linked);
    let text = std::fs::read_to_string(&path).unwrap();
    let doc: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        doc["mcp"]["cmux"],
        json!({
            "type": "local",
            "command": ["/opt/cmux/bin/acpmux", "acpmux-mcp"],
            "environment": {GUEST_ENV: "opencode"},
            "enabled": true,
        })
    );
    assert_eq!(doc["mcp"]["zeta"]["url"], "https://x");
    // The person's key order stays: theme, mcp, model; their server first.
    let order: Vec<usize> = ["\"theme\"", "\"mcp\"", "\"zeta\"", "\"cmux\"", "\"model\""]
        .map(|k| text.find(k).unwrap())
        .to_vec();
    assert!(order.windows(2).all(|w| w[0] < w[1]), "{text}");
    assert_eq!(status(&env, App::OpenCode).state, State::Linked);
    assert_eq!(link(&env, App::OpenCode, false).note.as_deref(), Some("already linked"));
    // Another binary's entry of ours is stale.
    let mut moved = env.clone();
    moved.exe = PathBuf::from("/elsewhere/acpmux");
    assert_eq!(status(&moved, App::OpenCode).state, State::Stale);
    assert_eq!(unlink(&env, App::OpenCode, false).state, State::NotLinked);
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(doc["mcp"].get("cmux").is_none());
    assert_eq!(doc["mcp"]["zeta"]["type"], "remote");
}

#[test]
fn an_opencode_server_named_cmux_that_cmux_did_not_write_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    install(&env, App::OpenCode);
    let path = env.config_path(App::OpenCode);
    let theirs = r#"{"mcp": {"cmux": {"type": "local", "command": ["my-cmux"]}}}"#;
    std::fs::write(&path, theirs).unwrap();
    assert_eq!(status(&env, App::OpenCode).state, State::Foreign);
    assert_eq!(link(&env, App::OpenCode, false).state, State::Foreign);
    assert_eq!(unlink(&env, App::OpenCode, false).state, State::Foreign);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), theirs);
}

#[test]
fn gemini_cli_and_qwen_code_get_mcp_servers_without_claudes_type() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    for (app, file, id) in [
        (App::GeminiCli, ".gemini/settings.json", "gemini"),
        (App::QwenCode, ".qwen/settings.json", "qwen"),
    ] {
        install(&env, app);
        let path = env.config_path(app);
        assert!(path.ends_with(file));
        std::fs::write(&path, r#"{"selectedAuthType": "oauth-personal"}"#).unwrap();
        assert_eq!(link(&env, app, false).state, State::Linked, "{app:?}");
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            doc["mcpServers"]["cmux"],
            json!({
                "command": "/opt/cmux/bin/acpmux",
                "args": ["acpmux-mcp"],
                "env": {GUEST_ENV: id},
            })
        );
        assert_eq!(doc["selectedAuthType"], "oauth-personal");
        assert_eq!(status(&env, app).state, State::Linked);
        assert_eq!(unlink(&env, app, false).state, State::NotLinked);
    }
}

#[test]
fn pi_gets_a_skill_that_runs_this_cli_as_a_guest() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    let me = crate::self_command::SelfCommand::new(
        PathBuf::from("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"),
        vec!["acp".into()],
    );
    env.args = me.args_lossy(&["acpmux-mcp"]);
    env.exe = me.exe;
    install(&env, App::Pi);
    let path = env.config_path(App::Pi);
    assert!(path.ends_with(".pi/agent/skills/cmux/SKILL.md"));
    assert_eq!(status(&env, App::Pi).state, State::NotLinked);
    assert_eq!(link(&env, App::Pi, true).note.as_deref(), Some("would link"));
    assert!(!path.exists());
    assert_eq!(link(&env, App::Pi, false).state, State::Linked);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.starts_with("---\nname: cmux\ndescription: "), "{text}");
    // The binary under its prefix, quoted, as a guest; never the MCP server subcommand.
    assert!(
        text.contains("    ACPMUX_MCP_GUEST=pi '/Applications/cmux NEXT.app/Contents/Resources/bin/cmux' acp\n"),
        "{text}"
    );
    assert!(!text.contains("acpmux-mcp"));
    assert!(text.contains("send --no-wait --from pi -- NAME"));
    assert_eq!(status(&env, App::Pi).state, State::Linked);
    // Another acpmux home: stale, and relinked.
    env.acpmux_home = Some(PathBuf::from("/tmp/other-home"));
    assert_eq!(status(&env, App::Pi).state, State::Stale);
    assert_eq!(link(&env, App::Pi, false).state, State::Linked);
    assert!(std::fs::read_to_string(&path).unwrap().contains("ACPMUX_HOME=/tmp/other-home"));
    assert_eq!(unlink(&env, App::Pi, false).state, State::NotLinked);
    assert!(!path.exists());
    assert!(!path.parent().unwrap().exists());
}

#[test]
fn a_cmux_skill_in_pi_that_cmux_did_not_write_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    env.pi_dir = Some(dir.path().join("pi-home"));
    install(&env, App::Pi);
    std::fs::create_dir_all(dir.path().join("pi-home")).unwrap();
    let path = env.config_path(App::Pi);
    assert!(path.starts_with(dir.path().join("pi-home")));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "---\nname: cmux\n---\nmine\n").unwrap();
    assert_eq!(status(&env, App::Pi).state, State::Foreign);
    assert_eq!(link(&env, App::Pi, false).state, State::Foreign);
    assert_eq!(unlink(&env, App::Pi, false).state, State::Foreign);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "---\nname: cmux\n---\nmine\n");
}

/// Every harness family acpmux runs by name (`acpmux --help`: Claude Code, Codex, OpenCode, pi,
/// Gemini) can be linked, so a chat started outside cmux in any of them reaches the others.
#[test]
fn every_harness_family_acpmux_runs_can_be_linked() {
    for family in ["claude", "codex", "opencode", "pi", "gemini"] {
        assert!(App::ALL.iter().any(|a| a.id().starts_with(family)), "{family} has no link");
    }
}

#[test]
fn gemini_cli_reads_its_own_home_when_one_is_set() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    env.gemini_home = Some(dir.path().join("gemini-home"));
    assert_eq!(
        env.config_path(App::GeminiCli),
        dir.path().join("gemini-home/.gemini/settings.json")
    );
    install(&env, App::GeminiCli);
    assert_eq!(link(&env, App::GeminiCli, false).state, State::Linked);
    assert!(!dir.path().join(".gemini/settings.json").exists());
}

#[test]
fn pi_unlink_never_deletes_a_skill_that_is_not_cmuxs() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    install(&env, App::Pi);
    assert_eq!(link(&env, App::Pi, false).state, State::Linked);
    // Replaced by the person's own after status read cmux's: remove_entry judges what it moved.
    let path = env.config_path(App::Pi);
    std::fs::write(&path, "---\nname: cmux\n---\nmine\n").unwrap();
    let e = remove_entry(&env, App::Pi).unwrap_err();
    assert!(e.downcast_ref::<ForeignEntry>().is_some(), "{e:#}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "---\nname: cmux\n---\nmine\n");
    let left: Vec<_> = std::fs::read_dir(path.parent().unwrap()).unwrap().collect();
    assert_eq!(left.len(), 1, "only SKILL.md stays");
    // Gone already: nothing to do.
    std::fs::remove_file(&path).unwrap();
    assert!(remove_entry(&env, App::Pi).is_ok());
}

#[test]
fn a_pi_skill_that_only_mentions_the_guest_variable_is_not_cmuxs() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    install(&env, App::Pi);
    let path = env.config_path(App::Pi);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let theirs = "---\nname: cmux\n---\nRun with ACPMUX_MCP_GUEST=pi set.\n";
    std::fs::write(&path, theirs).unwrap();
    assert_eq!(status(&env, App::Pi).state, State::Foreign);
    assert_eq!(link(&env, App::Pi, false).state, State::Foreign);
    assert_eq!(unlink(&env, App::Pi, false).state, State::Foreign);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), theirs);
}
