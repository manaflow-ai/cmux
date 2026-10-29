//! The worker's loop: bootstrap, sandbox, HELLO, then commands and parse
//! slices on one thread until the daemon closes the socket.
//!
//! The order is the point (Chrome's `SeatbeltExecServer`): the first frame
//! must be BOOTSTRAP, the sandbox is applied before the worker maps or
//! reads any ring, and the daemon passes rings only after HELLO. Between
//! slices the loop polls the socket without waiting, so an ADVANCE or a
//! RESIZE is taken within one slice of a flood; with no unparsed bytes it
//! waits in `poll` and wakes for nothing else.

use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};

use crate::sandbox::{self, SandboxError};
use crate::shard::Shard;
use crate::wire::{
    Command, Event, FrameReader, WIRE_VERSION, WireError, decode_command, send_event,
};

/// Why a worker stopped before its daemon closed the socket.
#[derive(Debug)]
pub enum WorkerError {
    Io(io::Error),
    Wire(WireError),
    Sandbox(SandboxError),
    /// A frame other than BOOTSTRAP came first.
    NoBootstrap,
    /// A second BOOTSTRAP.
    BootstrapAgain,
}

impl WorkerError {
    /// The process exit code for this error.
    pub fn exit_code(&self) -> u8 {
        match self {
            Self::Io(_) => 2,
            Self::Wire(_) | Self::NoBootstrap | Self::BootstrapAgain => 3,
            Self::Sandbox(_) => 4,
        }
    }
}

impl std::fmt::Display for WorkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(f, "socket: {error}"),
            Self::Wire(error) => write!(f, "wire: {error}"),
            Self::Sandbox(error) => write!(f, "sandbox: {error}"),
            Self::NoBootstrap => f.write_str("the first frame was not BOOTSTRAP"),
            Self::BootstrapAgain => f.write_str("a second BOOTSTRAP"),
        }
    }
}

impl std::error::Error for WorkerError {}

impl From<io::Error> for WorkerError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<WireError> for WorkerError {
    fn from(error: WireError) -> Self {
        Self::Wire(error)
    }
}

/// Serve the daemon on `socket` until it closes it (`Ok`) or breaks a rule.
pub fn run(socket: OwnedFd) -> Result<(), WorkerError> {
    let fd = socket.as_raw_fd();
    let mut reader = FrameReader::default();
    let policy = loop {
        if let Some(frame) = reader.next_frame()? {
            match decode_command(frame)? {
                Command::Bootstrap(policy) => break policy,
                _ => return Err(WorkerError::NoBootstrap),
            }
        }
        if reader.fill(fd)? == 0 {
            return Ok(());
        }
    };
    let mechanism = sandbox::apply(&policy).map_err(WorkerError::Sandbox)?;
    send_event(
        fd,
        &Event::Hello { version: WIRE_VERSION, sandbox: mechanism, pid: std::process::id() },
    )?;

    let mut shard = Shard::new();
    let mut events = Vec::new();
    loop {
        while let Some(frame) = reader.next_frame()? {
            dispatch(&mut shard, decode_command(frame)?, &mut events)?;
        }
        flush(fd, &mut events)?;
        let busy = shard.has_work();
        if readable(fd, if busy { 0 } else { -1 })? && reader.fill(fd)? == 0 {
            return Ok(());
        }
        if busy {
            shard.step(&mut events);
        }
    }
}

fn dispatch(
    shard: &mut Shard,
    command: Command,
    events: &mut Vec<Event>,
) -> Result<(), WorkerError> {
    match command {
        Command::Bootstrap(_) => return Err(WorkerError::BootstrapAgain),
        Command::Attach(attach) => shard.attach(attach, events),
        Command::Advance { id, end } => shard.advance(id, end),
        Command::Resize { id, geometry, page } => shard.resize(id, geometry, page, events),
        Command::Colors { id, colors } => shard.colors(id, &colors, events),
        Command::Detach { id } => shard.detach(id),
        Command::KittyLimits { id, limits } => shard.kitty_limits(id, limits, events),
        Command::KittyMedia { id, answer } => shard.kitty_media(id, answer.into_read(), events),
    }
    Ok(())
}

fn flush(fd: RawFd, events: &mut Vec<Event>) -> io::Result<()> {
    for event in events.drain(..) {
        send_event(fd, &event)?;
    }
    Ok(())
}

/// Whether `fd` has bytes (or end of stream) within `timeout_ms` (-1: wait).
fn readable(fd: RawFd, timeout_ms: libc::c_int) -> io::Result<bool> {
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    loop {
        // SAFETY: one live pollfd for the call.
        let ready = unsafe { libc::poll(&mut poll, 1, timeout_ms) };
        if ready >= 0 {
            return Ok(ready > 0);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
