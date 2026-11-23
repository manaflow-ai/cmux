//! Update when idle (`updates.installWhenIdle`; on by default in NIGHTLY, off
//! in release, the build default the app names): whether a
//! downloaded app update may install and relaunch the app now (Leo,
//! 2026-11-19: "when it's idle, it's able to ... update automatically ...
//! maybe even having it as an opt-in option would be pretty interesting.
//! Yeah, like update when idle").
//!
//! The app reads the facts (seconds since the last keyboard or pointer input,
//! the screen lock, the unsent drafts) and asks here once a second
//! while a staged update waits; it installs on [`Hold`] none. The relaunch keeps
//! every terminal, agent host and running turn (the daemons outlive the app),
//! but it never starts while the person could be cut off:
//!
//! - the person is not away: away is input idle past `idle_minutes`
//!   (default 15) OR the screen locked, the definition leo-workspace
//!   `tools/host_presence.py` gates agent relaunches on (Leo, 2026-11-22:
//!   the Mac should update while he is away from the keyboard, as if someone
//!   clicked Restart to Update for him). A locked screen is away at once; an
//!   unreadable idle time with the screen not known locked is never away;
//! - an automatic install the app just declined (it did not quit): it backs
//!   off ([`retry_after_seconds`]) instead of retrying every second;
//! - an unsent draft in a composer: the person is mid-message;
//! - drafts unknown (the daemon did not answer): never guess.
//!
//! A running agent turn does not hold it: Leo's agents are always mid-turn, so
//! that hold would never let it fire, and the turn runs in the daemon, which
//! the app relaunch leaves running (Leo, 2026-11-22: "cosmic-gray was supposed
//! to auto-update when i was away from the keyboard. like, auto be de facto
//! able to click the restart button"). The relaunched app reattaches to it.
//!
//! The input check comes first, so the app reads the drafts only once the
//! person has been away long enough.

use serde::{Deserialize, Serialize};

/// The shortest idle time the setting takes, in minutes.
pub const MIN_IDLE_MINUTES: f64 = 1.0;

/// What the app knows now.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IdleFacts {
    /// `updates.installWhenIdle`.
    pub enabled: bool,
    /// `updates.installWhenIdleMinutes`; below [`MIN_IDLE_MINUTES`] (or not a
    /// number) counts as that.
    pub idle_minutes: f64,
    /// Seconds since the last keyboard or pointer input anywhere on the Mac;
    /// none when the app could not read it.
    pub input_idle_seconds: Option<f64>,
    /// Composers holding typed text not sent yet; none when unknown.
    pub unsent_drafts: Option<u32>,
    /// Whether the console session's screen is locked (`CGSSessionScreenIsLocked`);
    /// none when the app could not read it, which is never evidence of away.
    pub screen_locked: Option<bool>,
    /// Automatic installs declined in a row (the app did not quit for them).
    pub declined_installs: u32,
    /// Seconds since the last declined install; none when there was none.
    pub seconds_since_decline: Option<f64>,
}

impl Default for IdleFacts {
    fn default() -> Self {
        Self {
            enabled: false,
            idle_minutes: 15.0,
            input_idle_seconds: None,
            unsent_drafts: None,
            screen_locked: None,
            declined_installs: 0,
            seconds_since_decline: None,
        }
    }
}

/// Why the update waits.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "reason")]
pub enum Hold {
    /// The setting is off: only a click installs.
    Off,
    /// Input came too recently; `seconds_left` until the idle time is reached
    /// if nothing else happens.
    NotIdle {
        #[serde(rename = "secondsLeft")]
        seconds_left: f64,
    },
    /// A composer holds an unsent message.
    UnsentDraft,
    /// Input or drafts could not be read.
    Unknown,
    /// The last automatic install was declined; `seconds_left` until the next try.
    Backoff {
        #[serde(rename = "secondsLeft")]
        seconds_left: f64,
    },
}

/// Why the person counts as away, the reading the install acted on.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Away {
    /// The screen is locked.
    ScreenLocked,
    /// No input for `seconds`, past the idle time.
    Idle { seconds: f64 },
}

