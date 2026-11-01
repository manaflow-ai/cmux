//! Leak 2 of the incognito audit: every command typed in an incognito
//! terminal reached the user's shell history. Each test starts the real
//! shell with the daemon's integration in a PTY, under startup files that
//! keep history in a file and write it after every command (as many users'
//! do), types one command and exits. A normal terminal's command reaches the
//! file; an incognito terminal's ([`keep_no_history`]) never does. A shell
//! that is not installed skips its test.

use super::test_pty::TestPty;
use super::*;
use std::time::{Duration, Instant};

/// What the command prints; its typed text (`$((6*7))`) differs, so the
/// output marks the moment it ran.
const RAN: &[u8] = b"incognito-marker-42";
/// The command in POSIX shells (zsh, bash).
const TYPED: &str = "echo incognito-marker-$((6*7))";
/// The command in fish.
const TYPED_FISH: &str = "echo incognito-marker-(math 6 '*' 7)";
/// What a history file holds once the command reached it.
const KEPT: &str = "incognito-marker-";

fn find(candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().map(PathBuf::from).find(|path| path.is_file())
}

fn temp_base(name: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "cmux-tui-incognito-history-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    fs::create_dir_all(&base).unwrap();
    fs::canonicalize(&base).unwrap()
}

/// Reads into `output` until `needle` appears after its first `from` bytes;
/// the offset just past it.
fn read_until(pty: &mut TestPty, output: &mut Vec<u8>, from: usize, needle: &[u8], deadline: Instant) -> usize {
    loop {
        if let Some(at) = output
            .get(from..)
            .and_then(|rest| rest.windows(needle.len()).position(|window| window == needle))
        {
            return from + at + needle.len();
        }
        match pty.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(chunk) => output.extend_from_slice(&chunk),
            Err(_) => panic!(
                "no {:?} from the shell: {:?}",
                String::from_utf8_lossy(needle),
                String::from_utf8_lossy(output)
            ),
        }
    }
}

/// Start `exe` integrated as `shell` with `env` (plus the incognito keys when
/// `incognito`), run `typed` at the prompt and exit; the history file then.
fn run_one_command(
    shell: Shell,
    exe: &Path,
    base: &Path,
    mut env: Vec<(String, String)>,
    incognito: bool,
    (typed, history): (&str, &Path),
) -> String {
    if incognito {
        keep_no_history(&mut env);
    }
    let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
    let lookup = {
        let env = env.clone();
        move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
    };
    let launched = apply(
        shell,
        &root,
        vec![exe.to_string_lossy().into_owned()],
        env,
        &lookup,
        &ghostty_files::read(&lookup),
    );
    run_launch(launched, typed, history)
}

/// Like [`run_one_command`], for a shell the app integrated itself
/// (`terminal-frontend-shell-integration-v1`): the daemon starts `command`
/// as given with the app's env (Ghostty's scripts under the app's
/// `Resources/cmux-cli-path` layer, `BundledCLIEnvironment.swift`), adding
/// only its own keys.
fn run_app_command(
    command: Vec<String>,
    mut env: Vec<(String, String)>,
    incognito: bool,
    (typed, history): (&str, &Path),
) -> String {
    if incognito {
        keep_no_history(&mut env);
    }
    run_launch(ShellLaunch { command, env }, typed, history)
}

/// The repo's Ghostty scripts and the app's layer, as the app bundles them.
fn app_resources() -> (PathBuf, PathBuf) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    (
        fs::canonicalize(root.join("ghostty-next/src/shell-integration")).unwrap(),
        fs::canonicalize(root.join("Resources/cmux-cli-path")).unwrap(),
    )
}

fn run_launch(launched: ShellLaunch, typed: &str, history: &Path) -> String {
    let _ = fs::remove_file(history);
    let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
    command.args(launched.command[1..].iter().cloned());
    command.env("TERM", "xterm-256color");
    for (key, value) in &launched.env {
        command.env(key.clone(), value.clone());
    }
    let size = cmux_pty::PtySize { rows: 24, cols: 120, pixel_width: 0, pixel_height: 0 };
    let mut pty = TestPty::spawn(size, command);
    let deadline = Instant::now() + Duration::from_secs(30);
    // Type at the prompt, as a user does: input typed before the line editor
    // starts can lose characters.
    let mut output = Vec::new();
    let at = read_until(&mut pty, &mut output, 0, b"> ", deadline);
    pty.write(format!("{typed}\n").as_bytes());
    let at = read_until(&mut pty, &mut output, at, RAN, deadline);
    read_until(&mut pty, &mut output, at, b"> ", deadline);
    pty.write(b"exit\n");
    // The exit-time save runs before the shell exits.
    while pty.spawned.child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the shell did not exit");
        let _ = pty.recv_timeout(Duration::from_millis(50));
    }
    drop(pty);
    fs::read_to_string(history).unwrap_or_default()
}

fn assert_history_kept_only_when_normal(
    name: &str,
    run: impl Fn(bool) -> String,
    base: &Path,
) {
    let normal = run(false);
    assert!(normal.contains(KEPT), "{name}: a normal terminal keeps its history: {normal:?}");
    let incognito = run(true);
    assert!(
        !incognito.contains(KEPT),
        "{name}: an incognito terminal must keep no history: {incognito:?}"
    );
    let _ = fs::remove_dir_all(base);
}

