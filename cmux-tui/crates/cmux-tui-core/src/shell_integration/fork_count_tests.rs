//! Shell integration costs nothing per prompt, on the scripts the daemon
//! really writes: `materialize` puts `SCRIPTS` on disk and `apply` builds the
//! launch, exactly as `integrate_default_shell` does for a daemon spawn with
//! no app layer. Each test starts the shell on a pty, counts what it forks
//! from the spawn to its first prompt (startup), then types commands at the
//! prompt (half of them `cd` between a plain directory and a git repository,
//! so cwd- and git-triggered work is counted too) and counts what it forks
//! for them.
//!
//! How forks are counted. On macOS the kernel counts them for the shell
//! alone (`fork_watch`: a kqueue `NOTE_FORK` knote on the shell's pid), so
//! no other process on the host, and no other test of the run, changes the
//! count: the tests run in any fleet step, beside anything. The shell starts
//! behind a gate (Apple's /bin/bash waits for a line, then execs the shell),
//! so the watch is on the pid before the shell runs; the shell's exec, which
//! the watch must see after the gate opens, shows it watches the right pid.
//! The kernel's count is the shell's own forks, not its children's, and the
//! kqueue merges forks that come between two reads into one event: a count
//! of 0 is exact (every fork of a descendant starts with one of the shell),
//! a count above 0 is a lower bound. So the macOS checks are the budget-0
//! ones (zsh, fish, bash 5.3), and their verdict is exact when the control
//! counts 0 (each test prints both counts in a `FORK-COUNT` line). Elsewhere
//! (Linux) the count is the gap in the system PID counter (PIDs are handed
//! out in sequence), which every process forks into, the shell's
//! descendants included; other processes only make a gap larger, so each
//! count is the minimum over reps, and nextest runs these tests one at a
//! time with every test thread (group `fork-count-alone` in
//! `cmux-tui/.config/nextest.toml`, Linux only).
//!
//! The integrated shell may fork no more than the same shell without the
//! integration: 0 at startup, and per command 0, except on bash 4.4-5.2,
//! whose only pre-command hook is Ghostty's PS0 command substitution (a
//! fork of the shell, whose subshell forks once more for the history read:
//! 2 per command in the PID gap). Only Linux checks that budget: the
//! kernel's count would see 1 and miss every fork inside the PS0 subshell.
//! A control minimum that only one rep reached is host noise, not a
//! baseline, and fails the test ("unstable baseline") instead of hiding
//! forks; on macOS other processes do not change the control (a control
//! above 0 can still vary, by merged events). bash runs in
//! three homes: no PROMPT_COMMAND, a string one and an array one (the
//! integration reads its type at startup).
//!
//! It needs ghostty-next 72578da or later: before it, Ghostty's ghostty.bash
//! forks once per command on bash 5.3 (`cmd=$(builtin history 1)`) and once
//! at startup when .bashrc sets PROMPT_COMMAND (`$(builtin declare -p
//! PROMPT_COMMAND)`), on every bash.
//!
//! Which shells run. On macOS all three, on every host: the system's
//! /bin/zsh, and bash 5.3 and fish 4.9.3 from `scripts/ci/pinned-shell.sh`
//! (sha256-pinned; bash compiled and fish unpacked once per host into
//! ~/Library/Caches/cmux/pinned-shells, which needs the network and a C
//! compiler on the first run). A shell it cannot get fails the test: the
//! guard never passes without the shell it checks. Elsewhere a shell that is
//! not installed skips its test with a `FORK-COUNT-SKIP` line (Linux CI has
//! bash 5.2 and no zsh or fish), and so does bash older than 4.4 (Ghostty
//! uses bash-preexec there). On the fleet:
//!
//! ```text
//! cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh \
//!   --arg test --arg shell_integration:: --ref SHA
//! ```
//!
//! The bench (`scripts/cmux-next/shell-integration-bench.py`) counts the same
//! way, and also the app's spawn path (the `Resources/cmux-cli-path` layer),
//! an idle window at the prompt and the time to the first prompt.

use super::test_pty::TestPty;
use super::*;
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

/// Skips the test where its shell is not installed (never on macOS, where
/// `shell_path` always has one).
fn skip(what: &str, why: &str) {
    eprintln!("FORK-COUNT-SKIP {what}: {why}");
}

/// A pinned shell build (`scripts/ci/pinned-shell.sh`, cached per host).
#[cfg(target_os = "macos")]
fn pinned(name: &str) -> PathBuf {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../scripts/ci/pinned-shell.sh");
    let output = std::process::Command::new("/bin/bash")
        .arg(&script)
        .arg(name)
        .output()
        .unwrap_or_else(|error| panic!("{}: {error}", script.display()));
    let stderr = String::from_utf8_lossy(&output.stderr);
    eprint!("{stderr}");
    assert!(
        output.status.success(),
        "{name}: {} failed, so the shell under test cannot run: {stderr}",
        script.display()
    );
    PathBuf::from(String::from_utf8(output.stdout).unwrap().trim())
}

