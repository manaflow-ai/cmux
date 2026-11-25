//! Recovery 2: a UI-loop hang past the restart bound that no cancel ended hands the session to a
//! fresh client. The daemon holds every terminal, its scrollback and the layout, so the client
//! restores the outer terminal, writes a restore marker and `exec`s itself with its own arguments;
//! the new client attaches to the same session and reports the prior hang once
//! ([`take_restore_marker`]).
//!
//! A client that holds the session's terminals itself (no daemon) never restarts. Three restarts in
//! ten minutes is the limit (`CMUX_TUI_HANG_RESTARTS` carries the count across `exec`), so a client
//! that hangs at start does not loop.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::{Config, HangReport};

const AREA: &str = "hangs";
const RESTARTS_ENV: &str = "CMUX_TUI_HANG_RESTARTS";
const MAX_RESTARTS: u32 = 3;
const RESTART_WINDOW_MS: u64 = 10 * 60 * 1000;

fn marker_path(dir: &Path) -> PathBuf {
    dir.join("client-hang-restart.json")
}

/// `count:first_ms` from the environment the last restart passed on.
fn parse_restarts(value: Option<&str>) -> Option<(u32, u64)> {
    let (count, first) = value?.split_once(':')?;
    Some((count.parse().ok()?, first.parse().ok()?))
}

/// The restart count to pass on, or `None` when the limit is reached.
pub(super) fn next_restarts(previous: Option<&str>, now_ms: u64) -> Option<(u32, u64)> {
    match parse_restarts(previous) {
        Some((count, first)) if now_ms.saturating_sub(first) < RESTART_WINDOW_MS => {
            (count < MAX_RESTARTS).then_some((count + 1, first))
        }
        _ => Some((1, now_ms)),
    }
}

/// Restarts the client after `report`'s hang; returns only when it could not.
pub(super) fn restart_after_hang(
    config: &Config,
    report: &HangReport,
    restore_terminal: &(dyn Fn() + Send + Sync),
) {
    let now = super::record::now_ms();
    let previous = std::env::var(RESTARTS_ENV).ok();
    let Some((count, first)) = next_restarts(previous.as_deref(), now) else {
        crate::client_log::warn(
            AREA,
            &format!(
                "ui loop hung {:.0}s; restart limit reached, not restarting",
                report.duration.as_secs_f64()
            ),
        );
        return;
    };
    let Ok(exe) = std::env::current_exe() else { return };
    if let Some(dir) = &config.dir {
        let marker = json!({
            "at_ms": now,
            "pid": std::process::id(),
            "session": config.session,
            "duration_ms": u64::try_from(report.duration.as_millis()).unwrap_or(u64::MAX),
            "cancelled": report.cancelled,
            "waits": report.waits,
        });
        let _ = std::fs::write(marker_path(dir), marker.to_string());
    }
    crate::client_log::warn(
        AREA,
        &format!(
            "ui loop hung {:.0}s; restarting the client in place (restart {count} of {MAX_RESTARTS})",
            report.duration.as_secs_f64()
        ),
    );
    crate::client_log::flush_for_exit();
    restore_terminal();
    exec(&exe, &format!("{count}:{first}"));
}

/// Replaces this process with a fresh client: the same executable, arguments and environment
/// plus the restart count. Every descriptor past stdio is marked close-on-exec first, so the new
/// image starts with the outer terminal only, never a descriptor the old one held (`cmux_process::exec_replace`); when the exec fails, the client keeps running as it was.
#[cfg(unix)]
fn exec(exe: &Path, restarts: &str) {
    let env = std::env::vars_os()
        .filter(|(key, _)| key != RESTARTS_ENV)
        .chain(std::iter::once((RESTARTS_ENV.into(), restarts.into())));
    let error = cmux_process::exec_replace(exe, std::env::args_os().skip(1), env);
    crate::client_log::warn(AREA, &format!("restart failed: {error}"));
}

#[cfg(not(unix))]
fn exec(_exe: &Path, _restarts: &str) {}

/// At client start: when the last client restarted after a hang, says so once (client log) and
/// removes the marker.
pub(super) fn take_restore_marker(config: &Config) {
    let Some(dir) = &config.dir else { return };
    let path = marker_path(dir);
    let Ok(text) = std::fs::read_to_string(&path) else { return };
    let _ = std::fs::remove_file(&path);
    let marker: Value = serde_json::from_str(&text).unwrap_or_default();
    crate::client_log::warn(
        AREA,
        &format!(
            "restored after a UI hang: the last client (pid {}) hung {} ms and restarted; \
             the session's terminals were kept by the daemon",
            marker.get("pid").and_then(Value::as_u64).unwrap_or_default(),
            marker.get("duration_ms").and_then(Value::as_u64).unwrap_or_default(),
        ),
    );
}