#[test]
fn an_incognito_zsh_keeps_no_history_even_when_zshrc_sets_histfile() {
    let Some(zsh) = find(&["/bin/zsh", "/usr/bin/zsh"]) else {
        eprintln!("skipped: zsh is not installed");
        return;
    };
    let base = temp_base("zsh");
    let user = base.join("user");
    fs::create_dir_all(&user).unwrap();
    let history = base.join("zsh_history");
    fs::write(user.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
    // macOS /etc/zshrc sets HISTFILE the same way, after any inherited one.
    fs::write(
        user.join(".zshrc"),
        format!(
            "HISTFILE={}\nHISTSIZE=100\nSAVEHIST=100\nsetopt inc_append_history\nPS1='> '\n",
            history.display()
        ),
    )
    .unwrap();
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("ZDOTDIR".to_string(), user.to_string_lossy().into_owned()),
    ];
    let run = |incognito| run_one_command(Shell::Zsh, &zsh, &base, env.clone(), incognito, (TYPED, &history));
    assert_history_kept_only_when_normal("zsh", run, &base);
}

#[test]
fn an_incognito_bash_keeps_no_history_even_when_bashrc_sets_histfile() {
    // Apple's /bin/bash gets no integration (see detect_shell).
    let Some(bash) = find(&["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"])
    else {
        eprintln!("skipped: an integrated bash is not installed");
        return;
    };
    let base = temp_base("bash");
    let history = base.join("bash_history");
    fs::write(
        base.join(".bashrc"),
        format!("HISTFILE={}\nPROMPT_COMMAND='history -a'\nPS1='> '\n", history.display()),
    )
    .unwrap();
    let env = vec![("HOME".to_string(), base.to_string_lossy().into_owned())];
    let run =
        |incognito| run_one_command(Shell::Bash, &bash, &base, env.clone(), incognito, (TYPED, &history));
    assert_history_kept_only_when_normal("bash", run, &base);
}

#[test]
fn an_incognito_fish_keeps_no_history() {
    let Some(fish) = find(&["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"])
    else {
        eprintln!("skipped: fish is not installed");
        return;
    };
    let base = temp_base("fish");
    let config = base.join("config");
    let data = base.join("data");
    fs::create_dir_all(config.join("fish")).unwrap();
    fs::create_dir_all(&data).unwrap();
    fs::write(
        config.join("fish/config.fish"),
        "set -g fish_greeting\nfunction fish_prompt\n    echo -n '> '\nend\n",
    )
    .unwrap();
    let history = data.join("fish/fish_history");
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("XDG_CONFIG_HOME".to_string(), config.to_string_lossy().into_owned()),
        ("XDG_DATA_HOME".to_string(), data.to_string_lossy().into_owned()),
    ];
    let run =
        |incognito| run_one_command(Shell::Fish, &fish, &base, env.clone(), incognito, (TYPED_FISH, &history));
    assert_history_kept_only_when_normal("fish", run, &base);
}

#[test]
fn an_incognito_zsh_the_app_integrated_keeps_no_history() {
    let Some(zsh) = find(&["/bin/zsh", "/usr/bin/zsh"]) else {
        eprintln!("skipped: zsh is not installed");
        return;
    };
    let (ghostty, layer) = app_resources();
    let base = temp_base("app-zsh");
    let user = base.join("user");
    fs::create_dir_all(&user).unwrap();
    let history = base.join("zsh_history");
    fs::write(user.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
    fs::write(
        user.join(".zshrc"),
        format!(
            "HISTFILE={}\nHISTSIZE=100\nSAVEHIST=100\nsetopt inc_append_history\nPS1='> '\n",
            history.display()
        ),
    )
    .unwrap();
    // GhosttyShellIntegration.apply, then BundledCLIEnvironment.apply.
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("GHOSTTY_ZSH_ZDOTDIR".to_string(), user.to_string_lossy().into_owned()),
        ("CMUX_CLI_ZSH_ZDOTDIR".to_string(), ghostty.join("zsh").to_string_lossy().into_owned()),
        ("ZDOTDIR".to_string(), layer.join("zsh").to_string_lossy().into_owned()),
    ];
    let command = vec![zsh.to_string_lossy().into_owned()];
    let run =
        |incognito| run_app_command(command.clone(), env.clone(), incognito, (TYPED, &history));
    assert_history_kept_only_when_normal("app zsh", run, &base);
}

#[test]
fn an_incognito_bash_the_app_integrated_keeps_no_history() {
    let Some(bash) = find(&["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"])
    else {
        eprintln!("skipped: an integrated bash is not installed");
        return;
    };
    let (ghostty, layer) = app_resources();
    let base = temp_base("app-bash");
    let history = base.join("bash_history");
    fs::write(
        base.join(".bashrc"),
        format!("HISTFILE={}\nPROMPT_COMMAND='history -a'\nPS1='> '\n", history.display()),
    )
    .unwrap();
    // GhosttyShellIntegration.apply, then BundledCLIEnvironment.apply.
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("GHOSTTY_BASH_INJECT".to_string(), "1".to_string()),
        ("HISTFILE".to_string(), base.join(".bash_history").to_string_lossy().into_owned()),
        ("GHOSTTY_BASH_UNEXPORT_HISTFILE".to_string(), "1".to_string()),
        (
            "CMUX_CLI_BASH_ENV".to_string(),
            ghostty.join("bash/ghostty.bash").to_string_lossy().into_owned(),
        ),
        ("ENV".to_string(), layer.join("bash/cmux-cli-path.bash").to_string_lossy().into_owned()),
    ];
    let command = vec![bash.to_string_lossy().into_owned(), "--posix".to_string()];
    let run =
        |incognito| run_app_command(command.clone(), env.clone(), incognito, (TYPED, &history));
    assert_history_kept_only_when_normal("app bash", run, &base);
}