#[cfg(not(target_os = "macos"))]
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
#[cfg(not(target_os = "macos"))]
fn probe_pid() -> u32 {
    let mut child = std::process::Command::new("true").spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    pid
}

/// How the counts were taken, for the `FORK-COUNT` line.
#[cfg(target_os = "macos")]
const COUNTED_BY: &str = "the kernel's count of the shell's own forks (exact at 0)";
#[cfg(not(target_os = "macos"))]
const COUNTED_BY: &str = "the PID gap, minimum of the reps";

/// Forks a reading of the fork count itself adds to the next window: the
/// kernel's count costs none, a PID probe is one process.
#[cfg(target_os = "macos")]
const READ_COST: u32 = 0;
#[cfg(not(target_os = "macos"))]
const READ_COST: u32 = 1;

/// Forks per command of Ghostty's PS0 hook on bash 4.4-5.2, in the PID gap:
/// its command substitution, and the history read that subshell forks.
#[cfg(not(target_os = "macos"))]
const BASH_PS0_FORKS: u32 = 2;

/// The gate a shell starts behind on macOS: Apple's /bin/bash waits for a
/// line and then becomes the shell (`exec` keeps the pid), so the fork watch
/// is on the pid before the shell runs. Not /bin/sh: that is a shim that
/// execs /bin/bash on its own, an exec the watch could take for the shell's.
#[cfg(target_os = "macos")]
const GATE: &str = "read -r go && exec \"$@\"";

/// One shell on a pty, driven by what it prints.
struct Session {
    pty: TestPty,
    output: Vec<u8>,
    #[cfg(target_os = "macos")]
    watch: fork_watch::ForkWatch,
    /// The watch's exec count before the gate opened.
    #[cfg(target_os = "macos")]
    gate_execs: u32,
}

impl Session {
    /// Starts `command`; returns the session and the fork count before the
    /// shell ran (on Linux the PID counter, so the startup window also
    /// holds the shell itself, in the control as in the integrated run).
    fn start(command: &[String], env: &[(String, String)], cwd: &Path) -> (Self, u32) {
        #[cfg(target_os = "macos")]
        let mut pty_command = {
            let mut gated = cmux_pty::PtyCommand::new("/bin/bash");
            gated.args(
                ["-c", GATE, "gate"].map(String::from).into_iter().chain(command.iter().cloned()),
            );
            gated
        };
        #[cfg(not(target_os = "macos"))]
        let mut pty_command = {
            let mut direct = cmux_pty::PtyCommand::new(&command[0]);
            direct.args(command[1..].iter().cloned());
            direct
        };
        // Only the test's env: an inherited ENV, ZDOTDIR or PROMPT_COMMAND
        // would change what the shell runs.
        pty_command.env_clear();
        pty_command.cwd(cwd);
        for (key, value) in env {
            pty_command.env(key.clone(), value.clone());
        }
        let size = cmux_pty::PtySize { rows: 30, cols: 200, pixel_width: 0, pixel_height: 0 };
        #[cfg(not(target_os = "macos"))]
        let start = probe_pid();
        let pty = TestPty::spawn(size, pty_command);
        #[cfg(target_os = "macos")]
        let (session, start) = {
            let watch = fork_watch::ForkWatch::new(pty.pid());
            // The spawn returned after the gate's own exec, so nothing has
            // exec'd since the watch started; the gate forks nothing.
            let gate = watch.counts();
            let mut session = Self { pty, output: Vec::new(), watch, gate_execs: gate.execs };
            // Opens the gate.
            session.write(b"\n");
            (session, gate.forks)
        };
        #[cfg(not(target_os = "macos"))]
        let session = Self { pty, output: Vec::new() };
        (session, start)
    }

    /// The shell's fork count now, every fork before this call included.
    #[cfg(target_os = "macos")]
    fn forks(&self) -> u32 {
        let counts = self.watch.counts();
        // The gate's exec into the shell, after the gate opened: the watch
        // is live on the shell's pid (a watch on another pid sees no exec).
        assert!(
            counts.execs > self.gate_execs,
            "the fork watch saw no exec after the gate opened: it does not watch the shell"
        );
        counts.forks
    }

    /// The system's PID counter now (every process forks into it).
    #[cfg(not(target_os = "macos"))]
    fn forks(&self) -> u32 {
        probe_pid()
    }

