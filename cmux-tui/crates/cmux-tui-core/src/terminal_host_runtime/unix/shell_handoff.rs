//! Prepared terminals (new-terminal-100x): a standby host that already runs
//! its PTY and the shell's launcher before it knows its terminal.
//!
//! A new terminal used to open its PTY and start login(1) and its shell only
//! after its create reached the host; login(1) alone prints its first text
//! about 40 ms later. A standby host may get a [`MessageKind::Prepare`]
//! frame first: a [`HostLaunch`] without the terminal's own ids
//! ([`HANDOFF_KEYS`]). It opens the PTY and starts the launch as usual,
//! except that the program it reaches last is the launcher
//! (`__shell-handoff`): directly, or after login(1) in the bash script that
//! would exec the shell. The launcher waits on the PTY for one line.
//!
//! When the Launch for a terminal names the same directory, command, TERM
//! and environment apart from those ids ([`Handoff::between`]), the host
//! turns the PTY's echo off and writes the ids as that line; the launcher
//! turns echo back on and execs the shell with them, exactly as the cold
//! launch would have. The line travels through the PTY, so it survives
//! login(1) (which keeps no extra descriptors), and it is never shown. Any
//! other Launch kills the prepared launch (closing its PTY hangs its session
//! up) and launches cold. A host that never bootstraps ends at its pipe's
//! EOF, and its session with it: a prepared shell never outlives its daemon.

use std::collections::BTreeMap;
use std::io::{self, Read, Write as _};

use anyhow::Context as _;
use base64::Engine as _;
use cmux_pty::MasterPty;

use super::*;

/// Environment keys that name one terminal; a prepared launch has none and
/// gets them at handout. Everything else must match.
pub(crate) const HANDOFF_KEYS: [&str; 8] = [
    "CMUX_SURFACE_ID",
    "CMUX_PANEL_ID",
    "CMUX_WORKSPACE_ID",
    "CMUX_TAB_ID",
    "CMUX_PANE_ID",
    "CMUX_TUI_TERMINAL_ID",
    crate::launch_credential::LAUNCH_CREDENTIAL_ENV,
    "AGENT_BROWSER_SESSION",
];

/// argv[1] of the launcher (the host's own executable).
pub const SHELL_HANDOFF_ARG: &str = "__shell-handoff";

/// The handoff line's start; the rest is base64, then a newline.
const LINE_PREFIX: &str = "CMUXHANDOFF1:";

/// The longest handoff line: the PTY's canonical input limit (MAX_CANON,
/// 1024 on macOS) with room. A longer one launches cold.
const MAX_LINE: usize = 1000;

pub(crate) fn is_handoff_key(key: &str) -> bool {
    HANDOFF_KEYS.contains(&key)
}

/// `launch` without its identity and the terminal's own ids: what a standby
/// host can run before it knows its terminal.
pub(crate) fn prepare_template(launch: &HostLaunch) -> HostLaunch {
    let mut template = launch.clone();
    template.endpoint.clear();
    template.record_path.clear();
    template.seed.clear();
    template.workspace_key.clear();
    template.extra_env.retain(|(key, _)| !is_handoff_key(key));
    template
}

/// What turns a prepared launch into a terminal's own: the ids to set and
/// unset, and whether the PTY echoed before the handout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Handoff {
    pub(crate) set: Vec<(String, String)>,
    pub(crate) unset: Vec<String>,
    pub(crate) echo: bool,
}

/// The effective value of each key (the last one wins, as in the spawn).
fn effective(env: &[(String, String)]) -> BTreeMap<&str, &str> {
    env.iter().map(|(key, value)| (key.as_str(), value.as_str())).collect()
}

impl Handoff {
    /// The handoff from `prepared` to `launch`, or None when they differ in
    /// more than the terminal's own ids (or `launch` replays a screen).
    pub(crate) fn between(prepared: &HostLaunch, launch: &HostLaunch) -> Option<Self> {
        if prepared.cwd != launch.cwd
            || prepared.command != launch.command
            || prepared.term != launch.term
            || !launch.seed.is_empty()
        {
            return None;
        }
        let (before, after) = (effective(&prepared.extra_env), effective(&launch.extra_env));
        let shared = |env: &BTreeMap<&str, &str>| {
            env.iter()
                .filter(|(key, _)| !is_handoff_key(key))
                .map(|(key, value)| (key.to_string(), value.to_string()))
                .collect::<BTreeMap<_, _>>()
        };
        if shared(&before) != shared(&after) {
            return None;
        }
        let set = after
            .iter()
            .filter(|(key, _)| is_handoff_key(key))
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        let unset = before
            .keys()
            .filter(|key| is_handoff_key(key) && !after.contains_key(*key))
            .map(|key| key.to_string())
            .collect();
        Some(Self { set, unset, echo: true })
    }

