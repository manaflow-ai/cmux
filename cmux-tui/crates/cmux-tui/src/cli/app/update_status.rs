//! `cmux update status`: whether the app's automatic updater runs now and,
//! when it does not, why; its last check, channel and the version it found.
//!
//! Leo, 2026-11-27: "as in like us seeing a thing with the bottom elft
//! sidebar the auto update no longer being force paused". `cmux version`
//! prints the phase and `settings explain updates.automatic` the setting, but
//! neither says whether the running updater is paused. This reads the
//! updater's own state (`updates.status`, whose `automation` object carries
//! the raw facts: the build's pause, Sparkle's schedule and last check, the
//! download setting as applied, the link, the managed policy, the idle
//! install's hold) and decides here, in one place, what counts as paused and
//! for which reasons. Nothing here changes any state.
//!
//! An app older than the `automation` facts still answers: `paused` then
//! follows `automatic_checks` and `automatic_downloads`, and the reasons say
//! that the app cannot tell why.

use std::time::Duration;

use cmux_json::JsonGet as _;
use serde_json::{Value, json};

use super::super::{GlobalArgs, OutputMode, UsageError};
use crate::localization::UpdateStatusMessages;

/// `updates.status` answers inside the app's own 2 s control deadline.
const READ_TIMEOUT: Duration = Duration::from_secs(3);

/// `cmux update [status]`. `args` starts with `update`.
pub(super) fn parse(args: &[String]) -> Result<(), UsageError> {
    let messages = &crate::localization::catalog().app_control.update_status;
    match &args[1..] {
        [] => Ok(()),
        [verb] if verb == "status" => Ok(()),
        _ => Err(UsageError::new(messages.usage)),
    }
}

/// Reads `updates.status` and prints the report (exit 0), or the app's error.
pub(super) fn run(global: &GlobalArgs) -> i32 {
    let mut stream = match super::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::super::wire::print_local_error(&error, global.output, 3),
    };
    let status = match super::exchange(&mut stream, "updates.status", json!({}), READ_TIMEOUT) {
        Ok(Ok(status)) => status,
        Ok(Err(error)) => return super::super::wire::print_local_error(&error, global.output, 1),
        Err(error) => return super::failure("app.transport", &error, global.output, 3),
    };
    let messages = &crate::localization::catalog().app_control.update_status;
    let value = report(&status, messages);
    match global.output {
        OutputMode::Human => {
            print!("{}", human(&value, messages));
            0
        }
        _ => super::super::wire::print_local_success(&value, global.output),
    }
}

/// One reason automatic updates do not run as set: a stable `code`, who
/// decided it (`person`, `build`, `organization`, `network`, `app`) and a line.
fn reason(code: &str, by: &str, text: String) -> Value {
    json!({ "code": code, "by": by, "text": text })
}

