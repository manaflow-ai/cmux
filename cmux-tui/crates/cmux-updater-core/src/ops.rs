//! The JSON requests the app sends over the app FFI's JSON channel (`cmux_layout_reducer_json`,
//! ops `updater_*`), with their replies. Field names are camelCase, as Swift's `JSONEncoder`
//! writes them.

use serde::{Deserialize, Serialize};

use std::collections::BTreeMap;

use crate::appcast::{self, AppcastItem};
use crate::channels;
use crate::feed::{self, Architecture, Channel, Resolution, Ring};
use crate::install::{self, Action, Attempt, Phase};
use crate::numeric;
use crate::policy::{self, MeteredMode, Sample, Snooze, Track, TrackDefaults};
use crate::relaunch::{Blockers, Waits};
use crate::rollback::{self, Kept, Refusal, RingReturn};
use crate::select::{self, Candidate, Outcome};
use crate::system_version::SystemVersion;
use crate::version;

/// `updater_version_compare`: Sparkle's order of each pair.
#[derive(Debug, Deserialize)]
pub struct CompareRequest {
    pub pairs: Vec<(String, String)>,
}

/// -1, 0 or 1 per pair: the first older, equal, or newer.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct CompareReply {
    pub orders: Vec<i8>,
}

pub fn compare(request: &CompareRequest) -> CompareReply {
    CompareReply {
        orders: request.pairs.iter().map(|(a, b)| version::compare(a, b) as i8).collect(),
    }
}

/// `updater_appcast_parse`: the feed's text (the app refuses bytes that are not UTF-8 itself).
#[derive(Debug, Deserialize)]
pub struct ParseRequest {
    pub xml: String,
}

/// The items, or why the feed is not readable.
#[derive(Debug, Serialize, PartialEq)]
pub struct ParseReply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub items: Option<Vec<AppcastItem>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub fn parse(request: &ParseRequest) -> ParseReply {
    match appcast::parse(&request.xml) {
        Ok(items) => ParseReply { items: Some(items), error: None },
        Err(error) => ParseReply { items: None, error: Some(error.0) },
    }
}

/// `updater_appcast_select`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectRequest {
    pub items: Vec<Candidate>,
    pub current_build: String,
    pub system: SystemVersion,
}

pub fn select(request: &SelectRequest) -> Outcome {
    select::select(&request.items, &request.current_build, request.system)
}

/// `updater_system_version`: parses each text (`sparkle:minimumSystemVersion`,
/// `LSMinimumSystemVersion`), null where it is not a macOS version.
#[derive(Debug, Deserialize)]
pub struct SystemVersionRequest {
    pub texts: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct SystemVersionReply {
    pub versions: Vec<Option<SystemVersion>>,
}

pub fn system_versions(request: &SystemVersionRequest) -> SystemVersionReply {
    SystemVersionReply {
        versions: request.texts.iter().map(|text| SystemVersion::parse(text)).collect(),
    }
}

/// `updater_numeric_compare`: the numeric order (kept builds, channel tracks) of each pair.
pub fn numeric_compare(request: &CompareRequest) -> CompareReply {
    CompareReply {
        orders: request.pairs.iter().map(|(a, b)| numeric::compare(a, b) as i8).collect(),
    }
}

/// `updater_rollback`: the target of a rollback, or why it does not run.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RollbackRequest {
    pub kept: Vec<Kept>,
    #[serde(default)]
    pub build: Option<String>,
    #[serde(default)]
    pub running: Option<String>,
    #[serde(default)]
    pub stored: BTreeMap<String, i64>,
    #[serde(default)]
    pub team_id: Option<String>,
    /// Only the previous build of `running` (`RollbackDecision.previous`), no checks.
    #[serde(default)]
    pub previous_only: bool,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct RollbackReply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
}

pub fn rollback(request: &RollbackRequest) -> RollbackReply {
    if request.previous_only {
        let target = request
            .running
            .as_deref()
            .and_then(|running| rollback::previous(&request.kept, running));
        return RollbackReply { target, refusal: None };
    }
    match rollback::decide(
        &request.kept,
        request.build.as_deref(),
        request.running.as_deref(),
        &request.stored,
        request.team_id.as_deref(),
    ) {
        Ok(target) => RollbackReply { target: Some(target), refusal: None },
        Err(refusal) => RollbackReply { target: None, refusal: Some(refusal) },
    }
}

