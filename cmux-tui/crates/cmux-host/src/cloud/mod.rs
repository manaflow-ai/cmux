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
//! auth over the [`client::Http`] and [`client::Store`] traits), `role`
//! (the Linux worker).

pub mod client;
#[cfg(target_os = "linux")]
pub mod role;
pub mod sender;
pub mod session;
pub mod wire;

#[cfg(test)]
mod tests;
