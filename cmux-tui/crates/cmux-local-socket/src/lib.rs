//! The local socket transport of cmux, shared by the daemon (cmux-tui-core)
//! and the clients (cmux-sdk, cmux-daemon-client), so the same-user rules
//! exist once.
//!
//! Unix: `std::os::unix::net::UnixStream`; the daemon and the SDK keep their
//! own Unix connect and peer code for now (unchanged behavior).
//!
//! Windows: AF_UNIX through `uds_windows` (Windows 10 1803 and later; the
//! daemon listens there). [`listen`] makes the socket directory owner-only
//! (protected DACL, our token user as owner) and refuses a wider existing
//! one, binds, and sets the socket file's owner to our token user (an
//! elevated process would otherwise create it owned by
//! BUILTIN\Administrators). [`Listener::accept`] refuses a peer that is not
//! our user, or is sandboxed (integrity below Medium, or an AppContainer,
//! such as a Chromium renderer). [`connect_same_user`] refuses a socket file
//! whose owner is not our token user. Sockets are not inherited by child
//! processes. See plans/cmux-next/windows-daemon.md.

mod policy;

pub use policy::{MEDIUM_INTEGRITY_RID, PeerIdentity, Refusal, owner_allowed, peer_allowed};

#[cfg(windows)]
mod windows;

#[cfg(windows)]
pub use windows::{
    Listener, Stream, connect, connect_same_user, connect_with_deadline, listen, listen_explicit,
    peer_pid, private_directory,
};

#[cfg(windows)]
pub mod win {
    //! Windows token and security descriptor helpers (tests and the daemon's
    //! diagnostics).
    pub use crate::windows::{
        current_identity, directory_is_owner_only, owner_of, process_identity,
    };
}

#[cfg(unix)]
/// The connected stream type on Unix.
pub type Stream = std::os::unix::net::UnixStream;