    /// The line the host writes to the PTY.
    pub(crate) fn encode_line(&self) -> String {
        let engine = base64::engine::general_purpose::STANDARD;
        let mut text = String::new();
        text.push_str(if self.echo { "E\n" } else { "N\n" });
        for (key, value) in &self.set {
            text.push_str(&format!("S {} {}\n", engine.encode(key), engine.encode(value)));
        }
        for key in &self.unset {
            text.push_str(&format!("U {}\n", engine.encode(key)));
        }
        format!("{LINE_PREFIX}{}\n", engine.encode(text))
    }

    /// The handoff in `line` (without its newline).
    pub(crate) fn decode_line(line: &str) -> anyhow::Result<Self> {
        let engine = base64::engine::general_purpose::STANDARD;
        let body = line.strip_prefix(LINE_PREFIX).context("not a handoff line")?;
        let text = String::from_utf8(engine.decode(body.trim_end())?)?;
        let mut lines = text.lines();
        let echo = match lines.next() {
            Some("E") => true,
            Some("N") => false,
            _ => anyhow::bail!("handoff line has no echo flag"),
        };
        let field = |value: &str| -> anyhow::Result<String> {
            Ok(String::from_utf8(engine.decode(value)?)?)
        };
        let (mut set, mut unset) = (Vec::new(), Vec::new());
        for line in lines {
            let parts = line.split(' ').collect::<Vec<_>>();
            match parts.as_slice() {
                ["S", key, value] => set.push((field(key)?, field(value)?)),
                ["U", key] => unset.push(field(key)?),
                _ => anyhow::bail!("bad handoff entry"),
            }
        }
        for key in set.iter().map(|(key, _)| key).chain(&unset) {
            anyhow::ensure!(is_handoff_key(key), "handoff names {key}, not a terminal id");
        }
        Ok(Self { set, unset, echo })
    }
}

/// The argv a prepared launch spawns: `launch`'s (login(1)-wrapped when
/// marked), with the launcher `waiter` in front of the shell.
pub(crate) fn prepared_argv(launch: &HostLaunch, waiter: &str) -> anyhow::Result<Vec<String>> {
    anyhow::ensure!(!waiter.contains('\''), "launcher path has a quote");
    // Under login(1): the launcher prints the ids as exports for this bash,
    // which then execs the shell exactly as `login_shell::SCRIPT` does.
    let script = format!(
        "ids=\"$('{waiter}' {SHELL_HANDOFF_ARG} --print)\" || exit 1; eval \"$ids\"; {}",
        crate::login_shell::SCRIPT
    );
    if let Some(login) =
        crate::login_shell::wrap_with_script(&launch.command, &launch.extra_env, &script)
    {
        return Ok(login);
    }
    let mut argv =
        vec![waiter.to_owned(), SHELL_HANDOFF_ARG.to_owned(), "--exec".to_owned(), "--".to_owned()];
    argv.extend(launch.command.iter().cloned());
    Ok(argv)
}

/// A PTY and its prepared launch, before the host knows its terminal.
pub(crate) struct PreparedShell {
    template: HostLaunch,
    master: Option<Box<dyn MasterPty + Send>>,
    child: Option<Box<dyn cmux_pty::Child + Send + Sync>>,
}

impl PreparedShell {
    /// Open the PTY and start `template`'s launch up to the launcher.
    pub(crate) fn start(template: HostLaunch) -> anyhow::Result<Self> {
        let cell_pixels = (template.cell_pixels.0.max(1), template.cell_pixels.1.max(1));
        let pty = cmux_pty::open(pty_size(template.cols, template.rows, cell_pixels))?;
        let waiter = std::env::current_exe().context("the host's own executable")?;
        let argv = prepared_argv(&template, &waiter.to_string_lossy())?;
        let command = host_pty_command(&template, &argv)?;
        let cmux_pty::SpawnedPty { master, child } = pty.spawn(command)?;
        Ok(Self { template, master: Some(master), child: Some(child) })
    }

