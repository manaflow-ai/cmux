//! A shell the daemon integrates itself (a terminal that `cmux tab create
//! terminal` or `cmux workspace create` starts, with no caller env) must run
//! the app's bundled `cmux` (`CMUX_BUNDLED_CLI_PATH`, which the app puts in the
//! daemon's environment), also when the user's startup files prepend another
//! directory that holds a `cmux` (for example `~/.local/bin`). The app's own
//! spawns get this from `BundledCLIEnvironment.swift`; these run the real
//! shells through the daemon's injection with the app's
//! `Resources/cmux-cli-path` layers and read `command -v cmux` at the prompt.

use super::*;

/// A fake app bundle (`<Resources>/bin/cmux` and the layers from
/// `Resources/cmux-cli-path`) and a home whose startup files prepend
/// `~/.local/bin`, which holds another `cmux`.
struct Fixture {
    base: PathBuf,
    resources: PathBuf,
    home: PathBuf,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let base = std::env::temp_dir().join(format!(
            "cmux-cli-path-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&base).unwrap();
        let base = fs::canonicalize(&base).unwrap();
        let resources = base.join("cmux DEV t.app/Contents/Resources");
        let home = base.join("home");
        fs::create_dir_all(resources.join("bin")).unwrap();
        fs::create_dir_all(home.join(".local/bin")).unwrap();
        copy_tree(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/cmux-cli-path"),
            &resources.join("cmux-cli-path"),
        );
        executable(&resources.join("bin/cmux"), "#!/bin/sh\necho bundled\n");
        executable(&home.join(".local/bin/cmux"), "#!/bin/sh\necho old\n");
        let prepend =
            "export PATH=\"$HOME/.local/bin:$PATH\"\nexport CMUX_TEST_RC_RAN=1\nPS1='$ '\n";
        fs::write(home.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
        fs::write(home.join(".zshrc"), prepend).unwrap();
        fs::write(home.join(".bashrc"), prepend).unwrap();
        Self { base, resources, home }
    }

    fn bundled_cli(&self) -> String {
        self.resources.join("bin/cmux").to_string_lossy().into_owned()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}

#[cfg(unix)]
fn executable(path: &Path, contents: &str) {
    use std::os::unix::fs::PermissionsExt;
    fs::write(path, contents).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

#[cfg(not(unix))]
fn executable(path: &Path, contents: &str) {
    fs::write(path, contents).unwrap();
}

/// What `probe` prints in an interactive `exe` that the daemon integrated
/// with `env` (the daemon's environment for a terminal with no caller env).
#[cfg(unix)]
fn run_integrated(
    shell: Shell,
    exe: &str,
    fixture: &Fixture,
    env: Vec<(String, String)>,
) -> String {
    use std::io::{Read, Write};
    let root = materialize(&fixture.base.join("shell-integration").join(content_digest())).unwrap();
    let lookup = {
        let env = env.clone();
        move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
    };
    let launched =
        apply(shell, &root, vec![exe.into()], env, &lookup, &ghostty_files::read(&lookup));
    let pty =
        cmux_pty::open(cmux_pty::PtySize { rows: 24, cols: 400, pixel_width: 0, pixel_height: 0 })
            .unwrap();
    let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
    command.args(launched.command[1..].iter().cloned());
    command.env_clear();
    command.env("TERM", "xterm-256color");
    for (key, value) in &launched.env {
        command.env(key.clone(), value.clone());
    }
    let mut spawned = pty.spawn(command).unwrap();
    let mut reader = spawned.master.try_clone_reader().unwrap();
    let mut writer = spawned.master.take_writer().unwrap();
    let (chunks, received) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut chunk = [0u8; 4096];
        while let Ok(n) = reader.read(&mut chunk) {
            if n == 0 || chunks.send(chunk[..n].to_vec()).is_err() {
                break;
            }
        }
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut output = Vec::new();
    let read_until = |output: &mut Vec<u8>, needle: &[u8]| {
        while !output.windows(needle.len()).any(|window| window == needle) {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            match received.recv_timeout(left) {
                Ok(chunk) => output.extend_from_slice(&chunk),
                Err(_) => panic!(
                    "no {:?} from {exe}: {:?}",
                    String::from_utf8_lossy(needle),
                    String::from_utf8_lossy(output)
                ),
            }
        }
    };
    read_until(&mut output, b"$ ");
    // The marker's echoed text (`end-$((40+2))`) differs from its output.
    writer
        .write_all(
            b"printf 'cli=%s rc=%s leak=%s\\n' \"$(command -v cmux)\" \"$CMUX_TEST_RC_RAN\" \
              \"$(env | grep -c '^CMUX_CLI_')\"; echo end-$((40+2))\n",
        )
        .unwrap();
    read_until(&mut output, b"end-42\r\n");
    writer.write_all(b"exit\n").unwrap();
    drop(writer);
    while spawned.child.try_wait().unwrap().is_none() {
        assert!(std::time::Instant::now() < deadline, "{exe} did not exit");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let text = String::from_utf8_lossy(&output).into_owned();
    // The probe's output (not its echo, which shows `cli=%s`), after any
    // escape sequences the prompt hooks wrote on the same line.
    text.split(['\r', '\n'])
        .filter_map(|line| line.find("cli=/").map(|at| &line[at..]))
        .last()
        .unwrap_or_else(|| panic!("no probe line from {exe}: {text:?}"))
        .to_string()
}

/// The daemon's terminal env: the app's daemon environment (`PATH` with the
/// bundled bin dir first, `CMUX_BUNDLED_CLI_PATH`) and the user's home.
fn daemon_env(fixture: &Fixture, shell: Shell) -> Vec<(String, String)> {
    let home = fixture.home.to_string_lossy().into_owned();
    let bin = fixture.resources.join("bin").to_string_lossy().into_owned();
    let mut env = vec![
        ("HOME".to_string(), home.clone()),
        ("PATH".to_string(), format!("{bin}:/usr/bin:/bin:/usr/sbin:/sbin")),
        ("CMUX_BUNDLED_CLI_PATH".to_string(), fixture.bundled_cli()),
    ];
    if shell == Shell::Zsh {
        env.push(("ZDOTDIR".to_string(), home));
    }
    env
}

/// The real shells: after `~/.zshrc` / `~/.bashrc` prepend `~/.local/bin`
/// (which holds another `cmux`), plain `cmux` is still the bundled CLI, the
/// user's file ran, and no layer variable reaches the shell's children.
#[cfg(unix)]
#[test]
fn a_daemon_integrated_shell_keeps_the_bundled_cli_first_after_user_startup_files() {
    let shells: Vec<(Shell, &str)> = [
        (Shell::Zsh, ["/bin/zsh", "/usr/bin/zsh"].into_iter().find(|p| Path::new(p).is_file())),
        (
            Shell::Bash,
            ["/usr/bin/bash", "/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
                .into_iter()
                .find(|p| Path::new(p).is_file() && detect_shell(&[(*p).into()]).is_some()),
        ),
    ]
    .into_iter()
    .filter_map(|(shell, exe)| exe.map(|exe| (shell, exe)))
    .collect();
    if shells.is_empty() {
        eprintln!("skipped: neither zsh nor a usable bash is installed");
        return;
    }
    for (shell, exe) in shells {
        let fixture = Fixture::new(&format!("{shell:?}"));
        let line = run_integrated(shell, exe, &fixture, daemon_env(&fixture, shell));
        assert_eq!(line, format!("cli={} rc=1 leak=0", fixture.bundled_cli()), "{exe}");
    }
}

/// Without a bundled CLI in the environment, the daemon's integration is
/// Ghostty's alone (`ZDOTDIR` and `ENV` point at Ghostty's scripts).
#[test]
fn without_a_bundled_cli_the_integration_is_ghosttys_alone() {
    let zsh = super::tests::launch("zsh", &[("HOME", "/home/me")]);
    assert_eq!(
        super::tests::env_of(&zsh, "ZDOTDIR").as_deref(),
        Some("/state/shell-integration/abc/zsh")
    );
    assert_eq!(super::tests::env_of(&zsh, "CMUX_CLI_ZSH_ZDOTDIR"), None);
    let bash = super::tests::launch("/usr/local/bin/bash", &[("HOME", "/home/me")]);
    assert_eq!(
        super::tests::env_of(&bash, "ENV").as_deref(),
        Some("/state/shell-integration/abc/bash/ghostty.bash")
    );
}