    fn wait_for(&mut self, done: impl Fn(&[u8]) -> bool, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !done(self.output.as_slice()) {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.pty.recv_timeout(left) {
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
        self.pty.write(bytes);
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
        // The `TestPty` then kills and reaps the shell.
        self.pty.write_quietly(b"\x15exit\r");
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
    let (mut session, spawn) = Session::start(command, env, cwd);
    session.wait_for(|output| count(output, PROMPT) > 0, "first prompt");
    session.barrier();
    let before = session.forks();
    for line in lines {
        session.run(line);
    }
    session.barrier();
    let after = session.forks();
    let output = std::mem::take(&mut session.output);
    drop(session);
    // Each window excludes the reading that closes it.
    Some(Forks {
        startup: before.checked_sub(spawn)?.checked_sub(READ_COST)?,
        typing: after.checked_sub(before)?.checked_sub(READ_COST)?,
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
        let Some(plain_shell) = count_forks(std::slice::from_ref(&exe), &env, &base, &lines) else {
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
            eprintln!(
                "FORK-COUNT {name}: {startup_min} forks to the first prompt (control \
                 {control_startup}), {typing_min} for {} commands (control {control_typing}, \
                 budget {budget}); {COUNTED_BY}",
                lines.len()
            );
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

/// The shell a test runs: on macOS always one, the system's zsh and the
/// pinned bash 5.3 and fish.
#[cfg(target_os = "macos")]
fn shell_path(shell: Shell) -> Option<PathBuf> {
    Some(match shell {
        Shell::Zsh => PathBuf::from("/bin/zsh"),
        Shell::Bash => pinned("bash-5.3"),
        Shell::Fish => pinned("fish-4.9.3"),
    })
}

/// The shell a test runs, or `None` where it is not installed.
#[cfg(not(target_os = "macos"))]
fn shell_path(shell: Shell) -> Option<PathBuf> {
    match shell {
        Shell::Zsh => find(&["/bin/zsh", "/usr/bin/zsh"]),
        Shell::Bash => find(&["/usr/local/bin/bash", "/usr/bin/bash", "/bin/bash"]),
        Shell::Fish => find(&["/usr/local/bin/fish", "/usr/bin/fish"]),
    }
}

#[test]
fn fork_count_zsh_forks_nothing() {
    let Some(zsh) = shell_path(Shell::Zsh) else {
        return skip("zsh", "zsh is not installed");
    };
    assert_no_extra_forks("zsh", Shell::Zsh, &zsh, "", 0);
}

#[test]
fn fork_count_fish_forks_nothing() {
    let Some(fish) = shell_path(Shell::Fish) else {
        return skip("fish", "fish is not installed");
    };
    assert_no_extra_forks("fish", Shell::Fish, &fish, "", 0);
}

/// bash forks nothing at startup with any PROMPT_COMMAND, and nothing per
/// command on bash 5.3 (Ghostty's `$(builtin history 1)` before 72578da forks
/// once): red at ghostty-next 5555f42 on every Mac. On Linux, bash 4.4-5.2
/// forks `BASH_PS0_FORKS` per command (Ghostty's PS0 command substitution
/// and the history read in it), and no more.
#[test]
fn fork_count_bash_forks_nothing_at_startup_or_per_command_on_bash_5_3() {
    let Some(bash) = shell_path(Shell::Bash) else {
        return skip("bash", "an integrated bash is not installed");
    };
    let version = std::process::Command::new(&bash)
        .args(["-c", "printf '%s %s' \"${BASH_VERSINFO[0]}\" \"${BASH_VERSINFO[1]}\""])
        .output()
        .unwrap();
    let version = String::from_utf8_lossy(&version.stdout).into_owned();
    let mut parts = version.split(' ').map(|part| part.parse::<u32>().unwrap_or(0));
    let (major, minor) = (parts.next().unwrap_or(0), parts.next().unwrap_or(0));
    #[cfg(target_os = "macos")]
    let budget = {
        assert_eq!((major, minor), (5, 3), "{} is not the pinned bash 5.3", bash.display());
        0
    };
    #[cfg(not(target_os = "macos"))]
    let budget = {
        // Apple's /bin/bash 3.2 is not here (macOS takes the pinned bash).
        if (major, minor) < (4, 4) {
            return skip(
                "bash",
                &format!("bash {major}.{minor} is older than 4.4 (Ghostty uses bash-preexec)"),
            );
        }
        if (major, minor) >= (5, 3) { 0 } else { BASH_PS0_FORKS }
    };
    eprintln!("{}: bash {major}.{minor}, budget {budget} per command", bash.display());
    for (home, bashrc_extra) in [
        ("plain", ""),
        ("pc-string", "PROMPT_COMMAND='history -a'\n"),
        ("pc-array", "PROMPT_COMMAND=(history\\ -a)\n"),
    ] {
        assert_no_extra_forks(&format!("bash-{home}"), Shell::Bash, &bash, bashrc_extra, budget);
    }
}