/// `updater_ring_return`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RingReturnRequest {
    pub installed_build: String,
    pub offered: Vec<String>,
    #[serde(default)]
    pub promoted: Vec<String>,
    #[serde(default)]
    pub pulled: Vec<String>,
    /// Kept builds, newest first.
    #[serde(default)]
    pub kept: Vec<String>,
}

pub fn ring_return(request: &RingReturnRequest) -> RingReturn {
    rollback::ring_return(
        &request.installed_build,
        &request.offered,
        &request.promoted,
        &request.pulled,
        &request.kept,
    )
}

/// `updater_feed_resolve`: the feed for `SUFeedURL`, what it accepts on `ring`, and where a
/// failed update downloads by hand.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedRequest {
    #[serde(default, rename = "infoFeedURL")]
    pub info_feed_url: Option<String>,
    pub architecture: Architecture,
    #[serde(default)]
    pub ring: Option<Ring>,
    #[serde(default)]
    pub bundle_identifier: Option<String>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FeedReply {
    #[serde(flatten)]
    pub resolution: Resolution,
    pub allowed_sparkle_channels: Vec<&'static str>,
    #[serde(rename = "manualDownloadURL")]
    pub manual_download_url: String,
    pub dev_like: bool,
}

pub fn feed_resolve(request: &FeedRequest) -> FeedReply {
    let resolution = feed::resolve(request.info_feed_url.as_deref(), request.architecture);
    // Recovery classifies the raw `SUFeedURL`, as `UpdateManualDownloadRecovery` did.
    let recovery = Channel::classify(request.info_feed_url.as_deref().unwrap_or_default());
    FeedReply {
        allowed_sparkle_channels: resolution
            .channel
            .allowed_sparkle_channels(request.ring.unwrap_or(Ring::Nightly)),
        manual_download_url: recovery.manual_download_url(request.architecture),
        dev_like: feed::is_dev_like_bundle_identifier(request.bundle_identifier.as_deref()),
        resolution,
    }
}