    /// Hand the prepared launch to `launch`: resize the PTY, write the ids
    /// line, and return the PTY and its child for the host's runtime. None
    /// (the prepared session ends as this drops) when `launch` differs from
    /// it, its child already ended, or its line would not fit.
    pub(crate) fn hand_off(
        mut self,
        launch: &HostLaunch,
    ) -> Option<(Box<dyn MasterPty + Send>, HostChild)> {
        let mut handoff = Handoff::between(&self.template, launch)?;
        let alive = self.child.as_mut().is_some_and(|child| matches!(child.try_wait(), Ok(None)));
        if !alive {
            return None;
        }
        let fd = self.master.as_ref().and_then(|master| master.as_raw_fd())?;
        let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
        let size = pty_size(launch.cols, launch.rows, cell_pixels);
        let resized =
            matches!(self.master.as_ref().map(|master| master.resize(size)), Some(Ok(())));
        if !resized {
            return None;
        }
        // Echo off for the line, so it never shows; the launcher restores it.
        let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
        // SAFETY: tcgetattr writes into `termios` on the PTY this owns.
        if unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) } != 0 {
            return None;
        }
        // SAFETY: tcgetattr succeeded, so `termios` is initialized.
        let mut termios = unsafe { termios.assume_init() };
        handoff.echo = termios.c_lflag & libc::ECHO != 0;
        let line = handoff.encode_line();
        if line.len() > MAX_LINE {
            return None;
        }
        termios.c_lflag &= !libc::ECHO;
        // SAFETY: a valid termios for the PTY this owns.
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &termios) } != 0 {
            return None;
        }
        if write_all_fd(fd, line.as_bytes()).is_err() {
            return None;
        }
        let (Some(master), Some(child)) = (self.master.take(), self.child.take()) else {
            return None;
        };
        let process_group_leader = master.process_group_leader();
        Some((master, HostChild::Spawned(SpawnedPtyChild::new(child, process_group_leader))))
    }
}

impl Drop for PreparedShell {
    fn drop(&mut self) {
        // Closing the PTY hangs its session up (login(1) included, which
        // runs as root); the direct child is also killed and reaped.
        drop(self.master.take());
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = thread::Builder::new().name("terminal-host-prepared-reap".into()).spawn(
                move || {
                    let _ = child.wait();
                },
            );
        }
    }
}

fn write_all_fd(fd: RawFd, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        // SAFETY: writes from a live slice to a descriptor the caller owns.
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        bytes = &bytes[written as usize..];
    }
    Ok(())
}

/// The launcher (`<host> __shell-handoff --exec -- ARGV...` or `--print`):
/// read the handoff line from the PTY, restore its echo, then exec ARGV with
/// the ids (`--exec`) or print them as `export`/`unset` lines for the bash
/// under login(1) (`--print`). It never returns on success; any failure
/// exits 1 (the PTY hung up, or a bad line), which ends the terminal.
pub fn serve_shell_handoff(args: &[String]) -> ! {
    let code = if run_shell_handoff(args).is_ok() { 0 } else { 1 };
    // crash-allow: the launcher process's own exit (it has no daemon state); --print ends here, --exec only on a failure.
    std::process::exit(code)
}

fn run_shell_handoff(args: &[String]) -> anyhow::Result<()> {
    let args = args.iter().skip_while(|arg| *arg != SHELL_HANDOFF_ARG).skip(1).collect::<Vec<_>>();
    let line = read_line_from_tty()?;
    let handoff = Handoff::decode_line(&line)?;
    if handoff.echo {
        // SAFETY: tcgetattr/tcsetattr on this process's own stdin.
        unsafe {
            let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
            if libc::tcgetattr(libc::STDIN_FILENO, termios.as_mut_ptr()) == 0 {
                let mut termios = termios.assume_init();
                termios.c_lflag |= libc::ECHO;
                libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &termios);
            }
        }
    }
    match args.first().map(|arg| arg.as_str()) {
        Some("--print") => {
            let mut out = String::new();
            for (key, value) in &handoff.set {
                out.push_str(&format!("export {key}='{}'\n", value.replace('\'', "'\\''")));
            }
            for key in &handoff.unset {
                out.push_str(&format!("unset {key}\n"));
            }
            io::stdout().write_all(out.as_bytes())?;
            Ok(())
        }
        Some("--exec") => {
            let argv =
                args.iter().skip(1).skip_while(|arg| arg.as_str() == "--").collect::<Vec<_>>();
            let (program, rest) = argv.split_first().context("no shell to exec")?;
            let mut command = Command::new(program);
            command.args(rest.iter().map(|arg| arg.as_str()));
            for (key, value) in &handoff.set {
                command.env(key, value);
            }
            for key in &handoff.unset {
                command.env_remove(key);
            }
            Err(command.exec().into())
        }
        _ => anyhow::bail!("usage: {SHELL_HANDOFF_ARG} --exec -- ARGV... | --print"),
    }
}

/// One line from stdin, one byte at a time, so nothing typed after it is
/// taken from the shell.
fn read_line_from_tty() -> anyhow::Result<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    let mut stdin = io::stdin().lock();
    loop {
        match stdin.read(&mut byte) {
            Ok(0) => anyhow::bail!("the PTY closed before the handoff"),
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) => {
                line.push(byte[0]);
                anyhow::ensure!(line.len() <= MAX_LINE, "handoff line is too long");
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Ok(String::from_utf8(line)?)
}

#[cfg(test)]
#[path = "shell_handoff_tests.rs"]
mod tests;
