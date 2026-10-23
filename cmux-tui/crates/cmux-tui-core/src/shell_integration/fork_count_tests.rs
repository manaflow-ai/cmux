//! Shell integration costs nothing per prompt, on the scripts the daemon
//! really writes: `materialize` puts `SCRIPTS` on disk and `apply` builds the
//! launch, exactly as `integrate_default_shell` does for a daemon spawn with
//! no app layer. Each test starts the shell on a pty, counts what it forks
//! from the spawn to its first prompt (startup), then types commands at the
//! prompt (half of them `cd` between a plain directory and a git repository,
//! so cwd- and git-triggered work is counted too) and counts what it forks
//! for them. Counts come from the PID counter: PIDs are handed out in
//! sequence, so the PID gap between two probes is the number of processes
//! forked between them.
//!
//! Other processes on the host only make a gap larger, so each count is the
//! minimum over reps, and the integrated shell may fork no more than the same
//! shell without the integration: 0 at startup, and per command 0, except 2
//! on bash 4.4-5.2, whose only pre-command hook is Ghostty's PS0 command
//! substitution. A control minimum that only one rep reached is host noise,
//! not a baseline, and fails the test ("unstable baseline") instead of
//! hiding forks. bash runs in three homes: no PROMPT_COMMAND, a string one
//! and an array one (the integration reads its type at startup).
//!
//! It needs ghostty-next 72578da or later: before it, Ghostty's ghostty.bash
//! forks once per command on bash 5.3 (`cmd=$(builtin history 1)`) and once
//! at startup when .bashrc sets PROMPT_COMMAND (`$(builtin declare -p
//! PROMPT_COMMAND)`), on every bash.
//!
//! A shell that is not installed skips its test, and so does bash older than
//! 4.4 (Ghostty uses bash-preexec there). Linux CI has bash 5.2 and no zsh or
//! fish, so it runs only the bash 4.4-5.2 budget; the bash 5.3, zsh and fish
//! paths run on a Mac. There, `CMUX_FORK_COUNT_REQUIRE` turns a skip into a
//! failure: a comma list of `zsh`, `fish`, `bash`, and `bash5.3` (an
//! integrated bash 5.3 or later must run):
//!
//! ```text
//! CMUX_FORK_COUNT_REQUIRE=zsh,fish,bash5.3 cargo test -p cmux-tui-core --lib fork_count_
//! ```
//!
//! The bench (`scripts/cmux-next/shell-integration-bench.py`) also counts the
//! app's spawn path (the `Resources/cmux-cli-path` layer) and an idle window
//! at the prompt.

use super::*;
use std::io::Read;
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

const PROMPT: &[u8] = b"@@P@@ ";
const SYSTEM_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
/// Reps until the integrated count reaches the control count. A shell that
/// really forks never does, so a failure costs all of them.
const MAX_REPS: usize = 6;
/// Commands per counted window.
const COMMANDS: usize = 12;
/// Reps a control minimum must reach to count as the baseline.
const STABLE_REPS: usize = 2;
/// The fork-count tests fork too: run one at a time so they do not count
/// each other.
static SERIAL: Mutex<()> = Mutex::new(());

/// Runs `test` alone among the fork-count tests.
fn serial(test: impl FnOnce()) {
    let _guard = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    test();
}

/// Whether `CMUX_FORK_COUNT_REQUIRE` names `what`.
fn required(what: &str) -> bool {
    std::env::var("CMUX_FORK_COUNT_REQUIRE")
        .is_ok_and(|list| list.split(',').any(|item| item.trim() == what))
}

/// Skips the test, or fails it when `CMUX_FORK_COUNT_REQUIRE` names `what`.
fn skip(what: &str, why: &str) {
    assert!(!required(what), "{why}, and CMUX_FORK_COUNT_REQUIRE requires {what}");
    eprintln!("skipped: {why}");
}

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

/// What one shell forked: from the spawn to its first prompt, and while it
/// ran `lines`.
struct Forks {
    startup: u32,
    typing: u32,
    output: Vec<u8>,
}

/// Starts the shell, types `lines`, and counts its forks; `None` when the
/// PID counter wrapped inside a window (the gap says nothing then).
fn count_forks(
    command: &[String],
    env: &[(String, String)],
    cwd: &Path,
    lines: &[String],
) -> Option<Forks> {
    let spawn = probe_pid();
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
    // Both gaps exclude the closing probe; the startup gap includes the
    // shell itself, in the control as in the integrated run.
    (before > spawn && after > before).then(|| Forks {
        startup: before - spawn - 1,
        typing: after - before - 1,
        output,
    })
}

/// The minimum of `counts` once at least `STABLE_REPS` reps reached it.
fn stable_min(counts: &[u32]) -> Option<u32> {
    let low = *counts.iter().min()?;
    (counts.iter().filter(|count| **count == low).count() >= STABLE_REPS).then_some(low)
}

