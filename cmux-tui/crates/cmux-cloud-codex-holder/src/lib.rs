//! The NEXT app's Codex access holder for the person's own Cloud machines, moved from the app's
//! Swift `CmuxNextCloud/Broker`. One private Codex auth holder process per account scope
//! (acpmux `codex-auth-broker`) keeps the rotating refresh token on the Mac; machines get only
//! short-lived access, renewed before it ends, and a sign-out, an account or team switch, the
//! Cloud off switch or a machine delete erases it. A quit or an update leaves it in place, and
//! the next run takes it back from the delivery record. The Mac's own Codex sign-in is used,
//! read only, once the person allowed it.
//!
//! The app runs this as `cmux cloud codex-holder` ([`serve`]): it starts the process, answers its
//! questions (the Cloud credential, a machine's owner and status, the consent) and shows the
//! device-code prompt.

// Unix only (pipes, signals, file modes): empty elsewhere, so a whole-workspace build on Windows
// still builds. Its one user, cmux-tui's `cloud codex-holder`, is unix-only too.
#![cfg(unix)]

pub mod adapter;
pub mod broker;
mod broker_files;
mod broker_renewal;
pub mod cx;
pub mod error;
pub mod local_access;
pub mod record;
pub mod registry;
pub mod serve;
pub mod session;
pub mod target;
pub mod types;

#[cfg(test)]
mod test_support;

pub use broker_renewal::retries_later;
pub use error::{BrokerError, Error};
pub use serve::{App, Config, serve};
pub use target::{ExecResult, Machines, VmError};
