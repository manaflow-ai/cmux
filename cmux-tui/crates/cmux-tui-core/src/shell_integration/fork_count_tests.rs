//! Shell integration costs nothing per prompt, on the scripts the daemon
//! really writes: `materialize` puts `SCRIPTS` on disk and `apply` builds the
//! launch, exactly as `integrate_default_shell` does for a daemon spawn with
//! no app layer. Each test runs the shell on a pty, types commands at its
//! prompt (half of them `cd` between a plain directory and a git repository,
//! so cwd- and git-triggered work is counted too), and counts what the shell
//! forks with the PID counter: PIDs are handed out in sequence, so the PID gap
//! between two probes is the number of processes forked between them.
//!
//! Other processes on the host only make a gap larger, so each count is the
//! minimum over reps, and the integrated shell may fork no more than the same
//! shell without the integration (plus the budget: 2 per command on bash
//! 4.4-5.2, whose only pre-command hook is Ghostty's PS0 command
//! substitution). Removing the bash 5.3 fix from `SCRIPTS` makes the bash test
//! fail with one fork per command. A shell that is not installed skips its
//! test; so does bash older than 4.4 (Ghostty uses bash-preexec there).
//!
//! The bench (`scripts/cmux-next/shell-integration-bench.py`) also counts the
//! app's spawn path, startup forks and an idle window at the prompt.

use super::*;
use std::io::Read;
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

const PROMPT: &[u8] = b"@@P@@ ";
const SYSTEM_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
/// Reps until the integrated count reaches the control count. A shell that
/// really forks never does, so a failure costs all of them.
const MAX_REPS: usize = 6;
/// Commands per counted window.
const COMMANDS: usize = 12;

fn find(candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().map(PathBuf::from).find(|path| path.is_file())
}

fn temp_base(name: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "cmux-tui-fork-count-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    fs::create_dir_all(&base).unwrap();
    fs::canonicalize(&base).unwrap()
}

