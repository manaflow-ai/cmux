//! cmux server and VM software, I/O (plans/cmux-next/server.md 4, 5, 7.4,
//! 8, 9, 13). The pure crate `cmux-server-core` holds every plan and
//! renderer (paths, units, SQL, config files, manifest checks, health
//! rules); this crate applies them to the machine.
//!
//! Modules:
//! - [`store`]: verified manifest apply into `store/<sha256>/`, profiles,
//!   the atomic `current` flip, rollback and GC.
//! - [`service`]: systemd and launchd registration.
//! - [`pg`]: the Postgres cluster, per-app roles, WAL archive, backups.
//! - [`health`]: probes, the reducer driver and the logind inhibitors.
//! - [`cli`]: the `cmux server …` verbs (`cli::run`), also the standalone
//!   `cmux-server` binary.
//! - [`pair`]: `cmux server pair`, the server side of pairing (install
//!   identity, begin, the wait socket, stored credentials).
//! - [`exec`]: the one re-exec into a newer staged `cmux` (decision SV-R2).
//!
//! No async runtime of its own: reqwest's blocking client (package
//! downloads only) runs a private one on its own thread. Nothing polls:
//! health exposes a one-shot deadline, services start through the service
//! manager, and `pg_ctl -w` waits on Postgres's own readiness.

pub mod access;
pub mod cli;
pub mod config;
pub mod error;
pub mod exec;
pub mod fsx;
pub mod health;
pub mod host;
pub mod keys;
pub mod pair;
pub mod pg;
pub mod process;
pub mod service;
pub mod store;
pub mod sys;

pub use error::{Error, ExitKind, Result};
