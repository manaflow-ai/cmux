//! Private root/daemon transport. Lifetime-only recipients never receive keys.
//! Native support requires a root-authenticated startup request and an attached
//! recipient; protected frames bind the current role to its exact daemon.
//! The receiving child still needs fresh original policy before serving.
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::{UnixDatagram, UnixStream};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Instant;
use zeroize::Zeroizing;

use crate::caller::RootOwnedDaemon;

mod daemon;
pub use daemon::{Daemon, NativePermit};

const MAGIC: [u8; 4] = *b"CMR\x01";
const NATIVE: [u8; 4] = *b"NVR2";
const MAX_NATIVE_PAYLOAD: usize = 16 * 1024;

/// A local role incarnation, never serialized or derived from a caller claim.
#[derive(Clone)]
pub struct Ticket(Arc<()>);

/// Preparation belongs to this role and this authenticated daemon endpoint.
/// A late original-policy read cannot deliver secrets to a replacement child.
pub struct NativeRequest {
    ticket: Ticket,
    control: Arc<UnixStream>,
}

struct Role {
    ticket: Arc<()>,
    host: Arc<UnixStream>,
    recipient: Option<UnixStream>,
    payload: Option<Zeroizing<Vec<u8>>>,
    offset: usize,
    ready: bool,
    completed: Arc<AtomicBool>,
}
impl Role {
    fn close(&mut self) {
        self.payload = None;
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
    capability: Option<Capability>,
    native_payload: Option<Zeroizing<Vec<u8>>>,
    native_ended: Option<Arc<()>>,
}

/// Root supervision owns daemon identity; the Cloud role owns its current
/// ticket. The worker performs bounded nonblocking I/O after readiness wakes.
pub struct Host {
    state: Mutex<State>,
    notice: Arc<UnixDatagram>,
    wake: UnixDatagram,
    requested: Capability,
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
    NativeReceiver,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeStatus {
    Pending,
    Ready,
    Ended,
}

impl Host {
    pub fn capability(&self) -> Option<Capability> {
        self.state.lock().ok()?.capability
    }
    pub fn new() -> io::Result<Self> {
        Self::with_capability(Capability::LifetimeOnly)
    }

    /// Request support only. A fresh original-policy bootstrap and the
    /// authenticated daemon's Native acknowledgement are still required.
    pub fn new_native() -> io::Result<Self> {
        Self::with_capability(Capability::NativeReceiver)
    }

    fn with_capability(requested: Capability) -> io::Result<Self> {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            return Err(refused());
        }
        let (notice, wake) = UnixDatagram::pair()?;
        notice.set_nonblocking(true)?;
        wake.set_nonblocking(true)?;
        Ok(Self { state: Mutex::new(State::default()), notice: Arc::new(notice), wake, requested })
    }

