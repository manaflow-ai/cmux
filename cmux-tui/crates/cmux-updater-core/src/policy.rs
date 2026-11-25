//! The updater's small policies, moved from CmuxNextUpdater: when a pushed build downloads
//! (`DeltaWaitPolicy`), whether found updates download on this link (`UpdateNetworkPolicy`),
//! whether a closed update card stays hidden (`UpdateSnooze`), each track's defaults
//! (`UpdateTrack`) and a download's time left (`UpdateTransferRate`).

use serde::{Deserialize, Serialize};

/// Seconds a pushed build's automatic download waits for its `sparkle:deltas` (RFD 0166 U1).
pub const DELTA_WAIT_WINDOW_SECONDS: f64 = 300.0;
/// Seconds between feed reads while waiting.
pub const DELTA_WAIT_RECHECK_SECONDS: f64 = 30.0;

/// Whether a pushed build downloads now (true) or waits for its deltas. A click never waits.
pub fn delta_download_now(lists_deltas: bool, user_asked: bool, waited: f64) -> bool {
    user_asked || lists_deltas || waited >= DELTA_WAIT_WINDOW_SECONDS
}

/// `updates.meteredNetwork`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MeteredMode {
    #[serde(rename = "defer-low-data")]
    DeferLowData,
    #[serde(rename = "defer-expensive")]
    DeferExpensive,
    #[serde(rename = "download")]
    Download,
}

/// Whether found updates download by themselves right now.
pub fn downloads_automatically(
    setting: bool,
    mode: MeteredMode,
    constrained: bool,
    expensive: bool,
) -> bool {
    if !setting {
        return false;
    }
    match mode {
        MeteredMode::Download => true,
        MeteredMode::DeferLowData => !constrained,
        MeteredMode::DeferExpensive => !constrained && !expensive,
    }
}

/// What the update cards' x remembers (UPDATE-CARD-CLOSE). Times are seconds since 1970.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snooze {
    /// The version whose card was closed ("" when the update named none).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub closed_version: Option<String>,
    /// No card before this moment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remind_after: Option<f64>,
}

impl Snooze {
    /// Whether the card for `version` stays hidden at `now`.
    pub fn hides(&self, version: Option<&str>, now: f64) -> bool {
        if self.remind_after.is_some_and(|after| now < after) {
            return true;
        }
        self.closed_version.as_deref().is_some_and(|closed| closed == version.unwrap_or(""))
    }

    /// The same state without a reminder that ended at `now`.
    pub fn expired(&self, now: f64) -> Self {
        match self.remind_after {
            Some(after) if now >= after => {
                Self { closed_version: self.closed_version.clone(), remind_after: None }
            }
            _ => self.clone(),
        }
    }
}

/// The release line a build belongs to (`UpdateTrack`); its raw value is `updates.status`'s
/// `track`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Track {
    #[serde(rename = "stable")]
    Stable,
    #[serde(rename = "nightly")]
    Nightly,
    #[serde(rename = "rc")]
    Rc,
    #[serde(rename = "development")]
    Development,
    #[serde(rename = "nightly-next")]
    NightlyNext,
}

/// A track's defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackDefaults {
    /// A test appcast may replace the baked feed: DEV and both nightly rings.
    pub allows_test_feed: bool,
    /// `updates.downloadAutomatically` when never set (Leo 2026-11-07: on everywhere).
    pub downloads_automatically: bool,
    /// `updates.installWhenIdle` when never set: cmux NEXT's NIGHTLY only (Leo 2026-11-22).
    pub installs_when_idle: bool,
}

impl Track {
    pub fn defaults(self) -> TrackDefaults {
        TrackDefaults {
            allows_test_feed: matches!(self, Self::Nightly | Self::NightlyNext | Self::Development),
            downloads_automatically: true,
            installs_when_idle: self == Self::NightlyNext,
        }
    }
}

/// One byte count and when it arrived (seconds).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Sample {
    pub bytes: u64,
    pub at: f64,
}

/// Seconds the speed looks back.
pub const TRANSFER_WINDOW_SECONDS: f64 = 5.0;
/// The span of samples the first estimate waits for.
pub const TRANSFER_SETTLE_SECONDS: f64 = 1.0;

/// The samples after taking `bytes` at `now` (`UpdateTransferRate.record`): `None` (another phase)
/// or a count that went back starts over.
pub fn record(samples: &[Sample], bytes: Option<u64>, now: f64) -> Vec<Sample> {
    let Some(bytes) = bytes else { return Vec::new() };
    let mut next: Vec<Sample> = match samples.last() {
        Some(last) if bytes < last.bytes => Vec::new(),
        Some(last) if last.bytes == bytes => return samples.to_vec(),
        _ => samples.to_vec(),
    };
    next.push(Sample { bytes, at: now });
    next.retain(|sample| now - sample.at <= TRANSFER_WINDOW_SECONDS);
    next
}

