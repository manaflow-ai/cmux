//! Restart to Update hands the app to Sparkle's installer, which swaps the
//! bundle after the app quit. Just before the relaunch the app records which
//! build it installs over which; the next launch judges the record here.

use serde::Serialize;

/// A record older than this (seconds) judges nothing.
pub const MAX_AGE: f64 = 24.0 * 60.0 * 60.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InstallOutcome {
    /// The relaunch runs the build Sparkle installed.
    Installed,
    /// The relaunch runs the build the install was meant to replace.
    Failed,
}

/// The outcome for a launch of `running_build`, or none when the record says
/// nothing about it: stale, written more than a minute in the future, a no-op
/// install, or a third build (one installed by hand). Times are seconds since 1970.
pub fn outcome(
    from_build: &str,
    target_build: &str,
    recorded_at: f64,
    running_build: &str,
    now: f64,
) -> Option<InstallOutcome> {
    let age = now - recorded_at;
    // NaN times judge nothing, as Swift's comparisons are false for NaN.
    if !(-60.0..=MAX_AGE).contains(&age) || from_build == target_build {
        return None;
    }
    if running_build == target_build {
        return Some(InstallOutcome::Installed);
    }
    if running_build == from_build {
        return Some(InstallOutcome::Failed);
    }
    None
}