    /// Capture only the actual spawned child. An adopted pid gets no channel.
    /// Identity failure leaves the daemon running with bootstrap unavailable.
    pub fn spawn(&self, command: &mut Command, uid: u32) -> io::Result<Arc<RootOwnedDaemon>> {
        let channels = (|| -> io::Result<_> {
            let (mut parent, inherited) = UnixStream::pair()?;
            parent.write_all(&MAGIC)?;
            // Older v1 daemons recognize the common prefix and seal stdin
            // before refusing the optional suffix. An unknown replacement
            // magic would leave their private stdin unrecognized and unsealed.
            if self.requested == Capability::NativeReceiver {
                parent.write_all(&NATIVE)?;
            }
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

    pub fn prepare_native(&self, ticket: &Ticket) -> Option<NativeRequest> {
        let state = self.state.lock().ok()?;
        if self.requested != Capability::NativeReceiver
            || state.capability != Some(Capability::NativeReceiver)
            || !state.wanted
            || state.role.is_some()
            || state.closing.is_some()
            || state.native_payload.is_some()
            || state.native_ended.is_some()
            || !state.ticket.as_ref().is_some_and(|current| Arc::ptr_eq(current, &ticket.0))
        {
            return None;
        }
        Some(NativeRequest { ticket: ticket.clone(), control: state.control.as_ref()?.clone() })
    }

    pub fn native_request_current(&self, request: &NativeRequest) -> bool {
        self.prepare_native(&request.ticket)
            .is_some_and(|current| Arc::ptr_eq(&current.control, &request.control))
    }

    pub fn native_status(&self, ticket: &Ticket) -> Option<NativeStatus> {
        let state = self.state.lock().ok()?;
        if !state.wanted
            || !state.ticket.as_ref().is_some_and(|current| Arc::ptr_eq(current, &ticket.0))
        {
            return None;
        }
        Some(if state.native_ended.as_ref().is_some_and(|ended| Arc::ptr_eq(ended, &ticket.0)) {
            NativeStatus::Ended
        } else if state.role.as_ref().is_some_and(|role| role.ready) {
            NativeStatus::Ready
        } else {
            NativeStatus::Pending
        })
    }

    /// Only the still-current wanted role may advance after actual completion.
    /// The worker retires its backend generation before requesting this ticket.
    pub fn advance_native(&self, ticket: &Ticket) -> Option<Ticket> {
        let mut state = self.state.lock().ok()?;
        if !state.wanted
            || state.role.is_some()
            || state.closing.is_some()
            || state.native_payload.is_some()
            || !state.ticket.as_ref().is_some_and(|current| Arc::ptr_eq(current, &ticket.0))
            || !state.native_ended.as_ref().is_some_and(|ended| Arc::ptr_eq(ended, &ticket.0))
        {
            return None;
        }
        let next = Arc::new(());
        state.ticket = Some(next.clone());
        state.native_ended = None;
        drop(state);
        self.notify();
        Some(Ticket(next))
    }

    pub fn retire_native(&self, ticket: &Ticket) -> bool {
        let Ok(mut state) = self.state.lock() else { return false };
        if !state.wanted
            || !state.ticket.as_ref().is_some_and(|current| Arc::ptr_eq(current, &ticket.0))
        {
            return false;
        }
        state.native_payload = None;
        if let Some(mut role) = state.role.take() {
            role.close();
            if role.sent() {
                state.closing = Some(role);
            }
        }
        if state.closing.is_none() {
            state.native_ended = Some(ticket.0.clone());
        }
        drop(state);
        self.notify();
        true
    }

    pub fn publish_native(&self, request: NativeRequest, payload: Zeroizing<Vec<u8>>) -> bool {
        if payload.is_empty() || payload.len() > MAX_NATIVE_PAYLOAD {
            return false;
        }
        let Ok(mut state) = self.state.lock() else { return false };
        if self.requested != Capability::NativeReceiver
            || state.capability != Some(Capability::NativeReceiver)
            || !state.wanted
            || state.role.is_some()
            || state.closing.is_some()
            || state.native_payload.is_some()
            || state.native_ended.is_some()
            || !state.ticket.as_ref().is_some_and(|current| Arc::ptr_eq(current, &request.ticket.0))
            || !state.control.as_ref().is_some_and(|control| Arc::ptr_eq(control, &request.control))
        {
            return false;
        }
        state.native_payload = Some(payload);
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
            state.native_payload = None;
            state.native_ended = None;
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
        if let Some(role) = &state.role
            && state.capability == Some(Capability::NativeReceiver)
        {
            let events = libc::POLLIN
                | if role.sent() && role.payload.is_some() { libc::POLLOUT } else { 0 };
            fds.push(libc::pollfd { fd: role.host.as_raw_fd(), events, revents: 0 });
            streams.push(role.host.clone());
        }
        Ok(WakeSet { _streams: streams, _notice: self.notice.clone(), fds })
    }

    /// Returns true once the authenticated daemon was sent the role fd and,
    /// for Native support, its entire bounded protected frame.
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
                Ok((bytes, Some(fd)))
                    if bytes == [1]
                        || (bytes == [2] && self.requested == Capability::NativeReceiver) =>
                {
                    let stream = UnixStream::from(fd);
                    state.child.upgrade().ok_or_else(refused)?.verify(&stream)?;
                    stream.set_nonblocking(true)?;
                    state.control = Some(Arc::new(stream));
                    state.capability = Some(if bytes == [2] {
                        Capability::NativeReceiver
                    } else {
                        Capability::LifetimeOnly
                    });
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
            let ticket = role.ticket.clone();
            let completed = role.completed.clone();
            match ack(&role.host, &completed) {
                Ok(true) => {
                    completed.store(true, Ordering::Release);
                    state.closing = None;
                    if state.wanted
                        && state
                            .ticket
                            .as_ref()
                            .is_some_and(|current| Arc::ptr_eq(current, &ticket))
                    {
                        state.native_ended = Some(ticket);
                    }
                }
                Ok(false) => {}
                Err(error) => return Err(error),
            }
        }
        if state.capability == Some(Capability::NativeReceiver)
            && let Some(role) = &state.role
        {
            let mut reader = &*role.host;
            let ready = role.ready;
            let ticket = role.ticket.clone();
            match reader.read(&mut byte) {
                Ok(1) if byte == [2] && !ready => {
                    state.role.as_mut().ok_or_else(refused)?.ready = true;
                }
                Ok(1) if byte == [1] => {
                    role.completed.store(true, Ordering::Release);
                    state.role = None;
                    state.native_ended = Some(ticket);
                    return Ok(false);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                _ => return Err(refused()),
            }
        }
        if state.wanted
            && state.control.is_some()
            && state.role.is_none()
            && state.closing.is_none()
            && (self.requested == Capability::LifetimeOnly
                || (state.capability == Some(Capability::NativeReceiver)
                    && state.native_payload.is_some()))
        {
            let (host, recipient) = UnixStream::pair()?;
            host.set_nonblocking(true)?;
            let payload = state.native_payload.take();
            let ticket = state.ticket.clone().ok_or_else(refused)?;
            state.role = Some(Role {
                ticket,
                host: Arc::new(host),
                recipient: Some(recipient),
                payload,
                offset: 0,
                ready: false,
                completed: Arc::new(AtomicBool::new(false)),
            });
        }
        if let (Some(control), Some(role)) = (&state.control, &state.role)
            && let Some(recipient) = &role.recipient
        {
            state.child.upgrade().ok_or_else(refused)?.verify(control)?;
            let tag = if state.capability == Some(Capability::NativeReceiver) { 2 } else { 1 };
            match cmux_unix_socket::descriptor::send(control, &[tag], recipient.as_raw_fd()) {
                Ok(()) => {
                    state.role.as_mut().ok_or_else(refused)?.recipient = None;
                    if tag == 1 {
                        return Ok(true);
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
        }
        if state.capability == Some(Capability::NativeReceiver)
            && state.role.as_ref().is_some_and(|role| role.sent() && role.payload.is_some())
        {
            let control = state.control.as_ref().ok_or_else(refused)?;
            state.child.upgrade().ok_or_else(refused)?.verify(control)?;
            let role = state.role.as_mut().ok_or_else(refused)?;
            let payload = role.payload.as_ref().ok_or_else(refused)?;
            let mut writer = &*role.host;
            match writer.write(payload.get(role.offset..).ok_or_else(refused)?) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(count) => role.offset += count,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
            if role.offset == payload.len() {
                role.payload = None;
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Allowed to block only in the role's bounded park/shutdown path.
    pub fn quiesce(&self, deadline: Instant) -> io::Result<StopReceipt> {
        self.invalidate();
        self.finish_closing(None, deadline)
    }

    pub fn quiesce_native(&self, ticket: &Ticket, deadline: Instant) -> io::Result<StopReceipt> {
        self.retire_native(ticket);
        self.finish_closing(Some(ticket), deadline)
    }

    fn finish_closing(
        &self,
        ticket: Option<&Ticket>,
        deadline: Instant,
    ) -> io::Result<StopReceipt> {
        let closing = {
            let state = self.state.lock().map_err(|_| refused())?;
            state
                .closing
                .as_ref()
                .filter(|role| ticket.is_none_or(|ticket| Arc::ptr_eq(&role.ticket, &ticket.0)))
                .map(|role| (role.host.clone(), role.completed.clone(), role.ticket.clone()))
        };
        let Some((stream, completed, ticket)) = closing else { return Ok(StopReceipt::NoReceiver) };
        // Keep the closing barrier installed while waiting outside the lock.
        // A new ticket cannot publish a frame before the actual drain receipt.
        wait_ack(&stream, &completed, deadline)?;
        let mut state = self.state.lock().map_err(|_| refused())?;
        if state.closing.as_ref().is_some_and(|role| Arc::ptr_eq(&role.host, &stream)) {
            state.closing = None;
            if state.wanted
                && state.ticket.as_ref().is_some_and(|current| Arc::ptr_eq(current, &ticket))
            {
                state.native_ended = Some(ticket);
            }
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