/// Bytes per second over the window, once it spans the settle time.
pub fn bytes_per_second(samples: &[Sample]) -> Option<f64> {
    let (first, last) = (samples.first()?, samples.last()?);
    let span = last.at - first.at;
    if span < TRANSFER_SETTLE_SECONDS || last.bytes <= first.bytes {
        return None;
    }
    Some((last.bytes - first.bytes) as f64 / span)
}

/// Seconds until `expected` bytes are in, rounded up to 5 s under a minute and whole minutes above.
pub fn seconds_left(samples: &[Sample], expected: Option<u64>) -> Option<i64> {
    let rate = bytes_per_second(samples).filter(|rate| *rate > 0.0)?;
    let (expected, last) = (expected?, samples.last()?);
    if expected <= last.bytes {
        return None;
    }
    let seconds = (expected - last.bytes) as f64 / rate;
    let step = if seconds < 60.0 { 5.0 } else { 60.0 };
    let rounded = (seconds / step).ceil() * step;
    // 2^63 is one past i64::MAX: only values below it convert.
    (rounded < 9_223_372_036_854_775_808.0).then_some(rounded as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deltas_wait_only_for_automatic_downloads() {
        assert!(!delta_download_now(false, false, 299.0));
        assert!(delta_download_now(false, false, 300.0));
        assert!(delta_download_now(true, false, 0.0));
        assert!(delta_download_now(false, true, 0.0));
    }

    #[test]
    fn metered_modes() {
        assert!(!downloads_automatically(false, MeteredMode::Download, false, false));
        assert!(downloads_automatically(true, MeteredMode::Download, true, true));
        assert!(!downloads_automatically(true, MeteredMode::DeferLowData, true, false));
        assert!(downloads_automatically(true, MeteredMode::DeferLowData, false, true));
        assert!(!downloads_automatically(true, MeteredMode::DeferExpensive, false, true));
        assert!(downloads_automatically(true, MeteredMode::DeferExpensive, false, false));
    }

    #[test]
    fn snooze_hides_the_closed_version_and_until_the_reminder() {
        let closed = Snooze { closed_version: Some("1204".into()), remind_after: None };
        assert!(closed.hides(Some("1204"), 0.0));
        assert!(!closed.hides(Some("1205"), 0.0));
        let unnamed = Snooze { closed_version: Some(String::new()), remind_after: None };
        assert!(unnamed.hides(None, 0.0));
        let remind = Snooze { closed_version: None, remind_after: Some(100.0) };
        assert!(remind.hides(Some("9"), 99.0));
        assert!(!remind.hides(Some("9"), 100.0));
        assert_eq!(remind.expired(99.0), remind);
        assert_eq!(remind.expired(100.0), Snooze::default());
    }

    #[test]
    fn track_defaults() {
        assert!(!Track::Stable.defaults().allows_test_feed);
        assert!(!Track::Rc.defaults().allows_test_feed);
        assert!(Track::Development.defaults().allows_test_feed);
        assert!(Track::NightlyNext.defaults().installs_when_idle);
        assert!(!Track::Nightly.defaults().installs_when_idle);
        assert!(Track::Stable.defaults().downloads_automatically);
    }

    #[test]
    fn transfer_rate_settles_then_rounds() {
        let mut samples = record(&[], Some(0), 0.0);
        assert_eq!(bytes_per_second(&samples), None);
        samples = record(&samples, Some(0), 0.5);
        assert_eq!(samples.len(), 1);
        samples = record(&samples, Some(1000), 1.0);
        assert_eq!(bytes_per_second(&samples), Some(1000.0));
        assert_eq!(seconds_left(&samples, Some(13_000)), Some(15));
        assert_eq!(seconds_left(&samples, Some(100_000)), Some(120));
        assert_eq!(seconds_left(&samples, Some(1000)), None);
        assert!(record(&samples, Some(10), 2.0).len() == 1);
        assert!(record(&samples, None, 2.0).is_empty());
        let late = record(&samples, Some(2000), 5.5);
        assert_eq!(late.first().map(|s| s.at), Some(1.0));
        assert_eq!(
            seconds_left(
                &[Sample { bytes: 0, at: 0.0 }, Sample { bytes: 1, at: 1.0 }],
                Some(u64::MAX)
            ),
            None
        );
    }
}