/// The decision: install now, or the hold and its reason.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub install: bool,
    pub hold: Option<Hold>,
    /// Why the person counts as away, when they do (so the app can log what it acted on).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub away: Option<Away>,
}

impl Decision {
    fn hold(hold: Hold) -> Self {
        Decision { install: false, hold: Some(hold), away: None }
    }
}

/// The first wait after a declined automatic install, in seconds.
pub const RETRY_BASE_SECONDS: f64 = 60.0;
/// The longest wait between automatic install tries, in seconds.
pub const RETRY_MAX_SECONDS: f64 = 3600.0;

/// How long to wait after `declined` automatic installs in a row before the
/// next try: none after none, then 1, 2, 4 ... minutes, capped at an hour.
pub fn retry_after_seconds(declined: u32) -> f64 {
    if declined == 0 {
        return 0.0;
    }
    let doublings = (declined - 1).min(16);
    (RETRY_BASE_SECONDS * f64::from(1u32 << doublings)).min(RETRY_MAX_SECONDS)
}

/// Whether the person is away: the screen locked, or input idle past
/// `needed` seconds. `Err(None)` when there is no reading to say so (never
/// away), `Err(Some(left))` when they are at the Mac, `left` seconds short.
pub fn away(
    input_idle_seconds: Option<f64>,
    screen_locked: Option<bool>,
    needed: f64,
) -> Result<Away, Option<f64>> {
    if screen_locked == Some(true) {
        return Ok(Away::ScreenLocked);
    }
    let Some(idle) = input_idle_seconds.filter(|s| s.is_finite() && *s >= 0.0) else {
        return Err(None);
    };
    if idle >= needed { Ok(Away::Idle { seconds: idle }) } else { Err(Some(needed - idle)) }
}

/// When the updater checks next, in seconds from now: the last check plus the
/// interval, now (0) when that has passed or there was no check yet. None
/// when the interval is not a positive number (automatic checks are off).
pub fn next_check_in(seconds_since_last_check: Option<f64>, interval_seconds: f64) -> Option<f64> {
    if !interval_seconds.is_finite() || interval_seconds <= 0.0 {
        return None;
    }
    let since = seconds_since_last_check.filter(|s| s.is_finite() && *s >= 0.0);
    Some(since.map_or(0.0, |since| (interval_seconds - since).max(0.0)))
}

/// The idle time the setting asks for, in seconds.
pub fn idle_seconds(idle_minutes: f64) -> f64 {
    let minutes = if idle_minutes.is_finite() {
        idle_minutes.max(MIN_IDLE_MINUTES)
    } else {
        MIN_IDLE_MINUTES
    };
    minutes * 60.0
}

/// Whether the staged update installs now.
pub fn decide(facts: &IdleFacts) -> Decision {
    if !facts.enabled {
        return Decision::hold(Hold::Off);
    }
    let away =
        match away(facts.input_idle_seconds, facts.screen_locked, idle_seconds(facts.idle_minutes))
        {
            Ok(away) => away,
            Err(None) => return Decision::hold(Hold::Unknown),
            Err(Some(seconds_left)) => return Decision::hold(Hold::NotIdle { seconds_left }),
        };
    if facts.declined_installs > 0 {
        let wait = retry_after_seconds(facts.declined_installs);
        // A decline with no time read is as recent as can be: wait the whole backoff.
        let since =
            facts.seconds_since_decline.filter(|s| s.is_finite() && *s >= 0.0).unwrap_or(0.0);
        if since < wait {
            return Decision::hold(Hold::Backoff { seconds_left: wait - since });
        }
    }
    match facts.unsent_drafts {
        None => Decision::hold(Hold::Unknown),
        Some(drafts) if drafts > 0 => Decision::hold(Hold::UnsentDraft),
        Some(_) => Decision { install: true, hold: None, away: Some(away) },
    }
}

#[cfg(test)]
#[path = "update_idle_tests.rs"]
mod tests;