/// The report `cmux update status --json` prints, from `updates.status`.
pub(super) fn report(status: &Value, messages: &UpdateStatusMessages) -> Value {
    let facts = status.get("automation").filter(|facts| facts.is_object());
    let flag = |value: Option<&Value>, key: &str| value.and_then(|v| v.get_bool(key));
    let sparkle_enabled = status.get_bool("sparkle_enabled").unwrap_or(false);
    let automatic_downloads = status.get_bool("automatic_downloads").unwrap_or(false);
    let check_interval =
        facts.and_then(|f| f.get("check_interval_seconds")).and_then(Value::as_f64);
    let checks_running = match facts {
        Some(_) => sparkle_enabled && check_interval.is_some(),
        None => status.get_bool("automatic_checks").unwrap_or(false),
    };

    let mut reasons = Vec::new();
    if !sparkle_enabled {
        let why = status.get_nonempty_str("sparkle_disabled_reason").unwrap_or("?");
        reasons.push(reason("updater_off", "build", messages.updater_off.replace("{reason}", why)));
    }
    match facts {
        None => {
            if sparkle_enabled && !(checks_running && automatic_downloads) {
                reasons.push(reason("unknown", "app", messages.unknown.to_owned()));
            }
        }
        Some(facts) => {
            let facts = Some(facts);
            if flag(facts, "paused_by_build") == Some(true) {
                reasons.push(reason("build_pause", "build", messages.build_pause.to_owned()));
            }
            if flag(facts, "managed_policy_disables") == Some(true) {
                reasons.push(reason(
                    "managed_policy",
                    "organization",
                    messages.managed_policy.to_owned(),
                ));
            }
            let builds_pause = !reasons.is_empty();
            if flag(facts, "settings_applied") == Some(false) {
                reasons.push(reason("starting", "app", messages.starting.to_owned()));
            }
            if sparkle_enabled && !builds_pause && check_interval.is_none() {
                reasons.push(reason("checks_off", "person", messages.checks_off.to_owned()));
            }
            if sparkle_enabled && !builds_pause && !automatic_downloads {
                reasons.extend(download_reasons(facts, messages));
            }
        }
    }
    let paused = !reasons.is_empty();
    let hold = status.get("relaunch_hold").filter(|hold| hold.is_object());

    json!({
        "paused": paused,
        "reasons": reasons,
        "checks": {
            "automatic": checks_running,
            "interval_seconds": check_interval,
        },
        "downloads": { "automatic": sparkle_enabled && automatic_downloads },
        "install_when_idle": facts.map(|f| f.get("install_when_idle_seconds").is_some_and(|v| !v.is_null())),
        "install_hold": hold.map(|hold| json!({
            "reason": hold.get_nonempty_str("reason"),
            "since": hold.get_nonempty_str("since"),
            "surfaced": hold.get_bool("surfaced"),
        })),
        "last_check": last_check(status, facts),
        "last_check_error": status.get_nonempty_str("last_probe_error"),
        "channel": status.get_nonempty_str("ring"),
        "track": status.get_nonempty_str("track"),
        "installed": { "version": status.get_nonempty_str("version"), "build": status.get_nonempty_str("build") },
        "available": available(status, facts),
        "phase": status.get_nonempty_str("phase"),
        "feed_url": status.get_nonempty_str("feed_url"),
    })
}

/// Why a found update waits for a click while automatic checks may run.
fn download_reasons(facts: Option<&Value>, messages: &UpdateStatusMessages) -> Vec<Value> {
    let flag = |key: &str| facts.and_then(|f| f.get_bool(key)) == Some(true);
    let mut reasons = Vec::new();
    // Update When Idle downloads found updates too, whatever the download setting says.
    let idle = facts.and_then(|f| f.get("install_when_idle_seconds")).is_some_and(|v| !v.is_null());
    if facts.and_then(|f| f.get_bool("download_setting")) == Some(false) && !idle {
        reasons.push(reason(
            "downloads_by_click",
            "person",
            messages.downloads_by_click.to_owned(),
        ));
        return reasons;
    }
    if flag("off_managed_channel") {
        reasons.push(reason(
            "off_managed_channel",
            "organization",
            messages.off_managed_channel.to_owned(),
        ));
    }
    let metered =
        facts.and_then(|f| f.get_nonempty_str("metered_mode")).unwrap_or("defer-low-data");
    if metered != "download" {
        if flag("network_pending") {
            reasons.push(reason("network_pending", "network", messages.network_pending.to_owned()));
        } else if flag("network_constrained") {
            reasons.push(reason("low_data", "network", messages.low_data.to_owned()));
        } else if metered == "defer-expensive" && flag("network_expensive") {
            reasons.push(reason("expensive_link", "network", messages.expensive_link.to_owned()));
        }
    }
    if flag("download_held_for_deltas") {
        reasons.push(reason("held_for_deltas", "app", messages.held_for_deltas.to_owned()));
    }
    if reasons.is_empty() {
        reasons.push(reason("downloads_off", "app", messages.downloads_off.to_owned()));
    }
    reasons
}

/// The newest of Sparkle's last check and the last read-only probe, with which one it was.
fn last_check(status: &Value, facts: Option<&Value>) -> Value {
    let sparkle = facts.and_then(|f| f.get_nonempty_str("last_check"));
    let probe = status.get("last_probe").and_then(|probe| probe.get_nonempty_str("checked_at"));
    // Both are ISO 8601 in UTC from one formatter, so they order as strings.
    let (at, source) = match (sparkle, probe) {
        (Some(s), Some(p)) if p > s => (p, "probe"),
        (Some(s), _) => (s, "updater"),
        (None, Some(p)) => (p, "probe"),
        (None, None) => return Value::Null,
    };
    let result = if source == "probe" {
        status.get("last_probe").and_then(|probe| probe.get_nonempty_str("result"))
    } else {
        None
    };
    json!({ "at": at, "source": source, "result": result })
}

