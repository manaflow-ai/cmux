//! oh-my-zsh never checks for updates in a cmux terminal (Lawrence,
//! 2026-11-23: "make oh-my-zsh never check for updates again"). Each test
//! starts the real zsh in a PTY, integrated as the daemon does it and as the
//! app's layer does it, under a `.zshrc` that asks oh-my-zsh to update by
//! itself (`zstyle ':omz:update' mode auto`) and then runs oh-my-zsh's own
//! check (the mode lines of `tools/check_for_upgrade.sh`). The check must
//! read `disabled`; at the prompt `zstyle` is the builtin again. Without the
//! integration the same `.zshrc` checks, so the test proves the fixture. A
//! machine without zsh skips.

use super::test_pty::TestPty;
use super::*;
use std::time::{Duration, Instant};

/// oh-my-zsh's mode lookup (tools/check_for_upgrade.sh), then what it does:
/// return on `disabled`, else go on to the update check.
const CHECK: &str = r#"
zstyle -s ':omz:update' mode update_mode || {
  update_mode=prompt
  [[ "$DISABLE_UPDATE_PROMPT" != true ]] || update_mode=auto
  [[ "$DISABLE_AUTO_UPDATE" != true ]] || update_mode=disabled
}
if [[ "$update_mode" = disabled ]]; then
  print -r -- "omz-check-skipped"
else
  print -r -- "omz-check-runs-$update_mode"
fi
unset update_mode
"#;

fn temp_base(name: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "cmux-tui-omz-update-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    fs::create_dir_all(&base).unwrap();
    fs::canonicalize(&base).unwrap()
}

/// A user dir whose `.zshrc` asks for automatic updates and runs the check.
fn user_dir(base: &Path) -> PathBuf {
    let user = base.join("user");
    fs::create_dir_all(&user).unwrap();
    fs::write(user.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
    fs::write(
        user.join(".zshrc"),
        format!("zstyle ':omz:update' mode auto\nDISABLE_AUTO_UPDATE=false\n{CHECK}\nPS1='> '\n"),
    )
    .unwrap();
    user
}

/// Starts `launched`, waits for the prompt, asks what `zstyle` is and the
/// mode now, exits; everything the shell printed.
fn run(launched: ShellLaunch) -> String {
    let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
    command.args(launched.command[1..].iter().cloned());
    command.env("TERM", "xterm-256color");
    for (key, value) in &launched.env {
        command.env(key.clone(), value.clone());
    }
    let size = cmux_pty::PtySize { rows: 24, cols: 120, pixel_width: 0, pixel_height: 0 };
    let mut pty = TestPty::spawn(size, command);
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut output = Vec::new();
    let wait_for = |pty: &mut TestPty, output: &mut Vec<u8>, needle: &[u8]| loop {
        if output.windows(needle.len()).any(|window| window == needle) {
            return;
        }
        match pty.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(chunk) => output.extend_from_slice(&chunk),
            Err(_) => panic!(
                "no {:?} from zsh: {:?}",
                String::from_utf8_lossy(needle),
                String::from_utf8_lossy(output)
            ),
        }
    };
    wait_for(&mut pty, &mut output, b"> ");
    pty.write(
        b"print -r -- \"at-prompt-$(whence -w zstyle)-$(zstyle -L ':omz:update')-end$((6*7))\"\n",
    );
    // The typed line shows `$((6*7))`; only the output holds 42.
    wait_for(&mut pty, &mut output, b"-end42");
    pty.write(b"exit\n");
    drop(pty);
    String::from_utf8_lossy(&output).into_owned()
}

fn assert_never_checks(name: &str, output: &str) {
    assert!(output.contains("omz-check-skipped"), "{name}: the check ran: {output:?}");
    assert!(!output.contains("omz-check-runs-"), "{name}: the check ran: {output:?}");
    assert!(
        output.contains("at-prompt-zstyle: builtin-zstyle :omz:update mode disabled-end42"),
        "{name}: at the prompt zstyle is the builtin and the mode stays disabled: {output:?}"
    );
}

fn zsh() -> Option<PathBuf> {
    ["/bin/zsh", "/usr/bin/zsh"].iter().map(PathBuf::from).find(|path| path.is_file())
}

#[test]
fn oh_my_zsh_never_checks_for_updates_in_a_zsh_the_daemon_integrated() {
    let Some(zsh) = zsh() else {
        eprintln!("skipped: zsh is not installed");
        return;
    };
    let base = temp_base("daemon");
    let user = user_dir(&base);
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("ZDOTDIR".to_string(), user.to_string_lossy().into_owned()),
    ];
    // The fixture checks when nothing stops it.
    let bare =
        run(ShellLaunch { command: vec![zsh.to_string_lossy().into_owned()], env: env.clone() });
    assert!(bare.contains("omz-check-runs-auto"), "the fixture's check must run bare: {bare:?}");

    let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
    let lookup = {
        let env = env.clone();
        move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
    };
    let launched = apply(
        Shell::Zsh,
        &root,
        vec![zsh.to_string_lossy().into_owned()],
        env,
        &lookup,
        &ghostty_files::read(&lookup),
    );
    assert_never_checks("daemon zsh", &run(launched));
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn oh_my_zsh_never_checks_for_updates_in_a_zsh_the_app_integrated() {
    let Some(zsh) = zsh() else {
        eprintln!("skipped: zsh is not installed");
        return;
    };
    // affected-reads: ghostty-next Resources/cmux-cli-path
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let ghostty = fs::canonicalize(root.join("ghostty-next/src/shell-integration")).unwrap();
    let layer = fs::canonicalize(root.join("Resources/cmux-cli-path")).unwrap();
    let base = temp_base("app");
    let user = user_dir(&base);
    // GhosttyShellIntegration.apply, then BundledCLIEnvironment.apply.
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("GHOSTTY_ZSH_ZDOTDIR".to_string(), user.to_string_lossy().into_owned()),
        ("CMUX_CLI_ZSH_ZDOTDIR".to_string(), ghostty.join("zsh").to_string_lossy().into_owned()),
        ("ZDOTDIR".to_string(), layer.join("zsh").to_string_lossy().into_owned()),
    ];
    let launched = ShellLaunch { command: vec![zsh.to_string_lossy().into_owned()], env };
    assert_never_checks("app zsh", &run(launched));
    let _ = fs::remove_dir_all(&base);
}