/// `updater_install_attempt`: one step of an accepted install. `event` is `request` (the user
/// asked to install, `phase` is the phase showing), `freshCheckStarted`, or `phase` (a change).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttemptRequest {
    #[serde(default)]
    pub attempt: Attempt,
    pub event: AttemptEvent,
    #[serde(default)]
    pub phase: Option<Phase>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttemptEvent {
    Request,
    FreshCheckStarted,
    Phase,
    Cancel,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AttemptReply {
    pub attempt: Attempt,
    pub action: Action,
    pub monitoring: bool,
    /// The watchdog disarms: the step ended the attempt without an install, or `phase` resolves it.
    pub disarm: bool,
    /// Were the watchdog to fire now, `phase` would be a stall.
    pub stalled: bool,
}

pub fn install_attempt(request: &AttemptRequest) -> Option<AttemptReply> {
    let (attempt, action) = match request.event {
        AttemptEvent::Request => request.attempt.request_install_latest(request.phase?),
        AttemptEvent::FreshCheckStarted => (request.attempt.did_start_fresh_check(), Action::None),
        AttemptEvent::Phase => request.attempt.handle(request.phase?),
        AttemptEvent::Cancel => (Attempt::Inactive, Action::None),
    };
    let monitoring = attempt.is_monitoring();
    let disarm = (request.event == AttemptEvent::Phase
        && install::ended_without_install(action, monitoring))
        || request.phase.is_some_and(install::resolved);
    Some(AttemptReply {
        attempt,
        action,
        monitoring,
        disarm,
        stalled: request.phase.is_some_and(install::stalled),
    })
}

/// `updater_relaunch_permits`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelaunchRequest {
    #[serde(default)]
    pub blockers: Blockers,
    pub automatic: bool,
    pub waits: Waits,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RelaunchReply {
    pub permits: bool,
    pub empty: bool,
}

pub fn relaunch_permits(request: &RelaunchRequest) -> RelaunchReply {
    RelaunchReply {
        permits: request.blockers.permits_relaunch(request.automatic, &request.waits),
        empty: request.blockers.is_empty(),
    }
}

/// `updater_policy`: the small policies, each asked only when its fields are present.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PolicyRequest {
    #[serde(default)]
    pub delta: Option<DeltaQuery>,
    #[serde(default)]
    pub network: Option<NetworkQuery>,
    #[serde(default)]
    pub snooze: Option<SnoozeQuery>,
    #[serde(default)]
    pub track: Option<Track>,
    #[serde(default)]
    pub transfer: Option<TransferQuery>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeltaQuery {
    pub lists_deltas: bool,
    pub user_asked: bool,
    pub waited: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkQuery {
    pub setting: bool,
    pub mode: MeteredMode,
    pub constrained: bool,
    pub expensive: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnoozeQuery {
    #[serde(default)]
    pub snooze: Snooze,
    #[serde(default)]
    pub version: Option<String>,
    pub now: f64,
}

/// `bytes` null: the phase is not a byte-counted download.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferQuery {
    #[serde(default)]
    pub samples: Vec<Sample>,
    #[serde(default)]
    pub bytes: Option<u64>,
    pub now: f64,
    #[serde(default)]
    pub expected: Option<u64>,
}

#[derive(Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PolicyReply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delta_download_now: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub downloads_automatically: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snooze: Option<SnoozeReply>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub track: Option<TrackDefaults>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transfer: Option<TransferReply>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SnoozeReply {
    pub hides: bool,
    pub expired: Snooze,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TransferReply {
    pub samples: Vec<Sample>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_per_second: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seconds_left: Option<i64>,
}

pub fn policy(request: &PolicyRequest) -> PolicyReply {
    PolicyReply {
        delta_download_now: request
            .delta
            .as_ref()
            .map(|q| policy::delta_download_now(q.lists_deltas, q.user_asked, q.waited)),
        downloads_automatically: request.network.as_ref().map(|q| {
            policy::downloads_automatically(q.setting, q.mode, q.constrained, q.expensive)
        }),
        snooze: request.snooze.as_ref().map(|q| SnoozeReply {
            hides: q.snooze.hides(q.version.as_deref(), q.now),
            expired: q.snooze.expired(q.now),
        }),
        track: request.track.map(Track::defaults),
        transfer: request.transfer.as_ref().map(|q| {
            let samples = policy::record(&q.samples, q.bytes, q.now);
            TransferReply {
                bytes_per_second: policy::bytes_per_second(&samples),
                seconds_left: policy::seconds_left(&samples, q.expected),
                samples,
            }
        }),
    }
}

/// `updater_channel_tracks`.
pub fn channel_tracks(request: &channels::Request) -> Vec<channels::Track> {
    channels::tracks(request)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn compare_answers_each_pair() {
        let request: CompareRequest = serde_json::from_value(
            json!({"pairs": [["1203", "1204"], ["1.0", "1.0.0"], ["2", "1"]]}),
        )
        .unwrap();
        assert_eq!(compare(&request), CompareReply { orders: vec![-1, 0, 1] });
    }

    #[test]
    fn parse_answers_items_or_an_error() {
        let reply = parse(&ParseRequest { xml: "<rss/>".into() });
        assert_eq!(
            serde_json::to_value(reply).unwrap(),
            json!({"error": "appcast has no <channel>"})
        );
        let reply = parse(&ParseRequest {
            xml: "<rss><channel><item><sparkle:version>7</sparkle:version></item></channel></rss>"
                .into(),
        });
        assert_eq!(
            serde_json::to_value(reply).unwrap(),
            json!({"items": [{"version": "7", "listsDeltas": false}]})
        );
    }

    #[test]
    fn select_reads_the_app_request() {
        let request: SelectRequest = serde_json::from_value(json!({
            "items": [{"version": "5", "minimumSystemVersion": {"major": 27, "minor": 0, "patch": 0}}, {"version": "4"}],
            "currentBuild": "3",
            "system": {"major": 26, "minor": 1, "patch": 0},
        }))
        .unwrap();
        assert_eq!(select(&request), Outcome::UpdateAvailable { item: 1 });
    }

    #[test]
    fn rollback_answers_a_target_or_a_refusal() {
        let request: RollbackRequest = serde_json::from_value(json!({
            "kept": [{"build": "1205", "storeSchemas": {"tabs": 3}, "teamId": "T", "keptAt": 2.0},
                     {"build": "1200", "storeSchemas": {"tabs": 3}, "teamId": "T", "keptAt": 1.0}],
            "running": "1210", "stored": {"tabs": 4}, "teamId": "T",
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(rollback(&request)).unwrap(),
            json!({"refusal": {"kind": "storeTooNew", "store": "tabs", "stored": 4, "readable": 3, "kept": 0}})
        );
        let request: RollbackRequest = serde_json::from_value(json!({
            "kept": [{"build": "1205", "keptAt": 1.0}, {"build": "1200", "keptAt": 2.0}],
            "running": "1210", "previousOnly": true,
        }))
        .unwrap();
        assert_eq!(serde_json::to_value(rollback(&request)).unwrap(), json!({"target": 1}));
    }

    #[test]
    fn ring_return_reads_the_app_request() {
        let request: RingReturnRequest = serde_json::from_value(json!({
            "installedBuild": "1210", "offered": ["1200"], "promoted": ["1205"], "kept": ["1205"],
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(ring_return(&request)).unwrap(),
            json!({"kind": "goBack", "kept": 0})
        );
    }

    #[test]
    fn numeric_compare_answers_each_pair() {
        let request: CompareRequest = serde_json::from_value(
            json!({"pairs": [["999", "1204"], ["1.10", "1.9"], ["7", "7"]]}),
        )
        .unwrap();
        assert_eq!(numeric_compare(&request), CompareReply { orders: vec![-1, 1, 0] });
    }

    #[test]
    fn system_versions_parse_each_text() {
        let reply = system_versions(&SystemVersionRequest { texts: vec!["26".into(), "x".into()] });
        assert_eq!(reply.versions, vec![Some(SystemVersion::new(26, 0, 0)), None]);
    }

    #[test]
    fn feed_resolve_answers_feed_ring_and_recovery() {
        let request: FeedRequest = serde_json::from_value(json!({
            "infoFeedURL": "https://x/nightly-next/appcast.xml",
            "architecture": "arm64", "ring": "canary", "bundleIdentifier": "com.cmuxterm.app.debug.t",
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(feed_resolve(&request)).unwrap(),
            json!({
                "url": "https://x/nightly-next/appcast-arm64.xml", "channel": "nightlyNext",
                "usedFallback": false,
                "allowedSparkleChannels": ["cmux-next-stable", "cmux-next", "cmux-next-canary"],
                "manualDownloadURL": "https://cmux.com/api/download/next", "devLike": true,
            })
        );
    }

    #[test]
    fn install_attempt_steps_and_tells_the_watchdog() {
        let request: AttemptRequest =
            serde_json::from_value(json!({"event": "request", "phase": "updateAvailable"}))
                .unwrap();
        assert_eq!(
            serde_json::to_value(install_attempt(&request)).unwrap(),
            json!({"attempt": "awaitingFreshCheck", "action": "startFreshCheck", "monitoring": true,
                   "disarm": false, "stalled": true})
        );
        let request: AttemptRequest = serde_json::from_value(
            json!({"attempt": "awaitingResult", "event": "phase", "phase": "idle"}),
        )
        .unwrap();
        assert_eq!(
            serde_json::to_value(install_attempt(&request)).unwrap(),
            json!({"attempt": "inactive", "action": "installFailed", "monitoring": false,
                   "disarm": true, "stalled": true})
        );
        let request: AttemptRequest = serde_json::from_value(json!({"event": "phase"})).unwrap();
        assert_eq!(install_attempt(&request), None);
    }

    #[test]
    fn relaunch_permits_reads_the_gate() {
        let request: RelaunchRequest = serde_json::from_value(json!({
            "blockers": {"busyAgentCount": 1}, "automatic": false,
            "waits": {"waited": 5, "daemonUnavailableFor": 0, "agentTimeout": 5,
                      "daemonUnavailableTimeout": 30, "automaticWaitCap": 600},
        }))
        .unwrap();
        assert_eq!(relaunch_permits(&request), RelaunchReply { permits: true, empty: false });
    }

    #[test]
    fn policy_answers_only_what_was_asked() {
        let request: PolicyRequest = serde_json::from_value(json!({
            "delta": {"listsDeltas": false, "userAsked": false, "waited": 10},
            "network": {"setting": true, "mode": "defer-expensive", "constrained": false, "expensive": true},
            "snooze": {"snooze": {"remindAfter": 50.0}, "version": "9", "now": 60.0},
            "track": "nightly-next",
            "transfer": {"samples": [{"bytes": 0, "at": 0.0}], "bytes": 1000, "now": 1.0, "expected": 13000},
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(policy(&request)).unwrap(),
            json!({
                "deltaDownloadNow": false,
                "downloadsAutomatically": false,
                "snooze": {"hides": false, "expired": {}},
                "track": {"allowsTestFeed": true, "downloadsAutomatically": true, "installsWhenIdle": true},
                "transfer": {"samples": [{"bytes": 0, "at": 0.0}, {"bytes": 1000, "at": 1.0}],
                             "bytesPerSecond": 1000.0, "secondsLeft": 15},
            })
        );
        assert_eq!(serde_json::to_value(policy(&PolicyRequest::default())).unwrap(), json!({}));
    }
}
