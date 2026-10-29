//! A frozen copy of the terminal holder as it shipped with wire version 3
//! (`cmux-holder` at feat-cmux-next 9b98307c120), kept only as a test
//! fixture: a newer daemon must adopt a holder an older cmux build started,
//! by the wire version the two settle on (pty-holder.md 2.1: "a holder built
//! from the oldest supported holder commit"). Never edit these files except
//! to replace them with an older shipped holder; never ship this binary.
//!
//! The original crate documentation follows.
//!
//! `cmux-holder`: one small process that holds every PTY of an install.
//!
//! The holder parses no terminal output. It keeps each PTY master in one
//! `poll` set, is the parent of each shell it starts, and keeps a byte ring
//! per terminal so a restarted daemon can catch up. The daemon keeps a dup of
//! every master (passed with `SCM_RIGHTS`), so a crash of either process
//! loses no shell: a new holder takes the masters back with [`wire::Kind::Adopt`],
//! a new daemon re-attaches from the rings. Design:
//! `plans/cmux-next/terminal-host-model-DESIGN.md`.

#![cfg(unix)]

pub mod client;
pub mod holder;
pub mod link;
pub mod pty;
pub mod ring;
pub mod wire;

use std::io::{self, BufRead, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

/// What the daemon asks the holder to start.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SpawnRequest {
    /// The terminal's 128-bit id.
    pub id: [u8; 16],
    pub cols: u16,
    pub rows: u16,
    pub px_w: u16,
    pub px_h: u16,
    pub cwd: Vec<u8>,
    pub argv: Vec<Vec<u8>>,
    /// `KEY=VALUE` entries; the child gets exactly these.
    pub env: Vec<Vec<u8>>,
}

impl SpawnRequest {
    /// The wire payload of a [`wire::Kind::Spawn`].
    pub fn encode(&self) -> Vec<u8> {
        let mut out = wire::Out::default()
            .bytes(&self.id)
            .u16(self.cols)
            .u16(self.rows)
            .u16(self.px_w)
            .u16(self.px_h)
            .string(&self.cwd)
            .u32(self.argv.len() as u32);
        for arg in &self.argv {
            out = out.string(arg);
        }
        out = out.u32(self.env.len() as u32);
        for entry in &self.env {
            out = out.string(entry);
        }
        out.0
    }

    /// Decode a [`wire::Kind::Spawn`] payload.
    pub fn decode(payload: &[u8]) -> io::Result<Self> {
        let mut input = wire::In(payload);
        let id = input.array::<16>()?;
        let (cols, rows, px_w, px_h) = (input.u16()?, input.u16()?, input.u16()?, input.u16()?);
        let cwd = input.string()?.to_vec();
        let mut argv = Vec::new();
        for _ in 0..input.u32()?.min(4096) {
            argv.push(input.string()?.to_vec());
        }
        let mut env = Vec::new();
        for _ in 0..input.u32()?.min(65536) {
            env.push(input.string()?.to_vec());
        }
        Ok(Self { id, cols, rows, px_w, px_h, cwd, argv, env })
    }
}

/// One terminal a holder reports in its [`wire::Kind::Welcome`], with a dup
/// of its PTY master: a restarted daemon's custody copy.
#[derive(Debug)]
pub struct Listed {
    pub chan: u32,
    pub id: [u8; 16],
    pub pid: i32,
    /// Offset of the oldest output byte the holder still keeps.
    pub oldest: u64,
    /// Offset after the newest output byte.
    pub end: u64,
    pub exited: bool,
    /// The custody dup of the master (`None` from the holder's own encode).
    pub master: Option<std::os::fd::OwnedFd>,
}

impl Listed {
    pub(crate) fn encode(&self) -> Vec<u8> {
        wire::Out::default()
            .i32(self.pid)
            .u64(self.oldest)
            .u64(self.end)
            .u8(self.exited as u8)
            .bytes(&self.id)
            .0
    }

    pub(crate) fn decode(
        chan: u32,
        payload: &[u8],
        master: Option<std::os::fd::OwnedFd>,
    ) -> io::Result<Self> {
        let mut input = wire::In(payload);
        Ok(Self {
            master,
            chan,
            pid: input.i32()?,
            oldest: input.u64()?,
            end: input.u64()?,
            exited: input.u8()? != 0,
            id: input.array::<16>()?,
        })
    }
}