/// The newest version the updater knows of beyond the running one, and where it learned it.
fn available(status: &Value, facts: Option<&Value>) -> Value {
    if let Some(version) = status.get_nonempty_str("detected_version") {
        return json!({ "version": version, "source": "updater" });
    }
    let probe = status.get("last_probe").filter(|probe| probe.is_object());
    if let Some(offered) = probe.and_then(|probe| probe.get("offered")).filter(|v| v.is_object()) {
        let version = offered
            .get_nonempty_str("display_version")
            .or_else(|| offered.get_nonempty_str("version"));
        if let Some(version) = version {
            return json!({ "version": version, "source": "probe" });
        }
    }
    if let Some(version) = facts.and_then(|f| f.get_nonempty_str("feed_newest")) {
        return json!({ "version": version, "source": "feed", "at": facts.and_then(|f| f.get_nonempty_str("feed_read_at")) });
    }
    Value::Null
}

/// The plain-text report, one fact per line.
pub(super) fn human(report: &Value, messages: &UpdateStatusMessages) -> String {
    let mut out = String::new();
    let mut line = |label: &str, value: String| out.push_str(&format!("{label:<18} {value}\n"));
    let paused = report["paused"].as_bool() == Some(true);
    line(messages.automatic, (if paused { messages.paused } else { messages.running }).to_owned());
    if let Some(reasons) = report["reasons"].as_array() {
        for reason in reasons {
            line(messages.why, reason.get_nonempty_str("text").unwrap_or("-").to_owned());
        }
    }
    let checks = match (
        report["checks"]["automatic"].as_bool(),
        report["checks"]["interval_seconds"].as_f64(),
    ) {
        (Some(true), Some(seconds)) => messages.every.replace("{interval}", &interval(seconds)),
        (Some(true), None) => messages.on.to_owned(),
        _ => messages.off.to_owned(),
    };
    line(messages.checks, checks);
    let downloads = if report["downloads"]["automatic"].as_bool() == Some(true) {
        messages.automatically
    } else {
        messages.on_click
    };
    line(messages.downloads, downloads.to_owned());
    if let Some(hold) = report["install_hold"].as_object() {
        let why = hold.get("reason").and_then(Value::as_str).unwrap_or("-");
        let since = hold.get("since").and_then(Value::as_str).unwrap_or("-");
        line(
            messages.install_held,
            messages.held_since.replace("{reason}", why).replace("{since}", since),
        );
    }
    let last = &report["last_check"];
    let last_line = match last.get_nonempty_str("at") {
        Some(at) => match last.get_nonempty_str("result") {
            Some(result) => format!("{at} ({result})"),
            None => at.to_owned(),
        },
        None => messages.never.to_owned(),
    };
    line(messages.last_check, last_line);
    if let Some(error) = report.get_nonempty_str("last_check_error") {
        line(messages.last_error, error.to_owned());
    }
    let channel = match (report.get_nonempty_str("channel"), report.get_nonempty_str("track")) {
        (Some(ring), Some(track)) => format!("{ring} ({track})"),
        (Some(one), None) | (None, Some(one)) => one.to_owned(),
        (None, None) => "-".to_owned(),
    };
    line(messages.channel, channel);
    let installed = &report["installed"];
    line(messages.installed, installed.get_nonempty_str("version").unwrap_or("-").to_owned());
    let available = report["available"]
        .get_nonempty_str("version")
        .map_or_else(|| messages.none_known.to_owned(), str::to_owned);
    line(messages.available, available);
    out
}

/// `3600` as `1h`, `900` as `15m`, `45` as `45s`.
fn interval(seconds: f64) -> String {
    let seconds = seconds.max(0.0).round() as u64;
    match seconds {
        s if s >= 3600 && s % 3600 == 0 => format!("{}h", s / 3600),
        s if s >= 60 && s % 60 == 0 => format!("{}m", s / 60),
        s => format!("{s}s"),
    }
}

#[cfg(test)]
mod tests;
