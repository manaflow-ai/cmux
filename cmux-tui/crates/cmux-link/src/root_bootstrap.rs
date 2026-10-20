//! Private root/daemon transport. Version 1 carries only a role lifetime fence;
//! it grants no service and accepts no key payload. Original VM bootstrap and
//! receiver composition must negotiate a later capability before sending keys.
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::{UnixDatagram, UnixStream};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, Weak};
use std::time::Instant;

use crate::caller::RootOwnedDaemon;

mod daemon;
pub use daemon::Daemon;

const MAGIC: [u8; 4] = *b"CMR\x01";

/// A local role incarnation, never serialized or derived from a caller claim.
#[derive(Clone)]
pub struct Ticket(Arc<()>);

struct Role {
    host: Arc<UnixStream>,
    recipient: Option<UnixStream>,
}
impl Role {
    fn close(&self) {
        let _ = self.host.shutdown(Shutdown::Write);
    }
    fn sent(&self) -> bool {
        self.recipient.is_none()
    }
}

#[derive(Default)]
struct State {
    child: Weak<RootOwnedDaemon>,
    inherited: Option<Arc<UnixStream>>,
    control: Option<Arc<UnixStream>>,
    ticket: Option<Arc<()>>,
    wanted: bool,
    role: Option<Role>,
    closing: Option<Role>,
}

/// Root supervision owns daemon identity; the Cloud role owns its current
/// ticket. The worker performs bounded nonblocking I/O after readiness wakes.
pub struct Host {
    state: Mutex<State>,
    notice: Arc<UnixDatagram>,
    wake: UnixDatagram,
}

