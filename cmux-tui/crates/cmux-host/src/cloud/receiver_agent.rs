//! The receiver's on-demand public-policy source. Only the fixed root-owned
//! agent socket can feed the authority owner; no account token or key is read.
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_link::keyset::Keyset;
use cmux_link::native_token::{
    NativeTokenVerifier,
    receiver::{Owner, Refresh},
};

use super::receiver::{REQUEST_BUDGET, ReceiverBinding, ReceiverSnapshot};
use super::wire::AGENT_SOCKET;

const UNAVAILABLE: &str = "VM receiver authority unavailable";
const REQUEST: &[u8] = b"{\"op\":\"cloud.vm.network_policy\"}\n";

/// Own this for the supervised receiver lifetime. Verifier readers retain
/// replay state; dropping this source invalidates every pending/live authority.
pub struct AgentReceiver {
    binding: ReceiverBinding,
    owner: Owner,
    generation: Option<String>,
}

impl AgentReceiver {
    pub fn new(binding: ReceiverBinding, original_keys: Keyset) -> Result<Self, String> {
        Ok(Self {
            binding,
            owner: Owner::new(original_keys).map_err(|_| UNAVAILABLE)?,
            generation: None,
        })
    }

    pub fn for_receiver(
        binding: ReceiverBinding,
        original_keys: Keyset,
        generation: String,
    ) -> Result<Self, String> {
        let owner =
            Owner::for_receiver(original_keys, generation.clone()).map_err(|_| UNAVAILABLE)?;
        Ok(Self { binding, owner, generation: Some(generation) })
    }
    pub fn verifier(&self) -> Arc<NativeTokenVerifier> {
        self.owner.verifier()
    }
    pub fn invalidate(&self) {
        self.owner.invalidate();
    }
    /// A terminal generation change requires replacement under a fresh root frame.
    pub fn is_retired(&self) -> bool {
        self.owner.is_retired()
    }

    /// Reserve intent before scheduling blocking I/O. Cancellation must
    /// invalidate the source before dropping a queued read's async waiter.
    pub fn prepare_refresh(&self) -> Result<Refresh, String> {
        self.owner.begin().map_err(|_| UNAVAILABLE.into())
    }

    /// Complete only this prepared intent; never issue another intent when
    /// a blocking executor eventually starts a previously queued read.
    pub fn refresh_prepared(&self, refresh: Refresh) -> Result<ReceiverSnapshot, String> {
        self.refresh_at_prepared(Path::new(AGENT_SOCKET), 0, true, REQUEST_BUDGET, refresh)
    }

    /// One bounded read, with the original public self pin. The refresh guard
    /// closes current authority on every failed or abandoned read; stale reads
    /// and stale failures cannot publish over a newer intent.
    pub fn refresh(&self) -> Result<ReceiverSnapshot, String> {
        self.refresh_at(Path::new(AGENT_SOCKET), 0, true, REQUEST_BUDGET)
    }

    fn refresh_at(
        &self,
        path: &Path,
        uid: u32,
        system: bool,
        budget: Duration,
    ) -> Result<ReceiverSnapshot, String> {
        let refresh = self.prepare_refresh()?;
        self.refresh_at_prepared(path, uid, system, budget, refresh)
    }

    fn refresh_at_prepared(
        &self,
        path: &Path,
        uid: u32,
        system: bool,
        budget: Duration,
        refresh: Refresh,
    ) -> Result<ReceiverSnapshot, String> {
        let started = refresh.started();
        let budget = budget.min(REQUEST_BUDGET);
        let deadline = started + budget;
        if refresh.elapsed(Instant::now()).ok_or(UNAVAILABLE)? >= budget {
            return Err(UNAVAILABLE.into());
        }
        check_path(path, uid, system).map_err(|_| UNAVAILABLE)?;
        let mut stream = connect(path, deadline).map_err(|_| UNAVAILABLE)?;
        check_peer(&stream, uid).map_err(|_| UNAVAILABLE)?;
        let bytes = exchange(&mut stream, deadline).map_err(|_| UNAVAILABLE)?;
        let snapshot = ReceiverSnapshot::from_public_reply_for_refresh(
            &bytes,
            &self.binding,
            &refresh,
            Instant::now(),
        )?;
        if refresh.elapsed(Instant::now()).ok_or(UNAVAILABLE)? >= budget {
            return Err(UNAVAILABLE.into());
        }
        if self.generation.as_ref().is_some_and(|generation| {
            snapshot.policy().receiver_generation.as_ref() != Some(generation)
        }) {
            self.owner.retire(refresh);
            return Err(UNAVAILABLE.into());
        }
        snapshot.install(&self.owner, refresh, Instant::now())?;
        Ok(snapshot)
    }
}

