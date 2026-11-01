//! The Cloud machine agent, a role of `cmux host run` (vm-image.md 6.3,
//! 11 step 2): bind with the driver's one-time token, then
//! `cloud.vm.status.report` and `cloud.vm.event.emit` for the life of the
//! machine (plans/cmux-next/cloud-client-contract.md 1.7,
//! cloud-automation.md 27). It replaces the interim Bun agent
//! (`images/cmux-vm/guest/vm-agent.ts`) with the same file contracts, wire
//! shapes and timing:
//!
//! - first report right after bind and after every agent start; changes
//!   at most once per 10 s (latest wins, every reason named); a heartbeat
//!   deadline 1 h after the last accepted report; failures back off from
//!   5 s to 10 min, `retry_after_ms` honored;
//! - activity from the daemon's `subscribe-activity` stream (sessions =
//!   attached clients + live agents), `activity` advertised only while the
//!   stream is live;
//! - resume: the supervisor's `Resumed` event (clock-set wake, id
//!   confirmed) sends one report named `resume`.
//!
//! Modules: [`wire`] (contracts, pure), [`sender`] (the two senders, sans
//! I/O), [`session`] (inputs to requests, sans I/O), [`client`] (bind and
//! auth over the [`client::Http`] and [`client::Store`] traits), [`github`]
//! (GitHub tokens for the machine's git and `gh` over the agent socket),
//! [`github_repos`] (repository discovery through the platform connector),
//! [`handoff`] (hand-off reports for the machine's agent sessions, over the
//! same socket), `github_minter` (the thread that answers both off the poll
//! loop),
//! `role` (the Linux worker), [`trajectory`] (ACP chats kept in cmux
//! Cloud and restored into a replacement machine, #25584),
//! `trajectory_thread` (its thread), [`harness_login`] (one sign-in per
//! person: a Claude or Codex login on one of their machines is kept for them
//! and written on their next machine) and `harness_login_thread` (its
//! thread).

#[cfg(target_os = "linux")]
mod bootstrap_role;
pub mod client;
pub mod github;
#[cfg(unix)]
pub mod github_minter;
pub mod github_repos;
pub mod handoff;
pub mod harness_login;
#[cfg(unix)]
pub mod harness_login_thread;
pub mod private_bootstrap;
pub mod receiver;
#[cfg(target_os = "linux")]
pub mod receiver_agent;
#[cfg(target_os = "linux")]
mod receiver_files;
#[cfg(target_os = "linux")]
mod receiver_lifecycle;
#[cfg(target_os = "linux")]
pub mod role;
pub mod sender;
pub mod session;
pub mod trajectory;
#[cfg(unix)]
pub mod trajectory_thread;
pub mod wire;

#[cfg(all(test, unix))]
mod github_tests;
#[cfg(all(test, unix))]
mod handoff_tests;
#[cfg(all(test, unix))]
mod harness_login_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod trajectory_tests;

#[cfg(test)]
mod github_repos_tests;
#[cfg(test)]
mod receiver_client_tests;
#[cfg(all(test, target_os = "linux"))]
mod receiver_files_tests;
#[cfg(test)]
mod receiver_read_tests;
#[cfg(test)]
mod receiver_reply_tests;
