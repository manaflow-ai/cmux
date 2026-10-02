//! Per-check conditions with hysteresis (server.md 9.3 table).

use super::facts::{BackupFacts, DiskFacts, GIB, HealthSettings, PowerSource};
use super::{AlertKey, AlertSet, CheckId, Facts, Severity};

/// A condition that holds now. `delay_ms > 0` means the alert is raised only
/// after the condition held that long.
pub(super) struct Condition {
    pub key: AlertKey,
    pub severity: Severity,
    pub delay_ms: u64,
}

/// The conditions that hold at `now`, and the earliest future time at which
/// a time-based condition (backup age, WAL failure) starts to hold.
pub(super) fn conditions(facts: &Facts, now_ms: u64, prev: &AlertSet) -> (Vec<Condition>, Option<u64>) {
    let s = &facts.settings;
    let prev_sev = |key: &AlertKey| prev.get(key).map(|a| a.severity);
    let mut out = Vec::new();
    let mut push = |key: AlertKey, severity: Severity, delay_ms: u64| {
        if !s.disabled.contains(&key.check) {
            out.push(Condition { key, severity, delay_ms });
        }
    };

    if let Some(power) = facts.power
        && power.source == PowerSource::Battery
    {
        let key = AlertKey::check(CheckId::PowerOnBattery);
        let latched = prev_sev(&key) == Some(Severity::Critical);
        let severity = battery_severity(s, power.battery_percent, latched);
        push(key, severity, s.on_battery_delay_ms);
    }
    if !facts.link_up && !facts.has_route {
        push(AlertKey::check(CheckId::NetworkOffline), Severity::Critical, s.offline_delay_ms);
    }
    if let Some(disk) = facts.disk {
        let key = AlertKey::check(CheckId::DiskLow);
        if let Some(severity) = disk_severity(s, &disk, prev_sev(&key)) {
            push(key, severity, 0);
        }
    }
    if let Some(lock) = facts.lock
        && !lock.display_assertion_held
        && lock.gui_workload_active
        && lock.idle_lock_due_secs.is_some_and(|due| due <= s.lock_due_window_secs)
    {
        push(AlertKey::check(CheckId::LockPending), Severity::Warning, 0);
    }
    let flags = [
        (facts.sleep_on_ac_enabled == Some(true), CheckId::SleepEnabled, Severity::Info),
        (facts.autorestart == Some(false), CheckId::RestartNoAutoRestart, Severity::Info),
        (
            facts.filevault_on == Some(true) && facts.autologin == Some(false),
            CheckId::RestartFileVaultWait,
            Severity::Warning,
        ),
        (facts.headless_agent_not_logged_in, CheckId::RestartNotLoggedIn, Severity::Warning),
        (facts.linger == Some(false), CheckId::LingerOff, Severity::Critical),
        (facts.encryption_on == Some(false), CheckId::EncryptionOff, Severity::Info),
    ];
    for (holds, check, severity) in flags {
        if holds {
            push(AlertKey::check(check), severity, 0);
        }
    }
    for usage in &facts.quota {
        let key = AlertKey { check: CheckId::PostgresQuota, subject: Some(usage.app.clone()) };
        let latched = prev_sev(&key).is_some();
        let pct = if latched { s.quota_warning_percent.saturating_sub(s.clear_margin) } else { s.quota_warning_percent };
        if usage.quota_bytes > 0 && at_least_percent(usage.bytes, usage.quota_bytes, pct) {
            push(key, Severity::Warning, 0);
        }
    }
    let mut deadline = None;
    if let Some(backup) = facts.backup {
        let (stale, next) = backup_state(s, &backup, now_ms);
        if stale {
            push(AlertKey::check(CheckId::BackupStale), Severity::Warning, 0);
        }
        deadline = next;
    }
    (out, deadline)
}

fn battery_severity(s: &HealthSettings, percent: Option<u8>, latched_critical: bool) -> Severity {
    let Some(pct) = percent else { return Severity::Warning };
    let threshold = if latched_critical {
        s.battery_critical_percent.saturating_add(s.clear_margin)
    } else {
        s.battery_critical_percent
    };
    if pct < threshold { Severity::Critical } else { Severity::Warning }
}

/// `part / whole >= pct %`, without overflow.
fn at_least_percent(part: u64, whole: u64, pct: u8) -> bool {
    u128::from(part) * 100 >= u128::from(whole) * u128::from(pct)
}

fn below(disk: &DiskFacts, pct: u8, bytes: u64) -> bool {
    !at_least_percent(disk.free_bytes, disk.total_bytes, pct) || disk.free_bytes < bytes
}

/// Warning under 10% or 10 GiB free, critical under 5% or 2 GiB. A raised
/// level holds until free space is `clear_margin` points (and GiB) above its
/// threshold.
fn disk_severity(s: &HealthSettings, disk: &DiskFacts, prev: Option<Severity>) -> Option<Severity> {
    if disk.total_bytes == 0 {
        return None;
    }
    let m = s.clear_margin;
    let margin_bytes = u64::from(m) * GIB;
    let critical = below(disk, s.disk_critical_percent, s.disk_critical_bytes);
    let warning = below(disk, s.disk_warning_percent, s.disk_warning_bytes);
    let critical_hold =
        below(disk, s.disk_critical_percent.saturating_add(m), s.disk_critical_bytes.saturating_add(margin_bytes));
    let warning_hold =
        below(disk, s.disk_warning_percent.saturating_add(m), s.disk_warning_bytes.saturating_add(margin_bytes));
    let level = match prev {
        Some(Severity::Critical) if critical_hold => Severity::Critical,
        Some(Severity::Critical | Severity::Warning) if critical => Severity::Critical,
        Some(Severity::Critical | Severity::Warning) if warning_hold => Severity::Warning,
        Some(Severity::Critical | Severity::Warning) => return None,
        _ if critical => Severity::Critical,
        _ if warning => Severity::Warning,
        _ => return None,
    };
    Some(level)
}

/// Whether the backup is stale at `now`, and when it next becomes stale if
/// it is not.
fn backup_state(s: &HealthSettings, b: &BackupFacts, now_ms: u64) -> (bool, Option<u64>) {
    let base_due = b.last_base_backup_at_ms.unwrap_or(b.cluster_created_at_ms).saturating_add(s.backup_max_age_ms);
    let wal_due = b.wal_failing_since_ms.map(|t| t.saturating_add(s.wal_failing_max_ms));
    let dues = std::iter::once(base_due).chain(wal_due);
    let stale = dues.clone().any(|due| due <= now_ms);
    let next = if stale { None } else { dues.min() };
    (stale, next)
}
