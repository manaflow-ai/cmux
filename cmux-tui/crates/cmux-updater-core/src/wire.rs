//! The JSON operations of the update rules, for the app FFI's JSON channel
//! (`cmux_layout_reducer_json`; the move PR links this crate into
//! cmux-app-ffi and sends these from the Swift updater). The updater is not
//! a hot path: each call is once per check, click or settings read. Requests
//! and responses are camelCase JSON objects; `updater_pulled_decode` takes
//! the raw `pulled.json` body as its request.

use crate::appcast::{self, AppcastItem};
use crate::channel_track::{self, TracksRequest};
use crate::install_check;
use crate::pulled;
use crate::ring_return;
use crate::rollback::{self, KeptCandidate};
use crate::select;
use crate::track::{self, BuildFacts, InfoStrings};
use crate::version::{self, SystemVersion};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

/// The request was not the JSON the operation reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WireError;

fn read<T: DeserializeOwned>(request: &[u8]) -> Result<T, WireError> {
    serde_json::from_slice(request).map_err(|_| WireError)
}

fn write<T: Serialize>(value: &T) -> Result<Vec<u8>, WireError> {
    serde_json::to_vec(value).map_err(|_| WireError)
}

#[derive(Serialize)]
struct Order<T> {
    order: T,
}

#[derive(Serialize)]
#[serde(untagged)]
enum ParseAnswer {
    Items { items: Vec<AppcastItem> },
    Error { error: String },
}

#[derive(Serialize)]
struct Tracks {
    tracks: Vec<channel_track::ChannelTrack>,
}

#[derive(Serialize)]
#[serde(untagged)]
enum RollbackAnswer {
    Target { target: usize },
    Refusal { refusal: rollback::Refusal },
}

#[derive(Serialize)]
struct Builds {
    builds: Vec<pulled::PulledBuild>,
}

#[derive(Serialize)]
struct InstallAnswer {
    outcome: Option<install_check::InstallOutcome>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CompareRequest {
    lhs: String,
    rhs: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuildsRequest {
    builds: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParseRequest {
    xml: String,
    /// The `sparkle:channel` tags the updater allows; none keeps every item.
    #[serde(default)]
    allowed_channels: Option<BTreeSet<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SelectRequest {
    items: Vec<AppcastItem>,
    current_build: String,
    system: SystemVersion,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RingReturnRequest {
    installed_build: String,
    #[serde(default)]
    offered: Vec<String>,
    #[serde(default)]
    promoted: BTreeSet<String>,
    #[serde(default)]
    pulled: BTreeSet<String>,
    #[serde(default)]
    kept: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RollbackRequest {
    kept: Vec<KeptCandidate>,
    #[serde(default)]
    build: Option<String>,
    #[serde(default)]
    stored: Option<BTreeMap<String, i64>>,
    #[serde(default)]
    team_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallCheckRequest {
    from_build: String,
    target_build: String,
    recorded_at: f64,
    running_build: String,
    now: f64,
}

fn order_name(order: Ordering) -> i8 {
    match order {
        Ordering::Less => -1,
        Ordering::Equal => 0,
        Ordering::Greater => 1,
    }
}

/// The answer to `operation`, or none when this crate has no such operation.
///
/// - `updater_version_compare` `{lhs, rhs}` -> `{order: -1|0|1}`: Sparkle's order.
/// - `updater_builds_newest_first` `{builds}` -> `{order: [index]}`: numeric build order.
/// - `updater_appcast_parse` `{xml, allowedChannels?}` -> `{items}` or `{error}`.
/// - `updater_appcast_select` `{items, currentBuild, system}` -> the outcome (`kind`, indices).
/// - `updater_ring_return` `{installedBuild, offered, promoted, pulled, kept}` -> `{way, kept?}`.
/// - `updater_channel_tracks` [`TracksRequest`] -> `{tracks}`.
/// - `updater_rollback_decide` `{kept, build?, stored?, teamId?}` -> `{target}` or `{refusal}`.
/// - `updater_pulled_decode` (the raw body) -> `{builds}`.
/// - `updater_build_info` [`InfoStrings`] -> [`track::BuildInfo`].
/// - `updater_build_rules` [`BuildFacts`] -> [`track::BuildRules`].
/// - `updater_install_check` `{fromBuild, targetBuild, recordedAt, runningBuild, now}` -> `{outcome}`.
pub fn respond(operation: &[u8], request: &[u8]) -> Option<Result<Vec<u8>, WireError>> {
    Some(match operation {
        b"updater_version_compare" => read::<CompareRequest>(request).and_then(|r| {
            write(&Order { order: order_name(version::compare_sparkle(&r.lhs, &r.rhs)) })
        }),
        b"updater_builds_newest_first" => read::<BuildsRequest>(request)
            .and_then(|r| write(&Order { order: version::newest_first(&r.builds) })),
        b"updater_appcast_parse" => read::<ParseRequest>(request).and_then(|r| {
            write(&match appcast::parse(r.xml.as_bytes()) {
                Ok(items) => ParseAnswer::Items {
                    items: appcast::offered(items, r.allowed_channels.as_ref()),
                },
                Err(error) => ParseAnswer::Error { error: error.message },
            })
        }),
        b"updater_appcast_select" => read::<SelectRequest>(request)
            .and_then(|r| write(&select::select(&r.items, &r.current_build, r.system))),
        b"updater_ring_return" => read::<RingReturnRequest>(request).and_then(|r| {
            write(&ring_return::decide(
                &r.installed_build,
                &r.offered,
                &r.promoted,
                &r.pulled,
                &r.kept,
            ))
        }),
        b"updater_channel_tracks" => read::<TracksRequest>(request)
            .and_then(|r| write(&Tracks { tracks: channel_track::tracks(&r) })),
        b"updater_rollback_decide" => read::<RollbackRequest>(request).and_then(|r| {
            write(&match rollback::decide(
                &r.kept,
                r.build.as_deref(),
                r.stored.as_ref(),
                r.team_id.as_deref(),
            ) {
                Ok(target) => RollbackAnswer::Target { target },
                Err(refusal) => RollbackAnswer::Refusal { refusal },
            })
        }),
        b"updater_pulled_decode" => write(&Builds { builds: pulled::decode(request) }),
        b"updater_build_info" => {
            read::<InfoStrings>(request).and_then(|r| write(&track::build_info(&r)))
        }
        b"updater_build_rules" => {
            read::<BuildFacts>(request).and_then(|r| write(&track::build_rules(&r)))
        }
        b"updater_install_check" => read::<InstallCheckRequest>(request).and_then(|r| {
            write(&InstallAnswer {
                outcome: install_check::outcome(
                    &r.from_build,
                    &r.target_build,
                    r.recorded_at,
                    &r.running_build,
                    r.now,
                ),
            })
        }),
        _ => return None,
    })
}