/// How a terminal's child ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExitStatus {
    Exited(i32),
    Signaled(i32),
    /// The child was adopted from a holder that died, so this holder is not
    /// its parent and cannot read its status.
    Unobserved,
}

impl ExitStatus {
    pub(crate) fn encode(self) -> (u8, i32) {
        match self {
            Self::Exited(code) => (0, code),
            Self::Signaled(signal) => (1, signal),
            Self::Unobserved => (2, 0),
        }
    }

    pub(crate) fn decode(kind: u8, code: i32) -> Self {
        match kind {
            0 => Self::Exited(code),
            1 => Self::Signaled(code),
            _ => Self::Unobserved,
        }
    }
}

/// The environment variable that carries the soft `RLIMIT_NOFILE` cmux
/// started with (the daemon raised its own): the holder gives it back to
/// every shell. The same name a spawned terminal host reads.
pub const NOFILE_SOFT_ENV: &str = "CMUX_TUI_HOST_NOFILE_SOFT";

/// Run a holder process: `--socket PATH` (and `--idle-exit-ms N`, the idle
/// exit; default [`holder::IDLE_EXIT`]), the owner token as 64 hex
/// characters on stdin, `ready` on stdout once it listens. Returns on a
/// startup error, once it was idle for its idle exit, or when launchd ends
/// it (logout, shutdown).
pub fn serve(args: &[String]) -> io::Result<()> {
    // First, before any descriptor of the holder's own exists: nothing the
    // daemon inherited reaches a shell.
    pty::mark_inherited_close_on_exec();
    let mut args = args.iter().cloned();
    let mut socket = None;
    let mut idle_exit = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--socket" => socket = args.next().map(PathBuf::from),
            "--idle-exit-ms" => {
                let millis = args.next().and_then(|value| value.parse::<u64>().ok());
                let millis = millis.ok_or_else(|| invalid("--idle-exit-ms takes milliseconds"))?;
                idle_exit = Some(std::time::Duration::from_millis(millis));
            }
            other => return Err(invalid(&format!("unknown argument {other}"))),
        }
    }
    let child_open_file_limit =
        std::env::var(NOFILE_SOFT_ENV).ok().and_then(|value| value.parse::<u64>().ok());
    let socket = socket.ok_or_else(|| invalid("--socket PATH is required"))?;
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    let token = parse_token(line.trim()).ok_or_else(|| invalid("bad token on stdin"))?;

    // SAFETY: plain process-wide calls at startup, before any thread exists.
    // SIGTERM gets a handler in `Holder::new`: only launchd's ends the holder.
    unsafe {
        libc::setsid();
        for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGTERM, libc::SIGPIPE, libc::SIGQUIT] {
            libc::signal(signal, libc::SIG_IGN);
        }
    }
    // A socket file nobody listens on is a dead holder's; a live one is not
    // ours to take.
    if socket.exists() {
        if UnixStream::connect(&socket).is_ok() {
            return Err(invalid("another holder serves this socket"));
        }
        std::fs::remove_file(&socket)?;
    }
    let listener = UnixListener::bind(&socket)?;
    let mut holder = holder::Holder::new(listener, token)?;
    holder.set_child_open_file_limit(child_open_file_limit);
    if let Some(idle_exit) = idle_exit {
        holder.set_idle_exit(idle_exit);
    }
    let mut stdout = io::stdout().lock();
    stdout.write_all(b"ready\n")?;
    stdout.flush()?;
    drop(stdout);
    // Stdio no longer leads anywhere the holder needs.
    // SAFETY: replaces fds 0-2 with /dev/null at startup.
    unsafe {
        let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
        if null >= 0 {
            libc::dup2(null, 0);
            libc::dup2(null, 1);
            libc::dup2(null, 2);
            if null > 2 {
                libc::close(null);
            }
        }
    }
    holder.run()
}

fn parse_token(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    let mut token = [0u8; 32];
    for (index, byte) in token.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(index * 2..index * 2 + 2)?, 16).ok()?;
    }
    Some(token)
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spawn_request_round_trips() {
        let request = SpawnRequest {
            id: [7; 16],
            cols: 80,
            rows: 24,
            px_w: 640,
            px_h: 384,
            cwd: b"/tmp".to_vec(),
            argv: vec![b"/bin/sh".to_vec(), b"-l".to_vec()],
            env: vec![b"TERM=xterm-256color".to_vec()],
        };
        assert_eq!(SpawnRequest::decode(&request.encode()).unwrap(), request);
    }
}