/// A HOME whose startup files only set a prompt the test can find (and, for
/// bash, `bashrc_extra`), a plain directory and a git repository to `cd`
/// between, and the base env.
fn prepare(base: &Path, bashrc_extra: &str) -> (PathBuf, PathBuf, Vec<(String, String)>) {
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
    fs::write(base.join(".bashrc"), format!("PS1='{prompt}'\n{bashrc_extra}")).unwrap();
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
/// integrated shell forks more than the control at startup, or more than
/// `budget_per_command` per command over the control.
fn assert_no_extra_forks(
    name: &str,
    shell: Shell,
    exe: &Path,
    bashrc_extra: &str,
    budget_per_command: u32,
) {
    let base = temp_base(name);
    let (plain, repo, env) = prepare(&base, bashrc_extra);
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
    let mut control = (Vec::new(), Vec::new());
    let (mut startup_min, mut typing_min) = (u32::MAX, u32::MAX);
    let mut verdict = "the PID counter wrapped in every rep".to_string();
    for _ in 0..MAX_REPS {
        let Some(plain_shell) = count_forks(&[exe.clone()], &env, &base, &lines) else {
            continue;
        };
        let Some(forks) = count_forks(&integrated.command, &integrated.env, &base, &lines) else {
            continue;
        };
        // An integration that did not run forks nothing: its preexec marks
        // prove it ran.
        let marks = count(&forks.output, b"\x1b]133;C");
        assert!(
            marks >= lines.len(),
            "{name}: {marks} OSC 133;C marks for {} commands (the integration did not run): {:?}",
            lines.len(),
            String::from_utf8_lossy(&forks.output[forks.output.len().saturating_sub(600)..])
        );
        control.0.push(plain_shell.startup);
        control.1.push(plain_shell.typing);
        startup_min = startup_min.min(forks.startup);
        typing_min = typing_min.min(forks.typing);
        let (Some(control_startup), Some(control_typing)) =
            (stable_min(&control.0), stable_min(&control.1))
        else {
            verdict = format!(
                "unstable baseline: the control minimum came from one rep only (startup {:?}, \
                 {} commands {:?}); host noise may hide integration forks, rerun on an idle host",
                control.0,
                lines.len(),
                control.1
            );
            continue;
        };
        if startup_min <= control_startup && typing_min <= control_typing + budget {
            fs::remove_dir_all(&base).unwrap();
            return;
        }
        verdict = format!(
            "the daemon-integrated shell forked {startup_min} times to its first prompt and \
             {typing_min} times for {} commands, the same shell without the integration \
             {control_startup} and {control_typing} (budget 0 and {budget}; minimum of the reps)",
            lines.len()
        );
    }
    panic!("{name}: {verdict} ({MAX_REPS} reps)");
}

#[test]
fn fork_count_zsh_forks_nothing() {
    serial(|| {
        let Some(zsh) = find(&["/bin/zsh", "/usr/bin/zsh"]) else {
            return skip("zsh", "zsh is not installed");
        };
        assert_no_extra_forks("zsh", Shell::Zsh, &zsh, "", 0);
    });
}

#[test]
fn fork_count_fish_forks_nothing() {
    serial(|| {
        let Some(fish) = find(&["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"])
        else {
            return skip("fish", "fish is not installed");
        };
        assert_no_extra_forks("fish", Shell::Fish, &fish, "", 0);
    });
}

/// bash forks nothing at startup with any PROMPT_COMMAND, and nothing per
/// command on bash 5.3 (Ghostty's `$(builtin history 1)` before 72578da forks
/// once); bash 4.4-5.2 forks twice per command (Ghostty's PS0 command
/// substitution and the history read in it), and no more.
#[test]
fn fork_count_bash_forks_nothing_at_startup_or_per_command_on_bash_5_3() {
    serial(|| {
        // Apple's /bin/bash gets no integration (see detect_shell).
        let Some(bash) = find(&["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"])
        else {
            skip("bash5.3", "an integrated bash is not installed");
            return skip("bash", "an integrated bash is not installed");
        };
        let version = std::process::Command::new(&bash)
            .args(["-c", "printf '%s %s' \"${BASH_VERSINFO[0]}\" \"${BASH_VERSINFO[1]}\""])
            .output()
            .unwrap();
        let version = String::from_utf8_lossy(&version.stdout).into_owned();
        let mut parts = version.split(' ').map(|part| part.parse::<u32>().unwrap_or(0));
        let (major, minor) = (parts.next().unwrap_or(0), parts.next().unwrap_or(0));
        let bash_5_3 = (major, minor) >= (5, 3);
        if !bash_5_3 {
            skip(
                "bash5.3",
                &format!("{} is bash {major}.{minor}, not 5.3 or later", bash.display()),
            );
        }
        if (major, minor) < (4, 4) {
            return skip(
                "bash",
                &format!("bash {major}.{minor} is older than 4.4 (Ghostty uses bash-preexec)"),
            );
        }
        let budget = if bash_5_3 { 0 } else { 2 };
        eprintln!("{}: bash {major}.{minor}, budget {budget} per command", bash.display());
        for (home, bashrc_extra) in [
            ("plain", ""),
            ("pc-string", "PROMPT_COMMAND='history -a'\n"),
            ("pc-array", "PROMPT_COMMAND=(history\\ -a)\n"),
        ] {
            assert_no_extra_forks(
                &format!("bash-{home}"),
                Shell::Bash,
                &bash,
                bashrc_extra,
                budget,
            );
        }
    });
}
