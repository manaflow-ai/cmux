//! A daemon's HELLO and the holder's WELCOME: who may link, at which wire
//! version, with which [`wire::capability`] bits, and what the WELCOME lists.

use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;

use super::{Holder, error_code, ring_flag};
use crate::Listed;
use crate::wire::{self, In, Kind, Out};

impl Holder {
    /// The wire version both peers speak and the [`wire::capability`] bits
    /// the daemon wants (0 from a daemon older than them), or the error code
    /// that refuses the HELLO.
    pub(super) fn check_hello(&self, payload: &[u8]) -> Result<(u16, u32), u16> {
        let mut input = In(payload);
        let (Ok(version), Ok(token)) = (input.u16(), input.array::<32>()) else {
            return Err(error_code::BAD_PAYLOAD);
        };
        let wanted = input.u32().unwrap_or(0);
        if !constant_time_eq(&token, &self.token) {
            return Err(error_code::BAD_TOKEN);
        }
        if version < wire::MIN_VERSION {
            return Err(error_code::NO_COMMON_VERSION);
        }
        Ok((version.min(wire::VERSION), wanted))
    }

    /// WELCOME the new link with every terminal, a master dup of each and,
    /// for a daemon of [`wire::RING_VERSION`], a dup of its ring segment.
    /// An older daemon gets no segment: it could hand a layout 2 segment to
    /// a holder that knows only layout 1. `granted` follows the count (an
    /// older daemon reads only the count).
    pub(super) fn welcome(&mut self, version: u16, granted: u32) {
        let rings = version >= wire::RING_VERSION;
        let listed: Vec<(u32, Vec<u8>, Vec<OwnedFd>)> = self
            .terminals
            .iter()
            .map(|(chan, terminal)| {
                let listed = Listed {
                    chan: *chan,
                    id: terminal.id,
                    pid: terminal.pid,
                    oldest: terminal.ring.oldest(),
                    end: terminal.ring.end(),
                    exited: terminal.ended(),
                    master: None,
                    ring: None,
                };
                (*chan, listed.encode(), terminal.descriptors(rings))
            })
            .collect();
        let welcome = Out::default().u16(version).u32(listed.len() as u32).u32(granted).0;
        self.queue(Kind::Welcome, 0, &welcome, Vec::new());
        for (chan, payload, fds) in listed {
            self.queue_flagged(Kind::Listed, ring_flag(&fds), chan, &payload, fds);
        }
    }
}

fn constant_time_eq(a: &[u8; 32], b: &[u8; 32]) -> bool {
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The peer runs as this process's user (the threat model: other users only).
pub(super) fn same_user(stream: &UnixStream) -> bool {
    peer_uid(stream.as_raw_fd()).is_some_and(|uid| {
        // SAFETY: getuid has no failure mode.
        uid == unsafe { libc::getuid() }
    })
}

#[cfg(any(target_os = "macos", target_os = "freebsd"))]
fn peer_uid(fd: RawFd) -> Option<libc::uid_t> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: out-pointers to live locals.
    (unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } == 0).then_some(uid)
}

#[cfg(target_os = "linux")]
fn peer_uid(fd: RawFd) -> Option<libc::uid_t> {
    // SAFETY: zeroed ucred is a valid out-buffer.
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: SO_PEERCRED fills one ucred.
    let ok = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    } == 0;
    ok.then_some(cred.uid)
}
