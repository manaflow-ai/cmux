//! Private root/daemon transport. Its recipients learn the Cloud role's
//! lifetime only and never receive keys.
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::{UnixDatagram, UnixStream};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
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
    completed: Arc<AtomicBool>,
}
impl Role {
    fn close(&mut self) {
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

impl Host {
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
            if let Some(mut role) = state.role.take() {
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

    /// A reaped daemon loses every connection. The current Cloud-role intent
    /// may be delivered only after its replacement passes fresh child checks.
    pub fn daemon_exited(&self) {
        self.disconnect();
    }

    fn disconnect(&self) {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let ticket = state.ticket.clone();
        let wanted = state.wanted;
        *state = State { ticket, wanted, ..State::default() };
        drop(state);
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

    /// Returns true once the authenticated daemon was sent the role fd.
    pub fn drive(&self) -> io::Result<bool> {
        let result = self.drive_inner();
        if result.is_err() {
            // EOF may precede the supervisor's reap. Keep only the live
            // role's enrollment intent; no endpoint survives this failure.
            // Delivery requires a newly spawned, freshly verified child.
            self.disconnect();
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
            let completed = role.completed.clone();
            match ack(&role.host, &completed) {
                Ok(true) => {
                    completed.store(true, Ordering::Release);
                    state.closing = None;
                }
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
            state.role = Some(Role {
                host: Arc::new(host),
                recipient: Some(recipient),
                completed: Arc::new(AtomicBool::new(false)),
            });
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
        let closing = {
            let state = self.state.lock().map_err(|_| refused())?;
            state.closing.as_ref().map(|role| (role.host.clone(), role.completed.clone()))
        };
        let Some((stream, completed)) = closing else { return Ok(StopReceipt::NoReceiver) };
        // Keep the closing barrier installed while waiting outside the lock.
        // A new ticket cannot publish a frame before the actual drain receipt.
        wait_ack(&stream, &completed, deadline)?;
        let mut state = self.state.lock().map_err(|_| refused())?;
        if state.closing.as_ref().is_some_and(|role| Arc::ptr_eq(&role.host, &stream)) {
            state.closing = None;
        }
        Ok(StopReceipt::Acknowledged)
    }

    fn notify(&self) {
        let _ = self.wake.send(&[1]);
    }
}

fn refused() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "cloud.bootstrap.channel_refused")
}

fn ack(stream: &UnixStream, completed: &AtomicBool) -> io::Result<bool> {
    if completed.load(Ordering::Acquire) {
        return Ok(true);
    }
    let mut reader = stream;
    let mut byte = [0];
    // READY may already be queued when root begins stopping. It is never a
    // drain receipt; consume at most that one notification before the ack.
    for _ in 0..2 {
        match reader.read(&mut byte) {
            Ok(1) if byte == [1] => {
                completed.store(true, Ordering::Release);
                return Ok(true);
            }
            Ok(1) if byte == [2] => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            _ if completed.load(Ordering::Acquire) => return Ok(true),
            _ => return Err(refused()),
        }
    }
    Err(refused())
}

fn wait_ack(stream: &UnixStream, completed: &AtomicBool, deadline: Instant) -> io::Result<()> {
    loop {
        if completed.load(Ordering::Acquire) {
            return Ok(());
        }
        match ack(stream, completed) {
            Ok(true) => {
                completed.store(true, Ordering::Release);
                return Ok(());
            }
            Ok(false) => {}
            Err(_) if completed.load(Ordering::Acquire) => return Ok(()),
            Err(error) => return Err(error),
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
