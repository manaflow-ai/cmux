//! Child processes of the cmux daemon that inherit no descriptor they were
//! not given.
//!
//! The daemon is multithreaded and receives descriptors it must never pass
//! on: a terminal's PTY master and its output ring arrive over the holder
//! link (`SCM_RIGHTS`). macOS has no atomic close-on-exec for received
//! descriptors (no `MSG_CMSG_CLOEXEC`), and it has no `pipe2` either: between
//! `recvmsg` (or `pipe`) and the `fcntl(F_SETFD)` after it, a child another
//! thread spawns inherits the descriptor for its whole life. The receiver
//! cannot close that window. A spawn can: on macOS [`Command::spawn`] uses
//! `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so the child gets only
//! descriptors 0-2 and the ones named with [`Command::inherit_fd`], whatever
//! the rest of the process has open. No code runs between a fork and an exec
//! (there is no fork).
//!
//! On Linux and Windows [`Command`] runs `std::process::Command`: there the
//! kernel makes received descriptors (`MSG_CMSG_CLOEXEC`), pipes (`pipe2`) and
//! sockets (`SOCK_CLOEXEC`) close-on-exec atomically, so nothing is
//! inheritable by accident.
//!
//! The API copies `std::process`, so a call site changes its `use` line:
//!
//! ```no_run
//! use cmux_process::{Command, Stdio};
//!
//! let output = Command::new("git").args(["status", "--porcelain"]).stdin(Stdio::null()).output()?;
//! assert!(output.status.success());
//! # Ok::<(), std::io::Error>(())
//! ```
//!
//! Differences from `std::process::Command` on macOS: every signal starts at
//! its default disposition with an empty signal mask (std keeps ignored
//! signals ignored); there is no `pre_exec`, `uid` or `gid` ([`Command::new_session`]
//! and [`Command::process_group`] cover what the daemon's hooks did); a
//! descriptor other than 0-2 reaches the child only through
//! [`Command::inherit_fd`].

mod child;
mod command;
#[cfg(target_vendor = "apple")]
mod spawn_apple;
mod stdio;

pub use child::Child;
pub use command::Command;
pub use std::process::{ExitStatus, Output};
pub use stdio::Stdio;
