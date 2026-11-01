//! manaflow-ai/cmux#21341 with the shells the daemon integrates. Each test
//! starts the real shell with the injected Ghostty integration in a PTY,
//! narrows the PTY and the daemon's terminal together, and parses the
//! shell's own SIGWINCH redraw. The prompt must show once: the terminal
//! clears it so the redraw replaces it, as in the Ghostty app.
//!
//! The shells are the fork-count guard's (`test_pty::shell_path`): on macOS
//! /bin/zsh and the pinned bash 5.3 and fish 4.9.3 on every host, so these
//! tests never pass there without their shell. Elsewhere a shell that is not
//! installed skips its test with a `PROMPT-REDRAW-SKIP` line, which the step
//! log keeps.

use super::test_pty::{self, TestPty, shell_path};
use super::*;
use std::time::{Duration, Instant};

/// Line 1 of every prompt: padded close to the 40-column start width, so a
/// narrower grid reflows the copy already on the screen onto two rows.
const LINE_ONE: &str = "LINE-ONE-OF-THE-PROMPT..............EOL";

/// Text that only a copy of line 1 (or a piece of one) puts on the screen.
/// Whatever the host prints before the first prompt (a greeting, Ubuntu's
/// /etc/bash.bashrc sudo hint) has none of it.
const LINE_ONE_PIECES: [&str; 4] = ["LINE-ONE", "-OF-THE-", "EOL", "…"];

/// Where the one copy of line 1 starts at the end of `shown`, as the shell
/// draws it at `cols` columns. zsh and bash wrap a line wider than the
/// terminal, so it shows whole. fish truncates it instead: an ellipsis, then
/// the end of the line that fits (`…-OF-THE-PROMPT..............EOL` at 32
/// columns).
fn line_one_start(shown: &str, cols: u16) -> Option<usize> {
    if shown.ends_with(LINE_ONE) {
        return Some(shown.len() - LINE_ONE.len());
    }
    let start = shown.rfind('…')?;
    let end = &shown[start + '…'.len_utf8()..];
    (!end.is_empty() && end.chars().count() < usize::from(cols) && LINE_ONE.ends_with(end))
        .then_some(start)
}

/// Checks that the screen ends with exactly one prompt (one copy of line 1,
/// then `> `) and holds no other piece of line 1. The rows are joined with
/// their trailing blanks removed, so a soft-wrapped line reads whole. A row
/// the redraw left behind (the reflowed start or end of the old line 1)
/// holds a piece of line 1, so the check fails on it.
fn assert_one_prompt(term: &mut ghostty_vt::Terminal, cols: u16, what: &str) {
    let text = term.plain_text().unwrap();
    let shown: String = text.lines().map(str::trim_end).collect();
    let before = shown
        .strip_suffix('>')
        .and_then(|rest| line_one_start(rest, cols).map(|start| &rest[..start]));
    assert!(
        before.is_some_and(|before| LINE_ONE_PIECES.iter().all(|piece| !before.contains(piece))),
        "{what}: not one prompt (line 1, then `> `) and no other piece of line 1:\n{text}"
    );
}

fn temp_base(name: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "cmux-tui-prompt-redraw-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    fs::create_dir_all(&base).unwrap();
    fs::canonicalize(&base).unwrap()
}

/// Reads until `needle` arrived (if any) and the shell then wrote nothing
/// for `quiet`. The quiet period is the bounded end of a redraw.
fn read_until_quiet(pty: &mut TestPty, needle: Option<&[u8]>, quiet: Duration) -> Vec<u8> {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut output = Vec::new();
    loop {
        let found =
            needle.is_none_or(|needle| output.windows(needle.len()).any(|window| window == needle));
        let wait = if found { quiet } else { deadline.saturating_duration_since(Instant::now()) };
        match pty.recv_timeout(wait) {
            Ok(chunk) => output.extend_from_slice(&chunk),
            Err(_) if found => return output,
            Err(_) => {
                panic!("no {needle:?} from the shell: {:?}", String::from_utf8_lossy(&output))
            }
        }
        assert!(Instant::now() < deadline, "the shell never went quiet");
    }
}

