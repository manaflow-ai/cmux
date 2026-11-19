//! A freed terminal's shell comes back as the person left it
//! (`crate::shell_state`). Each test starts the real shell with the daemon's
//! integration (the scripts `materialize` writes, the launch `apply`
//! builds) on a pty, changes its state at the prompt, asks it to save
//! exactly as a park does (`save_all`: a request, SIGWINCH, the ack), ends
//! it, hands the files to a new shell (`take_for_restore`) and checks in
//! that shell that the state came back, that the restore printed nothing
//! (its output before the first prompt is a fresh shell's) and that it
//! deleted its files. A shell that is not installed skips its test.

use super::test_pty::{self, TestPty, shell_path};
use super::*;
use crate::resource::TerminalPublicId;
use crate::shell_state::{SaveOutcome, ShellStateDir, save_all, signal_shell};
use std::time::{Duration, Instant};

const PROMPT: &[u8] = b"@> ";
const SYSTEM_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

struct Fixture {
    base: PathBuf,
    home: PathBuf,
    root: PathBuf,
    dir: ShellStateDir,
    terminal: TerminalPublicId,
}

impl Fixture {
    fn new(name: &str, shell: Shell) -> Self {
        let base = std::env::temp_dir().join(format!(
            "cmux-tui-shell-state-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let home = base.join("home");
        fs::create_dir_all(home.join("d1")).unwrap();
        fs::create_dir_all(home.join("d2")).unwrap();
        let base = fs::canonicalize(&base).unwrap();
        let home = base.join("home");
        let history = home.join("history");
        fs::write(&history, "line-from-the-history-file\n").unwrap();
        match shell {
            Shell::Bash => fs::write(
                home.join(".bashrc"),
                format!(
                    "PS1='@> '\nHISTFILE={}\nHISTSIZE=1000\nalias ll='ls -l'\nfrom_rc=rc\n",
                    history.display()
                ),
            )
            .unwrap(),
            Shell::Zsh => {
                // No system rc files: a distribution's global zshrc can stop
                // at an interactive compinit question.
                fs::write(home.join(".zshenv"), "unsetopt global_rcs\n").unwrap();
                fs::write(
                    home.join(".zshrc"),
                    format!(
                        "PS1='@> '\nHISTFILE={}\nHISTSIZE=1000\nSAVEHIST=1000\nalias ll='ls -l'\nfrom_rc=rc\n",
                        history.display()
                    ),
                )
                .unwrap();
            }
            Shell::Fish => unreachable!("fish never saves its state"),
        }
        let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
        let dir = ShellStateDir::new(base.join("shell-state"));
        Self { base, home, root, dir, terminal: TerminalPublicId::random().unwrap() }
    }

    fn launch(&self, shell: Shell, exe: &Path, incognito: bool) -> TestPty {
        let prefix = self.dir.prefix(&self.terminal).unwrap();
        let mut env = vec![
            ("HOME".to_string(), self.home.to_string_lossy().into_owned()),
            ("PATH".to_string(), SYSTEM_PATH.to_string()),
            (
                crate::shell_state::SHELL_STATE_ENV.to_string(),
                prefix.to_string_lossy().into_owned(),
            ),
        ];
        if shell == Shell::Zsh {
            env.push(("ZDOTDIR".to_string(), self.home.to_string_lossy().into_owned()));
        }
        if incognito {
            keep_no_history(&mut env);
        }
        let lookup = {
            let env = env.clone();
            move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
        };
        let launched = apply(
            shell,
            &self.root,
            vec![exe.to_string_lossy().into_owned()],
            env,
            &lookup,
            &ghostty_files::read(&lookup),
        );
        let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
        command.args(launched.command[1..].iter().cloned());
        command.cwd(&self.home);
        command.env("TERM", "xterm-256color");
        for (key, value) in &launched.env {
            command.env(key.clone(), value.clone());
        }
        let size = cmux_pty::PtySize { rows: 30, cols: 160, pixel_width: 0, pixel_height: 0 };
        TestPty::spawn(size, command)
    }

    fn files(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(self.dir_root())
            .map(|entries| {
                entries
                    .flatten()
                    .map(|entry| entry.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }

    fn dir_root(&self) -> PathBuf {
        self.base.join("shell-state")
    }

    fn save(&self, pty: &TestPty) -> SaveOutcome {
        let pid = pty.spawned.child.process_id().unwrap();
        let outcomes = save_all(
            &self.dir,
            &[(self.terminal.clone(), pid)],
            // A loaded CI host; the daemon's own bound is 500 ms.
            Duration::from_secs(5),
            &signal_shell,
        );
        outcomes[&self.terminal].clone()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

/// Reads until `needle` appears after `from`; the offset just past it.
fn read_until(pty: &mut TestPty, output: &mut Vec<u8>, from: usize, needle: &[u8]) -> usize {
    let deadline = Instant::now() + Duration::from_secs(30);
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

/// Types `line` at the prompt and waits for the next prompt; the output.
fn run(pty: &mut TestPty, output: &mut Vec<u8>, line: &str) -> String {
    let from = output.len();
    pty.write(format!("{line}\n").as_bytes());
    // The echoed line, then the command's output and the next prompt.
    let echoed = read_until(pty, output, from, b"\n");
    let end = read_until(pty, output, echoed, PROMPT);
    String::from_utf8_lossy(&output[echoed..end]).into_owned()
}

/// What a person sees in `bytes`: no escape sequences, no carriage returns.
fn visible(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    let mut out = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => match chars.next() {
                Some(']') => {
                    // OSC: to BEL or ST.
                    while let Some(c) = chars.next() {
                        if c == '\x07' || (c == '\x1b' && chars.next_if_eq(&'\\').is_some()) {
                            break;
                        }
                    }
                }
                Some('[') => {
                    while let Some(c) = chars.next() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                _ => {}
            },
            '\r' | '\x01' | '\x02' | '\x07' | '\x08' => {}
            c => out.push(c),
        }
    }
    out
}

/// Starts `exe`, reads to its first prompt; the shell, its output and how
/// long the prompt took.
fn start(
    fixture: &Fixture,
    shell: Shell,
    exe: &Path,
    incognito: bool,
) -> (TestPty, Vec<u8>, Duration) {
    let started = Instant::now();
    let mut pty = fixture.launch(shell, exe, incognito);
    let mut output = Vec::new();
    read_until(&mut pty, &mut output, 0, PROMPT);
    let took = started.elapsed();
    (pty, output, took)
}

/// Waits until the shell at its prompt has run its first-prompt hooks
/// (zsh arms its trap there): a command round trip.
fn settle(pty: &mut TestPty, output: &mut Vec<u8>) {
    run(pty, output, "true");
}

fn state_comes_back(name: &str, shell: Shell, setup: &[&str], check: &str, expect: &[String]) {
    let Some(exe) = shell_path(shell) else {
        test_pty::skip("SHELL-STATE-SKIP", name, "the shell is not installed");
        return;
    };
    let fixture = Fixture::new(name, shell);
    let (mut pty, mut output, _) = start(&fixture, shell, &exe, false);
    settle(&mut pty, &mut output);
    for line in setup {
        run(&mut pty, &mut output, line);
    }
    let before = output.len();
    let saving = Instant::now();
    assert_eq!(fixture.save(&pty), SaveOutcome::Saved, "{name}: {}", visible(&output));
    let saved_in = saving.elapsed();
    // The save draws nothing (zsh redraws the same prompt on SIGWINCH).
    std::thread::sleep(Duration::from_millis(200));
    while let Ok(chunk) = pty.recv_timeout(Duration::from_millis(50)) {
        output.extend_from_slice(&chunk);
    }
    let drawn = visible(&output[before..]).replace("@> ", "");
    assert!(drawn.trim().is_empty(), "{name}: the save printed {drawn:?}");
    drop(pty);
    assert!(fixture.dir.take_for_restore(&fixture.terminal), "{name}: {:?}", fixture.files());

    let (mut fresh, fresh_output, fresh_took) = {
        // A fresh shell of the same terminal, for the output and the time
        // to the first prompt without a restore. The restore files are
        // moved aside while it starts.
        let aside = fixture.base.join("aside");
        fs::rename(fixture.dir_root(), &aside).unwrap();
        let started = start(&fixture, shell, &exe, false);
        let _ = fs::remove_dir_all(fixture.dir_root());
        fs::rename(&aside, fixture.dir_root()).unwrap();
        started
    };
    fresh.write_quietly(b"exit\n");
    drop(fresh);
    let (mut pty, mut output, restored_took) = start(&fixture, shell, &exe, false);
    assert_eq!(
        visible(&output),
        visible(&fresh_output),
        "{name}: the restore printed something before the first prompt"
    );
    let shown = run(&mut pty, &mut output, check);
    for want in expect {
        assert!(shown.contains(want.as_str()), "{name}: no {want:?} in {shown:?}");
    }
    let left: Vec<String> =
        fixture.files().into_iter().filter(|file| file.contains("restore")).collect();
    assert!(left.is_empty(), "{name}: the restore left {left:?}");
    eprintln!(
        "SHELL-STATE {name}: save answered in {saved_in:?}; first prompt {restored_took:?} \
         restored, {fresh_took:?} fresh"
    );
}

#[test]
fn a_restored_bash_has_the_state_the_person_left() {
    let check = "printf 'V=[%s]X=[%s]\\n' \"$plain\" \"$(declare -p shipped)\"; greet x; hello; \
                 alias ll 2>/dev/null || echo no-ll; shopt -q globstar && echo globstar-on; \
                 echo \"DIRS=$(dirs -p | tr '\\n' ':')\"; echo \"UMASK=$(umask)\"; \
                 echo \"HIST=$(history | grep -c '[m]arker-in-history')\"; trap -p USR2; \
                 echo \"ARR=${arr[1]}\"; echo \"RC=$from_rc\"";
    state_comes_back(
        "bash",
        Shell::Bash,
        &[
            "plain='kept value'",
            "shipped=1; export shipped",
            "arr=(a 'b c')",
            "greet() { echo greet-$1; }",
            "alias hello='echo hello-alias'",
            "unalias ll",
            "shopt -s globstar",
            "pushd d1 >/dev/null",
            "pushd ../d2 >/dev/null",
            "umask 027",
            "trap 'echo usr2' USR2",
            "echo marker-in-history",
        ],
        check,
        &[
            "V=[kept value]X=[declare -x shipped=\"1\"]".to_string(),
            "greet-x".to_string(),
            "hello-alias".to_string(),
            "no-ll".to_string(),
            "globstar-on".to_string(),
            "DIRS=~/d2:~/d1:~:".to_string(),
            "UMASK=0027".to_string(),
            "HIST=1".to_string(),
            "echo usr2".to_string(),
            "ARR=b c".to_string(),
            "RC=rc".to_string(),
        ],
    );
}

#[test]
fn a_restored_zsh_has_the_state_the_person_left() {
    let check = "print -r -- \"V=[$plain]X=[${(t)shipped}]\"; greet x; hello; \
                 alias ll >/dev/null || echo no-ll; [[ -o extendedglob ]] && echo extglob-on; \
                 print -r -- \"DIRS=${(j/:/)${(D)dirstack}}\"; echo \"UMASK=$(umask)\"; \
                 echo \"HIST=$(fc -ln 1 | grep -c '[m]arker-in-history')\"; trap; \
                 echo \"ARR=${arr[2]}\"; echo \"RC=$from_rc\"; print -r -- \"PWD=${(D)PWD}\"";
    state_comes_back(
        "zsh",
        Shell::Zsh,
        &[
            "plain='kept value'",
            "export shipped=1",
            "arr=(a 'b c')",
            "greet() { echo greet-$1 }",
            "alias hello='echo hello-alias'",
            "unalias ll",
            "setopt extended_glob",
            "pushd d1 >/dev/null",
            "pushd ../d2 >/dev/null",
            "umask 027",
            "trap 'echo usr2' USR2",
            "echo marker-in-history",
        ],
        check,
        &[
            "V=[kept value]X=[scalar-export]".to_string(),
            "greet-x".to_string(),
            "hello-alias".to_string(),
            "no-ll".to_string(),
            "extglob-on".to_string(),
            "DIRS=~/d1:~".to_string(),
            "PWD=~/d2".to_string(),
            "UMASK=027".to_string(),
            "HIST=1".to_string(),
            "echo usr2".to_string(),
            "ARR=b c".to_string(),
            "RC=rc".to_string(),
        ],
    );
}

/// A shell with a job, or an fd the person opened, answers that it cannot
/// be saved: no restore could give either back, so its tab keeps running.
fn unsaveable(name: &str, shell: Shell, line: &str, why: &str) {
    let Some(exe) = shell_path(shell) else {
        test_pty::skip("SHELL-STATE-SKIP", name, "the shell is not installed");
        return;
    };
    let fixture = Fixture::new(name, shell);
    let (mut pty, mut output, _) = start(&fixture, shell, &exe, false);
    settle(&mut pty, &mut output);
    run(&mut pty, &mut output, line);
    assert_eq!(fixture.save(&pty), SaveOutcome::Unsaveable(why.to_string()), "{name}");
    assert!(
        !fixture.dir.take_for_restore(&fixture.terminal),
        "{name}: an unsaveable state restores"
    );
    assert!(fixture.files().iter().all(|file| !file.contains("restore")), "{:?}", fixture.files());
}

#[test]
fn a_bash_with_a_job_or_an_open_fd_is_not_saveable() {
    unsaveable("bash-job", Shell::Bash, "sleep 5 &", "jobs");
    unsaveable("bash-fd", Shell::Bash, "exec 7>/dev/null", "open-fd-7");
}

#[test]
fn a_zsh_with_a_job_or_an_open_fd_is_not_saveable() {
    unsaveable("zsh-job", Shell::Zsh, "sleep 5 &", "jobs");
    unsaveable("zsh-fd", Shell::Zsh, "exec 7>/dev/null", "open-fd-7");
}

/// An incognito terminal's save writes no history, and its shell writes
/// none to the person's file.
#[test]
fn an_incognito_bash_saves_no_history() {
    let shell = Shell::Bash;
    let Some(exe) = shell_path(shell) else {
        test_pty::skip("SHELL-STATE-SKIP", "bash-incognito", "the shell is not installed");
        return;
    };
    let fixture = Fixture::new("bash-incognito", shell);
    let (mut pty, mut output, _) = start(&fixture, shell, &exe, true);
    run(&mut pty, &mut output, "echo private-marker-$((6*7))");
    assert_eq!(fixture.save(&pty), SaveOutcome::Saved);
    assert!(
        fixture.files().iter().all(|file| !file.ends_with(".history")),
        "an incognito save wrote history: {:?}",
        fixture.files()
    );
    let kept = fs::read_to_string(fixture.home.join("history")).unwrap_or_default();
    assert!(!kept.contains("private-marker"), "{kept:?}");
}

/// A shell started without the integration's variable ignores SIGWINCH as
/// any program does: no answer, and it keeps running.
#[test]
fn a_shell_without_the_trap_does_not_answer_and_keeps_running() {
    let Some(exe) = shell_path(Shell::Bash) else {
        test_pty::skip("SHELL-STATE-SKIP", "bash-no-trap", "the shell is not installed");
        return;
    };
    let fixture = Fixture::new("bash-no-trap", Shell::Bash);
    let mut command = cmux_pty::PtyCommand::new(exe.to_string_lossy().into_owned());
    command.args(["--norc", "--noprofile", "-i"].map(String::from));
    command.env("PS1", "@> ");
    command.env("TERM", "xterm-256color");
    let size = cmux_pty::PtySize { rows: 24, cols: 120, pixel_width: 0, pixel_height: 0 };
    let mut pty = TestPty::spawn(size, command);
    let mut output = Vec::new();
    read_until(&mut pty, &mut output, 0, PROMPT);
    let pid = pty.spawned.child.process_id().unwrap();
    let outcomes = save_all(
        &fixture.dir,
        &[(fixture.terminal.clone(), pid)],
        Duration::from_millis(300),
        &signal_shell,
    );
    assert_eq!(outcomes[&fixture.terminal], SaveOutcome::NoAck);
    assert!(pty.spawned.child.try_wait().unwrap().is_none(), "the shell ended");
    assert!(run(&mut pty, &mut output, "echo still-$((1+1))").contains("still-2"));
    assert!(fixture.files().is_empty(), "{:?}", fixture.files());
}
