//! `cmux host run`: the bind agent and session host supervisor of a cmux
//! machine (plans/cmux-next/vm-image.md 6.2-6.4).
//!
//! A machine created from a memory snapshot resumes the snapshot's
//! processes, so it cannot tell it was cloned except through the metadata
//! service's instance id. The agent blocks in one epoll set over the
//! realtime clock-set timer, rtnetlink, inotify on the driver's and the
//! bake's files, a signalfd and the session host's pidfd. On each wake it
//! reads the instance id once and lets the pure [`machine`] decide: bind a
//! new id (reseed, drop inherited identity, write the bound id, spawn the
//! session host, then re-key off the critical path), park for a snapshot,
//! or keep supervising. There is no tick.
//!
//! Modules:
//! - [`machine`]: the decision state machine (pure, property-tested).
//! - [`retry`]: restart backoff and the bounded clock-set re-arm (pure).
//! - [`metadata`]: the single-reader metadata client.
//! - [`daemon_spec`]: the session host's exact argv and environment (pure).
//! - [`announce`]: the private network announce filter (pure).
//! - [`remote_entry`]: the session host's --remote-ws bind and auth mode (pure).
//! - [`agent`]: the event loop over the [`agent::Platform`] trait.
//! - [`roles`]: role supervision (order, deadlines, last errors).
//! - [`proc_roles`]: process roles from `server.json` (server.md 5.1).
//! - [`run_roles`]: `cmux host run` without a bind agent (macOS).
//! - [`status`]: `cmux host status`.
//! - [`cloud`]: the Cloud machine agent role (bind, status reports, events).
//! - [`team_ssh`]: sshd trust files, fail-closed principals and revoked-session reaping.
//! - [`cli`]: the verbs; also the standalone `cmux-host` binary.
//! - `linux`: the Linux platform (descriptors, spawn, identity, `/proc`).
//!
//! Known limits (security review notes):
//! - Adoption after an agent restart trusts only the agent's root-owned pid
//!   file in `/run/cmux-host`; there is no `/proc` fallback, so a session
//!   host whose pid file was lost is not adopted (a second one would fail
//!   to take the session and exit, and the backoff applies).
//! - `/run/cmux` belongs to the work user, so that user can write
//!   `/run/cmux/instance-id` and cause metadata reads. Each wake costs one
//!   bounded read; the id itself always comes from the metadata service.

pub mod agent;
pub mod announce;
pub mod cli;
pub mod cloud;
pub mod config;
pub mod daemon_spec;
#[cfg(target_os = "linux")]
pub mod linux;
pub mod machine;
pub mod metadata;
pub mod proc_roles;
pub mod remote_entry;
pub mod retry;
pub mod roles;
pub mod run_roles;
pub mod status;
pub mod team_ssh;
