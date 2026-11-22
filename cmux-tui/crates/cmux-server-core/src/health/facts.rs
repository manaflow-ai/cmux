//! Probe facts (server.md 9.2) and health settings (server.md 13,
//! `server.health.alerts.<check>`).
//!
//! `None` means "not known or not applicable here" (a Linux box has no
//! FileVault, the team VM has no battery). A check with an unknown fact is
//! not raised, and an open alert whose fact becomes unknown is resolved.

use std::collections::BTreeSet;

use super::{CheckId, HostId};
use crate::platform::{InstallMode, Platform};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerSource {
    Ac,
    Battery,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PowerFacts {
    pub source: PowerSource,
    /// 0..=100 when the machine has a battery.
    pub battery_percent: Option<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DiskFacts {
    pub free_bytes: u64,
    pub total_bytes: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LockFacts {
    /// cmux holds the display (idle lock) assertion.
    pub display_assertion_held: bool,
    /// When the idle lock is due (Unix ms), if one is configured. Absolute,
    /// so the reducer can set a one-shot deadline at `due - window`.
    pub idle_lock_due_at_ms: Option<u64>,
    /// A GUI workload runs (computer use, a headful browser).
    pub gui_workload_active: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuotaUsage {
    /// A validated app id (`pg::AppId`), used as the alert subject.
    pub app: String,
    pub bytes: u64,
    pub quota_bytes: u64,
}

/// Linux logind inhibitors the server holds, one file descriptor per kind
/// (server.md 9.1). Without the polkit rule, logind grants a lingering
/// user without a session only `idle`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InhibitFacts {
    pub idle: bool,
    pub sleep: bool,
    pub handle_lid_switch: bool,
}

/// Backup facts as timestamps, so the reducer can compute the deadline at
/// which a backup becomes stale without a new probe.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BackupFacts {
    /// When the cluster was created (a cluster without any base backup is
    /// stale 48 h after creation).
    pub cluster_created_at_ms: u64,
    pub last_base_backup_at_ms: Option<u64>,
    /// Since when `archive_command` has been failing, if it is.
    pub wal_failing_since_ms: Option<u64>,
}

/// Thresholds and switches. Defaults are server.md 9.3.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HealthSettings {
    pub disabled: BTreeSet<CheckId>,
    pub on_battery_delay_ms: u64,
    pub battery_critical_percent: u8,
    pub offline_delay_ms: u64,
    pub disk_warning_percent: u8,
    pub disk_warning_bytes: u64,
    pub disk_critical_percent: u8,
    pub disk_critical_bytes: u64,
    /// An alert clears (or de-escalates) only this many percentage points
    /// above its threshold, and this many GiB above the byte threshold.
    pub clear_margin: u8,
    pub lock_due_window_ms: u64,
    pub quota_warning_percent: u8,
    pub backup_max_age_ms: u64,
    pub wal_failing_max_ms: u64,
}

pub const GIB: u64 = 1 << 30;

impl HealthSettings {
    /// Free bytes under which `disk.low` (warning) raises on a disk of
    /// `total_bytes`: under the percent AND under the byte threshold, so
    /// the smaller of the two. The I/O crate sizes its next disk re-check
    /// from the headroom above this line.
    pub fn disk_warning_line(&self, total_bytes: u64) -> u64 {
        let pct = u128::from(total_bytes) * u128::from(self.disk_warning_percent) / 100;
        (pct as u64).min(self.disk_warning_bytes)
    }
}

impl Default for HealthSettings {
    fn default() -> Self {
        HealthSettings {
            disabled: BTreeSet::new(),
            on_battery_delay_ms: 60_000,
            battery_critical_percent: 20,
            offline_delay_ms: 30_000,
            disk_warning_percent: 10,
            disk_warning_bytes: 10 * GIB,
            disk_critical_percent: 5,
            disk_critical_bytes: 2 * GIB,
            clear_margin: 2,
            lock_due_window_ms: 300_000,
            quota_warning_percent: 80,
            backup_max_age_ms: 48 * 3600 * 1000,
            wal_failing_max_ms: 10 * 60 * 1000,
        }
    }
}

/// Everything the reducer reads. The I/O crate fills it from probe events.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facts {
    /// The stable host id in dedupe keys (`host_…`, or the install id
    /// `inst_…` before pairing); never a display name, which can change.
    pub host_id: HostId,
    pub platform: Platform,
    pub mode: InstallMode,
    pub settings: HealthSettings,
    pub power: Option<PowerFacts>,
    /// The link to the control plane is connected.
    pub link_up: bool,
    /// The OS has a default route.
    pub has_route: bool,
    pub disk: Option<DiskFacts>,
    pub lock: Option<LockFacts>,
    pub sleep_on_ac_enabled: Option<bool>,
    pub autorestart: Option<bool>,
    pub filevault_on: Option<bool>,
    pub autologin: Option<bool>,
    /// macOS headless install with a LaunchAgent and no login since boot.
    pub headless_agent_not_logged_in: bool,
    /// Linux user mode: `loginctl` linger for the user.
    pub linger: Option<bool>,
    /// Linux: the inhibitors held.
    pub inhibitors: Option<InhibitFacts>,
    pub encryption_on: Option<bool>,
    pub quota: Vec<QuotaUsage>,
    pub backup: Option<BackupFacts>,
}

impl Facts {
    /// Nothing known: no check raises, and every open alert is kept.
    pub fn unknown(host_id: HostId, platform: Platform, mode: InstallMode) -> Facts {
        Facts {
            host_id,
            platform,
            mode,
            settings: HealthSettings::default(),
            power: None,
            link_up: true,
            has_route: true,
            disk: None,
            lock: None,
            sleep_on_ac_enabled: None,
            autorestart: None,
            filevault_on: None,
            autologin: None,
            headless_agent_not_logged_in: false,
            linger: None,
            inhibitors: None,
            encryption_on: None,
            quota: Vec::new(),
            backup: None,
        }
    }

    /// Every fact known and healthy, except backups (they depend on `now`;
    /// the caller sets them). For tests and previews.
    pub fn healthy(host_id: HostId, platform: Platform, mode: InstallMode) -> Facts {
        let big = 1u64 << 50;
        Facts {
            power: Some(PowerFacts { source: PowerSource::Ac, battery_percent: None }),
            disk: Some(DiskFacts { free_bytes: big, total_bytes: big }),
            lock: Some(LockFacts {
                display_assertion_held: true,
                idle_lock_due_at_ms: None,
                gui_workload_active: false,
            }),
            sleep_on_ac_enabled: Some(false),
            autorestart: Some(true),
            filevault_on: Some(false),
            autologin: Some(false),
            linger: Some(true),
            inhibitors: Some(InhibitFacts { idle: true, sleep: true, handle_lid_switch: true }),
            encryption_on: Some(true),
            ..Facts::unknown(host_id, platform, mode)
        }
    }
}
