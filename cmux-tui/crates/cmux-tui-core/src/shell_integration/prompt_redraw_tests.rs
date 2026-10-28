//! manaflow-ai/cmux#21341 with the shells the daemon integrates. Each test
//! starts the real shell with the injected Ghostty integration in a PTY,
//! narrows the PTY and the daemon's terminal together, and parses the
//! shell's own SIGWINCH redraw. The prompt must show once: the terminal
//! clears it so the redraw replaces it, as in the Ghostty app. A shell that
//! is not installed skips its test.

use super::test_pty::TestPty;
use super::*;
use std::time::{Duration, Instant};

/// Line 1 of every prompt: padded close to the 40-column start width, so a
/// narrower grid wraps it onto two rows.
const LINE_ONE: &str = "LINE-ONE-OF-THE-PROMPT..............EOL";

fn find(candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().map(PathBuf::from).find(|path| path.is_file())
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
/// daemon's terminal shows the prompt's line 1 once after each redraw.
fn narrow_and_count_line_one(name: &str, launched: ShellLaunch, base: &Path) {
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
    let count = |term: &mut ghostty_vt::Terminal| {
        let text = term.plain_text().unwrap();
        (text.matches("LINE-ONE").count(), text)
    };
    assert_eq!(count(&mut term).0, 1, "{name}: the first prompt");
    for narrower in [32u16, 26] {
        cols = narrower;
        pty.spawned.master.resize(size(cols)).unwrap();
        term.resize(cols, rows, 8, 16).unwrap();
        term.vt_write(&read_until_quiet(&mut pty, None, Duration::from_millis(700)));
        let (copies, text) = count(&mut term);
        assert_eq!(copies, 1, "{name}: line 1 after narrowing to {cols} columns:\n{text}");
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
    let Some(zsh) = find(&["/bin/zsh", "/usr/bin/zsh"]) else {
        eprintln!("skipped: zsh is not installed");
        return;
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
    narrow_and_count_line_one("zsh", launch(Shell::Zsh, &zsh, &base, env), &base);
}

#[test]
fn prompt_redraw_fish_two_line_prompt_narrows_without_leftovers() {
    let Some(fish) = find(&["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"])
    else {
        eprintln!("skipped: fish is not installed");
        return;
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
    narrow_and_count_line_one("fish", launch(Shell::Fish, &fish, &base, env), &base);
}

#[test]
fn prompt_redraw_bash_two_line_prompt_narrows_without_leftovers() {
    // Apple's /bin/bash gets no integration (see detect_shell).
    let Some(bash) = find(&["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"])
    else {
        eprintln!("skipped: an integrated bash is not installed");
        return;
    };
    let base = temp_base("bash");
    fs::write(base.join(".bashrc"), format!("PS1='{LINE_ONE}\\n> '\n")).unwrap();
    let env = vec![("HOME".to_string(), base.to_string_lossy().into_owned())];
    narrow_and_count_line_one("bash", launch(Shell::Bash, &bash, &base, env), &base);
}