/// The PID of a process started now: the system's PID counter at this moment.
fn probe_pid() -> u32 {
    let mut child = std::process::Command::new("true").spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

/// One shell on a pty, driven by what it prints.
struct Session {
    spawned: cmux_pty::SpawnedPty,
    writer: Box<dyn Write + Send>,
    received: Receiver<Vec<u8>>,
    output: Vec<u8>,
}

impl Session {
    fn start(command: &[String], env: &[(String, String)], cwd: &Path) -> Self {
        let pty = cmux_pty::open(cmux_pty::PtySize {
            rows: 30,
            cols: 200,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();
        let mut pty_command = cmux_pty::PtyCommand::new(&command[0]);
        pty_command.args(command[1..].iter().cloned());
        // Only the test's env: an inherited ENV, ZDOTDIR or PROMPT_COMMAND
        // would change what the shell runs.
        pty_command.env_clear();
        pty_command.cwd(cwd);
        for (key, value) in env {
            pty_command.env(key.clone(), value.clone());
        }
        let spawned = pty.spawn(pty_command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        let writer = spawned.master.take_writer().unwrap();
        let (chunks, received) = channel::<Vec<u8>>();
        std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            // EOF, or EIO once the child side closes (Linux).
            while let Ok(n) = reader.read(&mut chunk) {
                if n == 0 || chunks.send(chunk[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Self { spawned, writer, received, output: Vec::new() }
    }

    fn wait_for(&mut self, done: impl Fn(&[u8]) -> bool, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !done(self.output.as_slice()) {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.received.recv_timeout(left) {
                Ok(chunk) => self.output.extend_from_slice(&chunk),
                Err(_) => {
                    let tail = &self.output[self.output.len().saturating_sub(600)..];
                    panic!("no {what} from the shell: {:?}", String::from_utf8_lossy(tail))
                }
            }
        }
    }

    fn prompts(&self) -> usize {
        count(&self.output, PROMPT)
    }

    fn write(&mut self, bytes: &[u8]) {
        self.writer.write_all(bytes).unwrap();
        self.writer.flush().unwrap();
    }

    /// Returns once the line editor reads keys again: every prompt hook ran.
    fn barrier(&mut self) {
        let mark = self.output.len();
        self.write(b"^");
        self.wait_for(|output| output[mark..].contains(&b'^'), "echo of the barrier key");
        // Kill the line (^U) so the next command starts on an empty one.
        self.write(b"\x15");
    }

    fn run(&mut self, line: &str) {
        let seen = self.prompts();
        self.write(format!("{line}\r").as_bytes());
        self.wait_for(|output| count(output, PROMPT) > seen, "the next prompt");
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.writer.write_all(b"\x15exit\r");
        let _ = self.spawned.child.kill();
    }
}

fn count(haystack: &[u8], needle: &[u8]) -> usize {
    haystack.windows(needle.len()).filter(|window| *window == needle).count()
}

/// The commands of one counted window, as typed at the prompt.
fn commands(plain: &Path, repo: &Path) -> Vec<String> {
    (0..COMMANDS)
        .map(|index| match index % 4 {
            0 => format!("cd {}", repo.display()),
            2 => format!("cd {}", plain.display()),
            _ => "true".to_string(),
        })
        .collect()
}

/// Forks in the window that types `lines`, and the shell's output.
fn forks_while_typing(
    command: &[String],
    env: &[(String, String)],
    cwd: &Path,
    lines: &[String],
) -> Option<(u32, Vec<u8>)> {
    let mut session = Session::start(command, env, cwd);
    session.wait_for(|output| count(output, PROMPT) > 0, "first prompt");
    session.barrier();
    let before = probe_pid();
    for line in lines {
        session.run(line);
    }
    session.barrier();
    let after = probe_pid();
    let output = std::mem::take(&mut session.output);
    drop(session);
    // A PID counter that wrapped inside the window says nothing.
    (after > before).then(|| (after - before - 1, output))
}

/// A HOME whose startup files only set a prompt the test can find, a plain
/// directory and a git repository to `cd` between, and the base env.
fn prepare(base: &Path) -> (PathBuf, PathBuf, Vec<(String, String)>) {
    let prompt = std::str::from_utf8(PROMPT).unwrap();
    let plain = base.join("plain");
    let repo = base.join("repo");
    fs::create_dir_all(&plain).unwrap();
    // A git repository without running git (a fork outside the window, but
    // the test should not need git installed).
    fs::create_dir_all(repo.join(".git/objects")).unwrap();
    fs::create_dir_all(repo.join(".git/refs/heads")).unwrap();
    fs::write(repo.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
    let zdotdir = base.join("zdotdir");
    fs::create_dir_all(&zdotdir).unwrap();
    // No system rc files: a distribution's global zshrc can stop at an
    // interactive compinit question.
    fs::write(zdotdir.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
    fs::write(zdotdir.join(".zshrc"), format!("PS1='{prompt}'\nSAVEHIST=0\n")).unwrap();
    fs::write(base.join(".bashrc"), format!("PS1='{prompt}'\n")).unwrap();
    let fish = base.join("config/fish");
    fs::create_dir_all(&fish).unwrap();
    // fish starts its man-page completion generator until this exists.
    fs::create_dir_all(base.join(".local/share/fish/generated_completions")).unwrap();
    fs::write(
        fish.join("config.fish"),
        format!(
            "set -g fish_greeting ''\nset -g fish_autosuggestion_enabled 0\n\
             function fish_prompt; printf '%s' '{prompt}'; end\nfunction fish_right_prompt; end\n"
        ),
    )
    .unwrap();
    // The daemon's agent shim directory: its prompt hook is part of the cost.
    let shims = base.join("agent-shims");
    fs::create_dir_all(&shims).unwrap();
    let mut env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("PATH".to_string(), format!("{}:{SYSTEM_PATH}", shims.display())),
        ("TERM".to_string(), "xterm-256color".to_string()),
        ("ZDOTDIR".to_string(), zdotdir.to_string_lossy().into_owned()),
        ("XDG_CONFIG_HOME".to_string(), base.join("config").to_string_lossy().into_owned()),
        (AGENT_SHIMS_ENV.to_string(), shims.to_string_lossy().into_owned()),
    ];
    // bash 5.3's `${ }` captures through a file in TMPDIR on macOS.
    for key in ["USER", "LOGNAME", "TMPDIR"] {
        if let Ok(value) = std::env::var(key) {
            env.push((key.to_string(), value));
        }
    }
    (plain, repo, env)
}

/// Runs `exe` with and without the daemon's integration and fails when the
/// integrated shell forks more than `budget_per_command` per command over
/// the control.
fn assert_no_forks_per_command(name: &str, shell: Shell, exe: &Path, budget_per_command: u32) {
    let base = temp_base(name);
    let (plain, repo, env) = prepare(&base);
    let lines = commands(&plain, &repo);
    let exe = exe.to_string_lossy().into_owned();
    let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
    let lookup = {
        let env = env.clone();
        move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
    };
    let integrated =
        apply(shell, &root, vec![exe.clone()], env.clone(), &lookup, &ghostty_files::read(&lookup));
    let budget = budget_per_command * lines.len() as u32;
    let (mut control_min, mut integrated_min) = (u32::MAX, u32::MAX);
    for rep in 0..MAX_REPS {
        let Some((control, _)) = forks_while_typing(&[exe.clone()], &env, &base, &lines) else {
            continue;
        };
        let Some((forks, output)) =
            forks_while_typing(&integrated.command, &integrated.env, &base, &lines)
        else {
            continue;
        };
        // An integration that did not run forks nothing: its preexec marks
        // prove it ran.
        let marks = count(&output, b"\x1b]133;C");
        assert!(
            marks >= lines.len(),
            "{name}: {marks} OSC 133;C marks for {} commands (the integration did not run): {:?}",
            lines.len(),
            String::from_utf8_lossy(&output[output.len().saturating_sub(600)..])
        );
        control_min = control_min.min(control);
        integrated_min = integrated_min.min(forks);
        if rep >= 1 && integrated_min <= control_min + budget {
            fs::remove_dir_all(&base).unwrap();
            return;
        }
    }
    panic!(
        "{name}: the daemon-integrated shell forked {integrated_min} times for {} commands, \
         the same shell without the integration {control_min} (budget {budget}; minimum of \
         {MAX_REPS} reps)",
        lines.len()
    );
}

#[test]
fn fork_count_zsh_forks_nothing_per_command() {
    let Some(zsh) = find(&["/bin/zsh", "/usr/bin/zsh"]) else {
        eprintln!("skipped: zsh is not installed");
        return;
    };
    assert_no_forks_per_command("zsh", Shell::Zsh, &zsh, 0);
}

#[test]
fn fork_count_fish_forks_nothing_per_command() {
    let Some(fish) = find(&["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"])
    else {
        eprintln!("skipped: fish is not installed");
        return;
    };
    assert_no_forks_per_command("fish", Shell::Fish, &fish, 0);
}

/// bash 5.3 forks nothing per command with the daemon's scripts (Ghostty's
/// `$(builtin history 1)` forks once without the fix); bash 4.4-5.2 forks
/// twice per command (Ghostty's PS0 command substitution and the history
/// read in it), and no more.
#[test]
fn fork_count_bash_forks_nothing_per_command_on_bash_5_3() {
    // Apple's /bin/bash gets no integration (see detect_shell).
    let Some(bash) = find(&["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"])
    else {
        eprintln!("skipped: an integrated bash is not installed");
        return;
    };
    let version = std::process::Command::new(&bash)
        .args(["-c", "printf '%s %s' \"${BASH_VERSINFO[0]}\" \"${BASH_VERSINFO[1]}\""])
        .output()
        .unwrap();
    let version = String::from_utf8_lossy(&version.stdout).into_owned();
    let mut parts = version.split(' ').map(|part| part.parse::<u32>().unwrap_or(0));
    let (major, minor) = (parts.next().unwrap_or(0), parts.next().unwrap_or(0));
    if (major, minor) < (4, 4) {
        eprintln!("skipped: bash {major}.{minor} is older than 4.4 (Ghostty uses bash-preexec)");
        return;
    }
    let budget = if (major, minor) >= (5, 3) { 0 } else { 2 };
    assert_no_forks_per_command("bash", Shell::Bash, &bash, budget);
}
