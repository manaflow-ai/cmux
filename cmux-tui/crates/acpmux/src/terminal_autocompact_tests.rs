use super::*;

use std::fs;

fn words(w: &[&str]) -> Vec<String> {
    w.iter().map(|s| (*s).to_owned()).collect()
}

/// An env with sr2's hook socket in `/tmp/sr2-claude2-1/` and Claude's config folder at `home`.
fn sr2_env(home: &Path) -> impl Fn(&str) -> Option<String> + '_ {
    move |name| match name {
        "SR2_CLAUDE2_HOOK_SOCKET" => Some("/tmp/sr2-claude2-1/hook.sock".into()),
        "CLAUDE_CONFIG_DIR" => Some(home.display().to_string()),
        _ => None,
    }
}

fn sources(dir: &Path) -> ProfileSources {
    ProfileSources { user_dir: Some(dir.to_path_buf()), ..ProfileSources::none() }
}

#[test]
fn the_chat_profiles_autocompact_is_its_last_one() {
    let root = tempfile::tempdir().unwrap();
    let harnesses = root.path().join("harnesses");
    fs::create_dir_all(&harnesses).unwrap();
    fs::write(
        harnesses.join("claude-sr2-pipe.toml"),
        r#"schema = 1
id = "claude-sr2-pipe"
name = "Claude"
protocol = "claude-stdio"
command = "/bin/claude-coord-cap"
args = ["236663", "/bin/claude", "--autocompact", "400000", "--autocompact", "157125"]
"#,
    )
    .unwrap();
    let config = root.path().join("config.json");
    fs::write(&config, r#"{"defaultHarness":"claude-sr2-pipe"}"#).unwrap();
    assert_eq!(
        chat_claude_autocompact_from(&config, &sources(&harnesses)).as_deref(),
        Some("157125")
    );

    // config.json's own entry, when no profile file has the id.
    fs::write(
        &config,
        r#"{"defaultHarness":"mine","harnesses":{"mine":{"kind":"claude-stdio","argv":["claude","--autocompact=200000"]}}}"#,
    )
    .unwrap();
    assert_eq!(
        chat_claude_autocompact_from(&config, &sources(&harnesses)).as_deref(),
        Some("200000")
    );

    // A default that is not Claude Code, or names none, gives none.
    fs::write(
        &config,
        r#"{"defaultHarness":"codex","harnesses":{"codex":{"argv":["codex-acp","--autocompact","1"]}}}"#,
    )
    .unwrap();
    assert_eq!(chat_claude_autocompact_from(&config, &sources(&harnesses)), None);
    assert_eq!(
        chat_claude_autocompact_from(&root.path().join("none.json"), &sources(&harnesses)),
        None
    );
}

#[test]
fn sr2s_draw_is_found_only_in_its_own_prefix() {
    let home = tempfile::tempdir().unwrap();
    let env = sr2_env(home.path());
    let resumed = words(&[
        "--autocompact",
        "385829",
        "--settings",
        "/tmp/sr2-claude2-1/settings.json",
        "--resume",
        "6e0bad7d",
    ]);
    assert_eq!(launcher_draw(&resumed, &env), Some(1));
    let fresh = words(&[
        "--session-id",
        "x",
        "--autocompact",
        "401000",
        "--settings",
        "/tmp/sr2-claude2-1/settings.json",
    ]);
    assert_eq!(launcher_draw(&fresh, &env), Some(3));
    // Another folder's settings, or no sr2 socket: the person's own flag.
    let typed = words(&["--autocompact", "300000", "--settings", "/home/me/s.json"]);
    assert_eq!(launcher_draw(&typed, &env), None);
    assert_eq!(launcher_draw(&resumed, |_| None), None);
}

#[test]
fn a_terminal_takes_the_chats_autocompact_over_a_launchers_draw() {
    let home = tempfile::tempdir().unwrap();
    let cwd = home.path();
    let env = sr2_env(home.path());
    let sr2 = words(&[
        "--autocompact",
        "385829",
        "--settings",
        "/tmp/sr2-claude2-1/settings.json",
        "--resume",
        "6e0bad7d",
    ]);
    // sr2's draw becomes the chat profile's value.
    assert_eq!(
        terminal_autocompact(&sr2, cwd, &env, Some("157125")),
        AutocompactEdit::Replace(1, "157125".into())
    );
    // A plain `claude`: the chat's value goes first.
    assert_eq!(
        terminal_autocompact(&words(&["fix the bug"]), cwd, &env, Some("157125")),
        AutocompactEdit::Prepend("157125".into())
    );
    // No chat value: as before (sr2's draw, or acpmux's window).
    assert_eq!(terminal_autocompact(&sr2, cwd, &env, None), AutocompactEdit::Keep);
    // The person's own flag after sr2's prefix wins.
    let mut typed = sr2.clone();
    typed.extend(words(&["--autocompact", "300000"]));
    assert_eq!(terminal_autocompact(&typed, cwd, &env, Some("157125")), AutocompactEdit::Keep);
    // So does their env.
    let own_env = |name: &str| match name {
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => Some("500000".to_owned()),
        other => env(other),
    };
    assert_eq!(terminal_autocompact(&sr2, cwd, own_env, Some("157125")), AutocompactEdit::Keep);
}
