//! The service's rules: at most four reports a UTC day, a watchdog report a day after the last
//! one, a small outbox that forgets after two weeks, an install id that rotates monthly, and the
//! ask decision. The app keeps the timers, files and network.

use serde::{Deserialize, Serialize};

use crate::aggregate::StallAggregate;
use crate::build::{Builder, Context, MetricKitInput, fitted, safe_app};
use crate::classify::is_uuid;
use crate::report::{App, HangReport, MAX_BODY_BYTES, SCHEMA_VERSION};
use crate::scan::{Finding, Scanner};

pub const DAILY_LIMIT: i64 = 4;
pub const WATCHDOG_REPORT_INTERVAL_S: f64 = 24.0 * 60.0 * 60.0;
pub const MAX_WAITING: usize = 8;
pub const OUTBOX_LIMIT: usize = 3;
pub const OUTBOX_MAX_AGE_S: f64 = 14.0 * 24.0 * 60.0 * 60.0;
pub const INSTALL_ID_ROTATION_S: f64 = 30.0 * 24.0 * 60.0 * 60.0;

/// The UTC day of a Unix time, `yyyy-MM-dd`.
pub fn day(unix_seconds: f64) -> String {
    let days = (unix_seconds / 86_400.0).floor();
    let days = if days.is_finite() { days.clamp(-1e9, 1e9) as i64 } else { 0 };
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

/// The send log (times are Unix seconds).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SendLog {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_sent_at: Option<f64>,
    pub day: String,
    pub sent_today: i64,
}

/// Takes one of today's sends: the updated log to save, or `None` when today's are used up.
pub fn take_send_slot(log: &SendLog, now: f64) -> Option<SendLog> {
    let today = day(now);
    let sent_today = if log.day == today { log.sent_today } else { 0 };
    (sent_today < DAILY_LIMIT).then(|| SendLog {
        last_sent_at: Some(now),
        day: today,
        sent_today: sent_today + 1,
    })
}

/// At launch: a watchdog report is due a day after the last send, when the watchdog saw anything.
pub fn launch_due(last_sent_at: Option<f64>, now: f64, watchdog_empty: bool) -> bool {
    let since = last_sent_at.map_or(f64::INFINITY, |last| now - last);
    since >= WATCHDOG_REPORT_INTERVAL_S && !watchdog_empty
}

/// A queued report file: its name and modification time (Unix seconds; none reads as long ago).
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct OutboxEntry {
    pub name: String,
    #[serde(default)]
    pub modified: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct OutboxPlan {
    /// Too old: delete.
    pub expired: Vec<String>,
    /// The rest, oldest first: send in this order.
    pub ordered: Vec<String>,
    /// After a new report is queued: the oldest beyond the limit, to delete.
    pub trim: Vec<String>,
}

pub fn outbox_plan(entries: &[OutboxEntry], now: f64) -> OutboxPlan {
    let mut plan = OutboxPlan::default();
    let mut kept: Vec<(&str, f64)> = Vec::new();
    for entry in
        entries.iter().filter(|entry| entry.name.ends_with(".json") && entry.name.len() > 5)
    {
        let modified = entry.modified.unwrap_or(f64::NEG_INFINITY);
        if now - modified > OUTBOX_MAX_AGE_S {
            plan.expired.push(entry.name.clone());
        } else {
            kept.push((&entry.name, modified));
        }
    }
    kept.sort_by(|a, b| a.1.total_cmp(&b.1));
    plan.ordered = kept.iter().map(|(name, _)| (*name).to_owned()).collect();
    plan.trim = plan
        .ordered
        .iter()
        .take(plan.ordered.len().saturating_sub(OUTBOX_LIMIT))
        .cloned()
        .collect();
    plan
}

/// The saved install id is kept while it is a uuid made in the last 30 days.
pub fn install_id_valid(id: Option<&str>, created: Option<f64>, now: f64) -> bool {
    match (id, created) {
        (Some(id), Some(created)) => {
            is_uuid(id) && created <= now && now - created < INSTALL_ID_ROTATION_S
        }
        _ => false,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Ask {
    Send,
    Confirm,
    Invite,
    Off,
}

pub fn ask(setting_on: bool, consented: bool, invited: bool, telemetry_opt_in: bool) -> Ask {
    if setting_on {
        return if consented { Ask::Send } else { Ask::Confirm };
    }
    if !invited && telemetry_opt_in { Ask::Invite } else { Ask::Off }
}

/// A queued body may still be sent: this schema, this app, and a clean scan (the outbox outlives
/// an update).
pub fn sendable(body: &[u8], app: &App, scanner: &Scanner) -> bool {
    let Ok(report) = serde_json::from_slice::<HangReport>(body) else { return false };
    report.schema == SCHEMA_VERSION
        && report.app == safe_app(app)
        && scanner.findings(body).is_empty()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ComposeStatus {
    /// Nothing worth sending.
    Empty,
    /// Over the body limit even fitted.
    TooLarge,
    /// The leak scan found something: never sent.
    Refused,
    Ok,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Composed {
    pub status: ComposeStatus,
    /// The wire bytes (status `ok`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    /// The readable copy (status `ok`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub readable: Option<String>,
    pub findings: Vec<Finding>,
}

/// Builds, fits, encodes and scans one report.
pub fn compose(
    builder: &Builder,
    scanner: &Scanner,
    context: &Context,
    watchdog: &StallAggregate,
    metric_kit: &[MetricKitInput],
) -> Composed {
    let report = fitted(builder.build(context, watchdog, metric_kit));
    let refuse = |status| Composed { status, body: None, readable: None, findings: Vec::new() };
    if report.has_no_findings() {
        return refuse(ComposeStatus::Empty);
    }
    let body = report.wire();
    if body.len() > MAX_BODY_BYTES {
        return refuse(ComposeStatus::TooLarge);
    }
    let findings = scanner.findings(&body);
    if !findings.is_empty() {
        return Composed { status: ComposeStatus::Refused, body: None, readable: None, findings };
    }
    Composed {
        status: ComposeStatus::Ok,
        body: Some(String::from_utf8_lossy(&body).into_owned()),
        readable: Some(String::from_utf8_lossy(&report.readable()).into_owned()),
        findings,
    }
}

/// The readable preview (View Hang Report before anything was sent): `None` unless it scans clean.
pub fn preview(
    builder: &Builder,
    scanner: &Scanner,
    context: &Context,
    watchdog: &StallAggregate,
    metric_kit: &[MetricKitInput],
) -> Option<String> {
    let readable = builder.build(context, watchdog, metric_kit).readable();
    scanner.findings(&readable).is_empty().then(|| String::from_utf8_lossy(&readable).into_owned())
}