/// Retain every polled descriptor until the caller's readiness wait completes.
pub struct WakeSet {
    _streams: Vec<Arc<UnixStream>>,
    _notice: Arc<UnixDatagram>,
    fds: Vec<libc::pollfd>,
}
impl WakeSet {
    pub fn fds(&self) -> Vec<libc::pollfd> {
        self.fds.clone()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum StopReceipt {
    NoReceiver,
    Acknowledged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capability {
    LifetimeOnly,
}

impl Host {
    pub fn capability(&self) -> Option<Capability> {
        self.state.lock().ok()?.control.as_ref().map(|_| Capability::LifetimeOnly)
    }
    pub fn new() -> io::Result<Self> {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            return Err(refused());
        }
        let (notice, wake) = UnixDatagram::pair()?;
        notice.set_nonblocking(true)?;
        wake.set_nonblocking(true)?;
        Ok(Self { state: Mutex::new(State::default()), notice: Arc::new(notice), wake })
    }

    /// Capture only the actual spawned child. An adopted pid gets no channel.
    /// Identity failure leaves the daemon running with bootstrap unavailable.
    pub fn spawn(&self, command: &mut Command, uid: u32) -> io::Result<Arc<RootOwnedDaemon>> {
        let channels = (|| -> io::Result<_> {
            let (mut parent, inherited) = UnixStream::pair()?;
            parent.write_all(&MAGIC)?;
            parent.set_nonblocking(true)?;
            Ok((parent, inherited))
        })()
        .ok();
        let (parent, inherited) = match channels {
            Some((parent, inherited)) => (Some(Arc::new(parent)), Some(inherited)),
            None => (None, None),
        };
        command.stdin(match inherited {
            Some(inherited) => Stdio::from(OwnedFd::from(inherited)),
            None => Stdio::null(),
        });
        let child = Arc::new(RootOwnedDaemon::capture(command.spawn()?, uid));
        // Even a poisoned optional bootstrap owner must not lose an already
        // spawned daemon. The caller always receives its actual child handle.
        if let Ok(mut state) = self.state.lock() {
            let ticket = state.ticket.clone();
            let wanted = state.wanted;
            *state = State {
                child: Arc::downgrade(&child),
                inherited: parent,
                ticket,
                wanted,
                ..State::default()
            };
        }
        self.notify();
        Ok(child)
    }

    pub fn new_ticket(&self) -> io::Result<Ticket> {
        self.invalidate();
        let ticket = Arc::new(());
        self.state.lock().map_err(|_| refused())?.ticket = Some(ticket.clone());
        Ok(Ticket(ticket))
    }

    /// Enrollment completion may request delivery only for its live role.
    pub fn offer(&self, ticket: &Ticket) -> bool {
        let Ok(mut state) = self.state.lock() else { return false };
        if !state.ticket.as_ref().is_some_and(|current| Arc::ptr_eq(current, &ticket.0)) {
            return false;
        }
        state.wanted = true;
        drop(state);
        self.notify();
        true
    }

    /// Fence pending callbacks before waiting for network or metadata work.
    pub fn invalidate(&self) {
        {
            let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            state.ticket = None;
            state.wanted = false;
            if let Some(role) = state.role.take() {
                role.close();
                if role.sent() {
                    state.closing = Some(role);
                }
            }
        }
        self.notify();
    }

    pub fn detach(&self) {
        self.invalidate();
        if let Ok(mut state) = self.state.lock() {
            *state = State::default();
        }
        self.notify();
    }

    pub fn wake_set(&self) -> io::Result<WakeSet> {
        let state = self.state.lock().map_err(|_| refused())?;
        let mut streams = Vec::new();
        let mut fds =
            vec![libc::pollfd { fd: self.notice.as_raw_fd(), events: libc::POLLIN, revents: 0 }];
        let writable =
            if state.role.as_ref().is_some_and(|r| !r.sent()) { libc::POLLOUT } else { 0 };
        for (stream, events) in state
            .inherited
            .iter()
            .map(|s| (s, libc::POLLIN))
            .chain(state.control.iter().map(|s| (s, libc::POLLIN | writable)))
        {
            fds.push(libc::pollfd { fd: stream.as_raw_fd(), events, revents: 0 });
            streams.push(stream.clone());
        }
        if let Some(role) = &state.closing {
            fds.push(libc::pollfd { fd: role.host.as_raw_fd(), events: libc::POLLIN, revents: 0 });
            streams.push(role.host.clone());
        }
        Ok(WakeSet { _streams: streams, _notice: self.notice.clone(), fds })
    }

    /// Returns true only after an authenticated daemon was sent the role fd.
    pub fn drive(&self) -> io::Result<bool> {
        let result = self.drive_inner();
        if result.is_err() {
            self.detach();
        }
        result
    }

    fn drive_inner(&self) -> io::Result<bool> {
        let mut byte = [0];
        while self.notice.recv(&mut byte).is_ok() {}
        let mut state = self.state.lock().map_err(|_| refused())?;
        if state.control.is_none()
            && let Some(parent) = &state.inherited
        {
            match cmux_unix_socket::descriptor::receive(parent, 1) {
                Ok((bytes, Some(fd))) if bytes == [1] => {
                    let stream = UnixStream::from(fd);
                    state.child.upgrade().ok_or_else(refused)?.verify(&stream)?;
                    stream.set_nonblocking(true)?;
                    state.control = Some(Arc::new(stream));
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                _ => return Err(refused()),
            }
        }
        if state.control.is_some() {
            for stream in state.inherited.iter().chain(state.control.iter()) {
                let mut reader = &**stream;
                match reader.read(&mut byte) {
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    _ => return Err(refused()),
                }
            }
        }
        if let Some(role) = &state.closing {
            match ack(&role.host) {
                Ok(true) => state.closing = None,
                Ok(false) => {}
                Err(error) => return Err(error),
            }
        }
        if state.wanted
            && state.control.is_some()
            && state.role.is_none()
            && state.closing.is_none()
        {
            let (host, recipient) = UnixStream::pair()?;
            host.set_nonblocking(true)?;
            state.role = Some(Role { host: Arc::new(host), recipient: Some(recipient) });
        }
        if let (Some(control), Some(role)) = (&state.control, &state.role)
            && let Some(recipient) = &role.recipient
        {
            state.child.upgrade().ok_or_else(refused)?.verify(control)?;
            match cmux_unix_socket::descriptor::send(control, &[1], recipient.as_raw_fd()) {
                Ok(()) => {
                    state.role.as_mut().ok_or_else(refused)?.recipient = None;
                    return Ok(true);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
        }
        Ok(false)
    }

    /// Allowed to block only in the role's bounded park/shutdown path.
    pub fn quiesce(&self, deadline: Instant) -> io::Result<StopReceipt> {
        self.invalidate();
        let role = self.state.lock().map_err(|_| refused())?.closing.take();
        let Some(role) = role else { return Ok(StopReceipt::NoReceiver) };
        let result = wait_ack(&role.host, deadline);
        if result.is_err() {
            self.state.lock().map_err(|_| refused())?.closing = Some(role);
        }
        result.map(|()| StopReceipt::Acknowledged)
    }

    fn notify(&self) {
        let _ = self.wake.send(&[1]);
    }
}

fn refused() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "cloud.bootstrap.channel_refused")
}

fn ack(stream: &UnixStream) -> io::Result<bool> {
    let mut reader = stream;
    let mut byte = [0];
    match reader.read(&mut byte) {
        Ok(1) if byte == [1] => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(false),
        _ => Err(refused()),
    }
}

fn wait_ack(stream: &UnixStream, deadline: Instant) -> io::Result<()> {
    loop {
        if ack(stream)? {
            return Ok(());
        }
        let left =
            deadline.checked_duration_since(Instant::now()).ok_or(io::ErrorKind::TimedOut)?;
        let mut fd = libc::pollfd { fd: stream.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one live initialized pollfd; timeout is one absolute budget.
        if unsafe { libc::poll(&mut fd, 1, left.as_millis().clamp(1, i32::MAX as u128) as i32) } < 0
        {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}
