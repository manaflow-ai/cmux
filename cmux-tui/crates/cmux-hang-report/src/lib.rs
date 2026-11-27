//! The cmux macOS app's hang reports (opt-in): which frames may be named, the privacy leak scan,
//! the watchdog's day, the report and its wire bytes, and the send rules. Pure: the app reads
//! files, dyld, sysctl and the clock, passes what it read through the app FFI (cmux-app-ffi
//! `cmux-layout-reducer-ffi/src/hang_report.rs`, JSON ops in [`ops`]) and does what the reply says.
//!
//! - [`report`]: the report schema (version 2) and its wire and readable bytes.
//! - [`classify`]: which images are named (ours or Apple's, plain names without the person's words).
//! - [`tree`]: MetricKit's call stack tree, heaviest path.
//! - [`scan`]: the last check before a report leaves the Mac.
//! - [`aggregate`]: the watchdog's stall counts and longest samples.
//! - [`build`]: the report from the watchdog and MetricKit, every envelope string made safe.
//! - [`service`]: daily limits, outbox, install id rotation, the ask decision, compose.

pub mod aggregate;
pub mod build;
pub mod classify;
pub mod ops;
pub mod report;
pub mod scan;
pub mod service;
pub mod tree;

#[cfg(test)]
mod tests;