/// Starts `launched` at 40x10, narrows to each width, and checks that the
/// daemon's terminal shows the prompt once after each redraw.
fn narrow_and_check_one_prompt(name: &str, launched: ShellLaunch, base: &Path) {
    let (mut cols, rows) = (40u16, 10u16);
    let size = |cols| cmux_pty::PtySize { rows, cols, pixel_width: 0, pixel_height: 0 };
    let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
    command.args(launched.command[1..].iter().cloned());
    command.env("TERM", "xterm-256color");
    for (key, value) in &launched.env {
        command.env(key.clone(), value.clone());
    }
    let mut pty = TestPty::spawn(size(cols), command);
    let mut term =
        ghostty_vt::Terminal::new(cols, rows, 100_000, ghostty_vt::Callbacks::default()).unwrap();
    term.vt_write(&read_until_quiet(&mut pty, Some(b"> "), Duration::from_millis(500)));
    assert_one_prompt(&mut term, cols, &format!("{name}: the first prompt"));
    for narrower in [32u16, 26] {
        cols = narrower;
        pty.spawned.master.resize(size(cols)).unwrap();
        term.resize(cols, rows, 8, 16).unwrap();
        term.vt_write(&read_until_quiet(&mut pty, None, Duration::from_millis(700)));
        assert_one_prompt(&mut term, cols, &format!("{name}: after narrowing to {cols} columns"));
    }
    pty.write_quietly(b"exit\n");
    drop(pty);
    let _ = fs::remove_dir_all(base);
}

fn launch(shell: Shell, exe: &Path, base: &Path, env: Vec<(String, String)>) -> ShellLaunch {
    let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
    let lookup = {
        let env = env.clone();
        move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
    };
    apply(
        shell,
        &root,
        vec![exe.to_string_lossy().into_owned()],
        env,
        &lookup,
        &ghostty_files::read(&lookup),
    )
}

#[test]
fn prompt_redraw_zsh_two_line_prompt_narrows_without_leftovers() {
    let Some(zsh) = shell_path(Shell::Zsh) else {
        return test_pty::skip("PROMPT-REDRAW-SKIP", "zsh", "zsh is not installed");
    };
    let base = temp_base("zsh");
    let user = base.join("user");
    fs::create_dir_all(&user).unwrap();
    fs::write(user.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
    fs::write(user.join(".zshrc"), format!("unsetopt prompt_sp\nPS1=$'{LINE_ONE}\\n> '\n"))
        .unwrap();
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("ZDOTDIR".to_string(), user.to_string_lossy().into_owned()),
    ];
    narrow_and_check_one_prompt("zsh", launch(Shell::Zsh, &zsh, &base, env), &base);
}

#[test]
fn prompt_redraw_fish_two_line_prompt_narrows_without_leftovers() {
    let Some(fish) = shell_path(Shell::Fish) else {
        return test_pty::skip("PROMPT-REDRAW-SKIP", "fish", "fish is not installed");
    };
    let base = temp_base("fish");
    let config = base.join("config");
    fs::create_dir_all(config.join("fish")).unwrap();
    fs::write(
        config.join("fish/config.fish"),
        format!(
            "set -g fish_greeting\nfunction fish_prompt\n    echo '{LINE_ONE}'\n    echo -n '> '\nend\n"
        ),
    )
    .unwrap();
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("XDG_CONFIG_HOME".to_string(), config.to_string_lossy().into_owned()),
    ];
    narrow_and_check_one_prompt("fish", launch(Shell::Fish, &fish, &base, env), &base);
}

#[test]
fn prompt_redraw_bash_two_line_prompt_narrows_without_leftovers() {
    // Apple's /bin/bash 3.2 gets no integration (see detect_shell); macOS
    // takes the pinned bash 5.3.
    let Some(bash) = shell_path(Shell::Bash) else {
        return test_pty::skip("PROMPT-REDRAW-SKIP", "bash", "an integrated bash is not installed");
    };
    let base = temp_base("bash");
    fs::write(base.join(".bashrc"), format!("PS1='{LINE_ONE}\\n> '\n")).unwrap();
    let env = vec![("HOME".to_string(), base.to_string_lossy().into_owned())];
    narrow_and_check_one_prompt("bash", launch(Shell::Bash, &bash, &base, env), &base);
}
