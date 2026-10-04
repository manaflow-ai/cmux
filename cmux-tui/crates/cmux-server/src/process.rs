//! External commands (`systemctl`, `launchctl`, `loginctl`, `initdb`,
//! `pg_ctl`, `psql`, …) behind one trait, so service and Postgres steps can
//! run against a recording runner in tests and in `--dry-run`.
//!
//! Secrets never go on argv: SQL and passwords travel on stdin or in 0600
//! files named by environment (`PGPASSFILE`).

use std::collections::VecDeque;
use std::ffi::OsString;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Mutex;

use crate::error::{Error, Result};

/// One command: program, arguments, extra environment, optional stdin.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cmd {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub env: Vec<(String, OsString)>,
    pub stdin: Option<Vec<u8>>,
    pub cwd: Option<PathBuf>,
}

impl Cmd {
    pub fn new(program: impl Into<PathBuf>) -> Cmd {
        Cmd { program: program.into(), ..Cmd::default() }
    }

    pub fn arg(mut self, arg: impl Into<OsString>) -> Cmd {
        self.args.push(arg.into());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Cmd
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn env(mut self, key: &str, value: impl Into<OsString>) -> Cmd {
        self.env.push((key.to_owned(), value.into()));
        self
    }

    pub fn stdin(mut self, bytes: impl Into<Vec<u8>>) -> Cmd {
        self.stdin = Some(bytes.into());
        self
    }

    pub fn cwd(mut self, dir: impl Into<PathBuf>) -> Cmd {
        self.cwd = Some(dir.into());
        self
    }

    /// `program arg …` for logs and errors (never includes stdin or env).
    pub fn display(&self) -> String {
        let mut out = self.program.display().to_string();
        for arg in &self.args {
            out.push(' ');
            out.push_str(&arg.to_string_lossy());
        }
        out
    }
}

/// What a command returned.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Output {
    /// `None` when the process was killed by a signal.
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Output {
    pub fn ok(&self) -> bool {
        self.code == Some(0)
    }

    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).trim().to_owned()
    }

    /// The first stderr line, for error messages.
    pub fn stderr_line(&self) -> String {
        String::from_utf8_lossy(&self.stderr).lines().next().unwrap_or("").trim().to_owned()
    }
}

pub trait Runner: Send + Sync {
    /// Runs `cmd` to completion. `Err` only when it could not start.
    fn run(&self, cmd: &Cmd) -> std::io::Result<Output>;

    /// Runs `cmd` and requires exit status 0.
    fn check(&self, cmd: &Cmd) -> Result<Output> {
        let out = self.run(cmd).map_err(|e| Error::io(cmd.display(), e))?;
        if out.ok() {
            Ok(out)
        } else {
            Err(Error::internal(format!(
                "{} exited with {}: {}",
                cmd.display(),
                out.code.map_or("a signal".to_owned(), |c| c.to_string()),
                out.stderr_line()
            )))
        }
    }
}

/// Runs commands on this machine. Stdout and stderr are captured.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemRunner;

impl Runner for SystemRunner {
    fn run(&self, cmd: &Cmd) -> std::io::Result<Output> {
        let mut command = Command::new(&cmd.program);
        command.args(&cmd.args);
        // The re-exec loop guard belongs to this process only.
        command.env_remove(cmux_server_core::reexec::GUARD_ENV);
        for (k, v) in &cmd.env {
            command.env(k, v);
        }
        if let Some(dir) = &cmd.cwd {
            command.current_dir(dir);
        }
        command.stdin(if cmd.stdin.is_some() { Stdio::piped() } else { Stdio::null() });
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = command.spawn()?;
        // Stdin is written on its own thread, so a child that writes a lot
        // before it reads cannot deadlock against us. A child that exits
        // early closes the pipe; its exit status reports why.
        let writer = cmd.stdin.clone().map(|bytes| {
            let mut pipe = child.stdin.take().expect("stdin is piped");
            std::thread::spawn(move || {
                let _ = pipe.write_all(&bytes);
            })
        });
        let out = child.wait_with_output()?;
        if let Some(writer) = writer {
            let _ = writer.join();
        }
        Ok(Output { code: out.status.code(), stdout: out.stdout, stderr: out.stderr })
    }
}

/// Records every command and answers from a script (first matching rule,
/// else success with empty output). For tests and `--dry-run`.
#[derive(Debug, Default)]
pub struct RecordingRunner {
    log: Mutex<Vec<Cmd>>,
    rules: Mutex<VecDeque<(String, Output)>>,
}

impl RecordingRunner {
    pub fn new() -> RecordingRunner {
        RecordingRunner::default()
    }

    /// The next command whose display contains `needle` gets `output`
    /// (each rule answers once).
    pub fn answer(&self, needle: &str, output: Output) {
        self.rules.lock().expect("rules").push_back((needle.to_owned(), output));
    }

    pub fn commands(&self) -> Vec<Cmd> {
        self.log.lock().expect("log").clone()
    }

    /// Display strings of the recorded commands.
    pub fn lines(&self) -> Vec<String> {
        self.commands().iter().map(Cmd::display).collect()
    }
}

impl Runner for RecordingRunner {
    fn run(&self, cmd: &Cmd) -> std::io::Result<Output> {
        self.log.lock().expect("log").push(cmd.clone());
        let line = cmd.display();
        let mut rules = self.rules.lock().expect("rules");
        if let Some(pos) = rules.iter().position(|(needle, _)| line.contains(needle.as_str())) {
            return Ok(rules.remove(pos).expect("position is valid").1);
        }
        Ok(Output { code: Some(0), ..Output::default() })
    }
}
