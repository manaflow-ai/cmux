//! One-click fix descriptors (server.md 9.4), as data only.
//!
//! A fix is exactly one of: an argv template run by the privileged path
//! (`{user}` is the only placeholder, filled with a validated value), a
//! settings URL the client opens, or an internal action of the health or
//! postgres role. Nothing here runs anything; the executor in `cmux-server`
//! has a dry-run mode that prints the rendered argv.
//!
//! The macOS settings URLs are the System Settings deep links of macOS 13
//! and later (UNVERIFIED on macOS 26 until the helper prototype).

use super::CheckId;
use crate::pg::valid_os_user;
use crate::platform::{InstallMode, Platform};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fix {
    /// Stable id: `server.health.fix {check, fix}`.
    pub id: &'static str,
    pub check: CheckId,
    pub platform: Platform,
    /// `None`: both modes.
    pub mode: Option<InstallMode>,
    pub title_key: &'static str,
    pub argv: Option<&'static [&'static str]>,
    pub opens_settings_url: Option<&'static str>,
    /// An action the server performs itself (`hold-display-assertion`, …).
    pub internal: Option<&'static str>,
    pub needs_admin: bool,
}

const fn argv(
    id: &'static str,
    check: CheckId,
    platform: Platform,
    mode: Option<InstallMode>,
    title_key: &'static str,
    argv: &'static [&'static str],
) -> Fix {
    Fix {
        id,
        check,
        platform,
        mode,
        title_key,
        argv: Some(argv),
        opens_settings_url: None,
        internal: None,
        needs_admin: true,
    }
}

const fn url(
    id: &'static str,
    check: CheckId,
    platform: Platform,
    title_key: &'static str,
    url: &'static str,
) -> Fix {
    Fix {
        id,
        check,
        platform,
        mode: None,
        title_key,
        argv: None,
        opens_settings_url: Some(url),
        internal: None,
        needs_admin: false,
    }
}

const fn internal(
    id: &'static str,
    check: CheckId,
    platform: Platform,
    title_key: &'static str,
    action: &'static str,
    needs_admin: bool,
) -> Fix {
    Fix {
        id,
        check,
        platform,
        mode: None,
        title_key,
        argv: None,
        opens_settings_url: None,
        internal: Some(action),
        needs_admin,
    }
}

use CheckId as C;
use Platform::{Linux, MacOs, Windows};

pub static FIXES: &[Fix] = &[
    // macOS
    argv(
        "pmset.noSleepOnAc",
        C::SleepEnabled,
        MacOs,
        None,
        "server.health.fix.noSleepOnAc",
        &["/usr/bin/pmset", "-c", "sleep", "0", "disksleep", "0"],
    ),
    argv(
        "pmset.autorestart",
        C::RestartNoAutoRestart,
        MacOs,
        None,
        "server.health.fix.autorestart",
        &["/usr/bin/pmset", "-a", "autorestart", "1"],
    ),
    internal(
        "holdDisplayAssertion",
        C::LockPending,
        MacOs,
        "server.health.fix.holdDisplay",
        "hold-display-assertion",
        false,
    ),
    url(
        "lockScreenSettings",
        C::LockPending,
        MacOs,
        "server.health.fix.openLockScreen",
        "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
    ),
    url(
        "storageSettings",
        C::DiskLow,
        MacOs,
        "server.health.fix.openStorage",
        "x-apple.systempreferences:com.apple.settings.Storage",
    ),
    url(
        "fileVaultSettings",
        C::EncryptionOff,
        MacOs,
        "server.health.fix.openEncryption",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
    ),
    internal(
        "installLaunchDaemon",
        C::RestartNotLoggedIn,
        MacOs,
        "server.health.fix.installLaunchDaemon",
        "install-launch-daemon",
        true,
    ),
    // Linux
    argv(
        "systemd.maskSleep",
        C::SleepEnabled,
        Linux,
        None,
        "server.health.fix.maskSleep",
        &[
            "/usr/bin/systemctl",
            "mask",
            "sleep.target",
            "suspend.target",
            "hibernate.target",
            "hybrid-sleep.target",
        ],
    ),
    argv(
        "loginctl.enableLinger",
        C::LingerOff,
        Linux,
        Some(InstallMode::User),
        "server.health.fix.enableLinger",
        &["/usr/bin/loginctl", "enable-linger", "{user}"],
    ),
    // Windows
    argv(
        "powercfg.noStandbyOnAc",
        C::SleepEnabled,
        Windows,
        None,
        "server.health.fix.noSleepOnAc",
        &["powercfg.exe", "/change", "standby-timeout-ac", "0"],
    ),
    url(
        "storageSense",
        C::DiskLow,
        Windows,
        "server.health.fix.openStorage",
        "ms-settings:storagesense",
    ),
    url(
        "deviceEncryption",
        C::EncryptionOff,
        Windows,
        "server.health.fix.openEncryption",
        "ms-settings:deviceencryption",
    ),
    // Every platform
    internal(
        "raiseQuota",
        C::PostgresQuota,
        Linux,
        "server.health.fix.raiseQuota",
        "raise-quota",
        false,
    ),
    internal(
        "raiseQuota",
        C::PostgresQuota,
        MacOs,
        "server.health.fix.raiseQuota",
        "raise-quota",
        false,
    ),
    internal(
        "raiseQuota",
        C::PostgresQuota,
        Windows,
        "server.health.fix.raiseQuota",
        "raise-quota",
        false,
    ),
    internal(
        "backupNow",
        C::BackupStale,
        Linux,
        "server.health.fix.backupNow",
        "backup-now",
        false,
    ),
    internal(
        "backupNow",
        C::BackupStale,
        MacOs,
        "server.health.fix.backupNow",
        "backup-now",
        false,
    ),
    internal(
        "backupNow",
        C::BackupStale,
        Windows,
        "server.health.fix.backupNow",
        "backup-now",
        false,
    ),
];

/// The fixes offered for `check` on `platform` in `mode`, in table order.
pub fn fixes_for(
    check: CheckId,
    platform: Platform,
    mode: InstallMode,
) -> impl Iterator<Item = &'static Fix> {
    FIXES.iter().filter(move |f| {
        f.check == check && f.platform == platform && f.mode.is_none_or(|m| m == mode)
    })
}

/// Values for argv placeholders.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FixValues {
    /// The installing user (`{user}`).
    pub user: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FixError {
    NotArgv,
    MissingValue(&'static str),
    InvalidValue(&'static str),
    UnknownPlaceholder(String),
}

/// The argv for `fix` with placeholders filled. A value is accepted only
/// when it passes its validator, and it always fills a whole argument.
pub fn render_argv(fix: &Fix, values: &FixValues) -> Result<Vec<String>, FixError> {
    let template = fix.argv.ok_or(FixError::NotArgv)?;
    template
        .iter()
        .map(|arg| match *arg {
            "{user}" => {
                let user = values.user.as_deref().ok_or(FixError::MissingValue("user"))?;
                if valid_os_user(user) {
                    Ok(user.to_owned())
                } else {
                    Err(FixError::InvalidValue("user"))
                }
            }
            a if a.contains(['{', '}']) => Err(FixError::UnknownPlaceholder(a.to_owned())),
            a => Ok(a.to_owned()),
        })
        .collect()
}