fn remaining(deadline: Instant) -> io::Result<Duration> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() { Err(io::ErrorKind::TimedOut.into()) } else { Ok(left) }
}

fn check_path(path: &Path, uid: u32, system: bool) -> io::Result<()> {
    let denied = || io::Error::from(io::ErrorKind::PermissionDenied);
    let parent = path.parent().ok_or_else(denied)?;
    if system {
        for dir in [Path::new("/"), Path::new("/run"), parent] {
            check_directory(dir, uid)?;
        }
    } else {
        check_directory(parent, uid)?;
    }
    let meta = fs::symlink_metadata(path)?;
    if !meta.file_type().is_socket() || meta.uid() != uid || meta.mode() & 0o007 != 0 {
        return Err(denied());
    }
    Ok(())
}

fn check_directory(path: &Path, uid: u32) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir()
        || meta.file_type().is_symlink()
        || meta.uid() != uid
        || meta.mode() & 0o022 != 0
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}

fn check_peer(stream: &UnixStream, uid: u32) -> io::Result<()> {
    // SAFETY: ucred is a plain initialized output buffer with its exact length.
    let mut peer = unsafe { std::mem::zeroed::<libc::ucred>() };
    let mut len = size_of_val(&peer) as libc::socklen_t;
    // SAFETY: both output pointers are live and sized for SO_PEERCRED.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut peer).cast(),
            &raw mut len,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if len as usize != size_of_val(&peer) || peer.uid != uid || peer.pid <= 0 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}

fn connect(path: &Path, deadline: Instant) -> io::Result<UnixStream> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: sockaddr_un is a plain all-zero-initializable address buffer.
    let mut address = unsafe { std::mem::zeroed::<libc::sockaddr_un>() };
    if bytes.is_empty() || bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (to, from) in address.sun_path.iter_mut().zip(bytes) {
        *to = *from as libc::c_char;
    }
    // SAFETY: socket has no borrowed pointers; a successful fd is newly owned.
    let raw = unsafe {
        libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK, 0)
    };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: raw is a new descriptor returned by socket with exactly one owner.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let size =
        (std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1) as libc::socklen_t;
    // SAFETY: address is initialized and size includes only the pathname and NUL.
    let result = unsafe { libc::connect(fd.as_raw_fd(), (&raw const address).cast(), size) };
    if result != 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINPROGRESS) {
            return Err(error);
        }
        loop {
            let mut poll = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
            let timeout = remaining(deadline)?.as_millis().clamp(1, i32::MAX as u128) as i32;
            // SAFETY: one initialized pollfd lives for the complete call.
            let ready = unsafe { libc::poll(&mut poll, 1, timeout) };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                remaining(deadline)?;
                continue;
            }
            let mut error: libc::c_int = 0;
            let mut len = size_of_val(&error) as libc::socklen_t;
            // SAFETY: error and len are correctly sized live output buffers.
            if unsafe {
                libc::getsockopt(
                    fd.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    (&raw mut error).cast(),
                    &raw mut len,
                )
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
            if error != 0 {
                return Err(io::Error::from_raw_os_error(error));
            }
            break;
        }
    }
    remaining(deadline)?;
    let stream = UnixStream::from(fd);
    stream.peer_addr()?;
    stream.set_nonblocking(false)?;
    Ok(stream)
}

fn exchange(stream: &mut UnixStream, deadline: Instant) -> io::Result<Vec<u8>> {
    let mut pending = REQUEST;
    while !pending.is_empty() {
        stream.set_write_timeout(Some(remaining(deadline)?))?;
        match stream.write(pending) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => pending = pending.get(n..).ok_or(io::ErrorKind::InvalidData)?,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        stream.set_read_timeout(Some(remaining(deadline)?))?;
        let count = match stream.read(&mut chunk) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            other => other?,
        };
        if count == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        let read = chunk.get(..count).ok_or(io::ErrorKind::InvalidData)?;
        let before = bytes.len();
        bytes.extend_from_slice(read);
        if bytes.len() > 1024 * 1024 + 1 {
            return Err(io::ErrorKind::InvalidData.into());
        }
        if let Some(relative) = read.iter().position(|b| *b == b'\n') {
            let end = before + relative;
            if end + 1 != bytes.len() {
                return Err(io::ErrorKind::InvalidData.into());
            }
            remaining(deadline)?;
            bytes.truncate(end);
            return Ok(bytes);
        }
    }
}

#[cfg(test)]
#[path = "receiver_agent_tests.rs"]
mod tests;
