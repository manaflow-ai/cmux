//! `cmux-holder`: one small process that holds every PTY of an install.
//!
//! The holder parses no terminal output. It keeps each PTY master in one
//! `poll` set, is the parent of each shell it starts, and keeps a byte ring
//! per terminal so a restarted daemon can catch up. The daemon keeps a dup of
//! every master (passed with `SCM_RIGHTS`), so a crash of either process
//! loses no shell: a new holder takes the masters back with [`wire::Kind::Adopt`],
//! a new daemon re-attaches from the rings. Design:
//! `plans/cmux-next/terminal-host-model-DESIGN.md`.

pub mod client;
pub mod holder;
pub mod pty;
pub mod ring;
pub mod wire;

use std::io;

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

/// One terminal a holder reports in its [`wire::Kind::Welcome`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Listed {
    pub chan: u32,
    pub id: [u8; 16],
    pub pid: i32,
    /// Offset of the oldest output byte the holder still keeps.
    pub oldest: u64,
    /// Offset after the newest output byte.
    pub end: u64,
    pub exited: bool,
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

    pub(crate) fn decode(chan: u32, payload: &[u8]) -> io::Result<Self> {
        let mut input = wire::In(payload);
        Ok(Self {
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
