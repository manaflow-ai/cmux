//! `cmux vm pool`: the CI runner pool's surge and idle pause, over two providers.
//!
//! Leo, 2026-11-20: "can't we have some kinda scheduler type thing?", and runners "up within a second, and then
//! the entire thing is running within like 10 seconds". The pool is persistent (cmuxterm-hq#15332: no deletes,
//! no caps): its machines keep their disks, caches and registered runners. This crate only moves them between
//! running and paused:
//!
//! - `up N` resumes paused machines in parallel until they carry N runners, Freestyle first (its resume keeps
//!   memory and answers in about 0.8 s; a GCE resume takes about 14.5 s to RUNNING, RFD 0017), then watches
//!   GitHub until N of their runners are online and says how long each step took.
//! - `pause` pauses (Freestyle) or suspends (GCE) machines whose runners are all idle.
//! - `schedule` is the loop: queued `cmux-linux` jobs resume machines, machines idle past a window pause.
//!
//! `cmux vm runner new|ls|park` (runner.rs, runner_cli.rs) makes or resumes one Freestyle runner VM for one job, with
//! the user's own Freestyle key and GitHub credential.
//!
//! Nothing here deletes, stops for good or re-creates a machine: there is no delete call in this crate
//! (`tests::no_delete_path`).

pub mod cli;
pub mod freestyle;
pub mod gce;
pub mod github;
pub mod http;
pub mod load;
pub mod model;
pub mod plan;
pub mod runner;
pub mod runner_cli;
pub mod schedule;
pub mod watch;

#[cfg(test)]
mod tests;
