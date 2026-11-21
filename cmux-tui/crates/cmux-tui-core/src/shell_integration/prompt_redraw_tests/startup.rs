//! New shells must leave one prompt through the first viewer's resize and replay.

use super::*;

const PROMPT: &str = "new-terminal-prompt> ";

fn fifty_opens(shell: Shell, name: &str) {
    let Some(exe) = shell_path(shell) else {
        return test_pty::skip("PROMPT-REDRAW-SKIP", name, "shell is not installed");
    };
    let base = temp_base(name);
    fs::write(base.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
    fs::write(base.join(".zshrc"), format!("PS1='{PROMPT}'\nsetopt prompt_cr prompt_sp\n"))
        .unwrap();
    fs::write(base.join(".bashrc"), format!("PS1='{PROMPT}'\n")).unwrap();
    let config = base.join("config");
    fs::create_dir_all(config.join("fish")).unwrap();
    fs::write(
        config.join("fish/config.fish"),
        format!("set -g fish_greeting\nfunction fish_prompt\n echo -n '{PROMPT}'\nend\n"),
    )
    .unwrap();
    let env = vec![
        ("HOME".into(), base.to_string_lossy().into_owned()),
        ("ZDOTDIR".into(), base.to_string_lossy().into_owned()),
        ("XDG_CONFIG_HOME".into(), config.to_string_lossy().into_owned()),
    ];
    let launched = launch(shell, &exe, &base, env);
    let mut duplicates = Vec::new();
    for opening in 0..50 {
        let size = |cols, rows| cmux_pty::PtySize { cols, rows, pixel_width: 0, pixel_height: 0 };
        let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
        command.args(launched.command[1..].iter().cloned());
        command.env("TERM", "xterm-256color");
        for (key, value) in &launched.env {
            command.env(key.clone(), value.clone());
        }
        let mut pty = TestPty::spawn(size(80, 24), command);
        let mut host =
            ghostty_vt::Terminal::new(80, 24, 100_000, ghostty_vt::Callbacks::default()).unwrap();
        host.resize(80, 24, 8, 16).unwrap();
        // Alternate an attach before the first prompt and after it. The latter
        // replays the terminal while its prompt clear still waits for the shell.
        if opening % 2 == 0 {
            host.vt_write(&read_until_quiet(
                &mut pty,
                Some(PROMPT.as_bytes()),
                Duration::from_millis(100),
            ));
        }
        let (cols, rows) = if opening % 3 == 0 { (60, 18) } else { (100, 30) };
        pty.spawned.master.resize(size(cols, rows)).unwrap();
        host.resize(cols, rows, 8, 16).unwrap();
        let replay = host.vt_replay_bounded_theme_portable_with_aliases(1_000_000).unwrap();
        let mut viewer =
            ghostty_vt::Terminal::new(cols, rows, 100_000, ghostty_vt::Callbacks::default())
                .unwrap();
        viewer.resize(cols, rows, 8, 16).unwrap();
        viewer.vt_write(&replay.self_contained_bytes());
        let output = read_until_quiet(
            &mut pty,
            (opening % 2 != 0).then_some(PROMPT.as_bytes()),
            Duration::from_millis(300),
        );
        host.vt_write(&output);
        viewer.vt_write(&output);
        for (side, term) in [("host", &mut host), ("viewer", &mut viewer)] {
            let text = term.plain_text().unwrap();
            if text.matches(PROMPT.trim_end()).count() != 1 {
                duplicates.push(format!("open {} {side}: {text:?}", opening + 1));
            }
        }
        pty.write_quietly(b"exit\n");
    }
    let _ = fs::remove_dir_all(&base);
    eprintln!("PROMPT-STARTUP {name}: 50 opens, {} failing screens", duplicates.len());
    assert!(duplicates.is_empty(), "{name}: {}", duplicates.join("\n"));
}

#[test]
fn prompt_startup_zsh_fifty_opens_have_one_prompt() {
    fifty_opens(Shell::Zsh, "zsh");
}

#[test]
fn prompt_startup_bash_fifty_opens_have_one_prompt() {
    fifty_opens(Shell::Bash, "bash");
}

#[test]
fn prompt_startup_fish_fifty_opens_have_one_prompt() {
    fifty_opens(Shell::Fish, "fish");
}
