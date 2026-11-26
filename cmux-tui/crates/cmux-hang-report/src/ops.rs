//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `hang_report_*`). Every op is pure: the app passes what it read
//! (files, dyld, sysctl, the clock as Unix seconds) and does what the reply says.
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `hang_report_stack_refs` | `{trees}` (MetricKit tree JSON texts) | `{uuids, names}`: uuids to find among loaded images, bare names to look for in Apple's folders |
//! | `hang_report_compose` | [`Compose`] | [`Composed`]: `{status, body?, readable?, findings}` |
//! | `hang_report_preview` | [`Compose`] | `{readable}` (null unless it scans clean) |
//! | `hang_report_frames` | `{addresses: [{address, image?}], appBundlePath?, forbiddenTerms}` | `{frames}` |
//! | `hang_report_scan` | `{body, forbiddenTerms}` | `{findings}` |
//! | `hang_report_sendable` | `{body, app, forbiddenTerms}` | `{sendable}` |
//! | `hang_report_note_stall` | `{durationNanos, cpuNanos, hasAddresses, stallCount, lastStallMs?}` | `{bucket?, sample?}` |
//! | `hang_report_note_hang` | `{durationNanos, hasAddresses, hangCount, lastHangMs?}` | `{sample?}` |
//! | `hang_report_keep` | `{aggregate, sample}` | `{aggregate}` |
//! | `hang_report_merge` | `{aggregate, other}` | `{aggregate}` |
//! | `hang_report_aggregate` | `{aggregate}` | `{isEmpty, histogram}` |
//! | `hang_report_send_slot` | `{log, now}` | `{log}` (null: today's sends are used up) |
//! | `hang_report_launch_due` | `{lastSentAt?, now, watchdogEmpty}` | `{due}` |
//! | `hang_report_day` | `{now}` | `{day}` |
//! | `hang_report_outbox_plan` | `{entries: [{name, modified?}], now}` | `{expired, ordered, trim}` |
//! | `hang_report_install_id` | `{id?, created?, now}` | `{keep}` |
//! | `hang_report_ask` | `{settingOn, consented, invited, telemetryOptIn}` | `{decision}` |
//! | `hang_report_hardware` | `{rawArch?, rawChip?, cores, memoryBytes}` | the hardware class |
//! | `hang_report_counts` | `{windows, workspaces, panes, tabs}` | the coarse counts |

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::aggregate::{self, StallAggregate};
use crate::build::{Address, Builder, Context, MetricKitInput, address_frames, hardware};
use crate::classify::{Classifier, LoadedImage};
use crate::report::{App, CoarseCounts, HangSample};
use crate::scan::Scanner;
use crate::service::{self, OutboxEntry, SendLog};
use crate::tree;

pub const PREFIX: &str = "hang_report_";

#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    UnknownOp(String),
    Invalid(String),
}

pub fn serves(operation: &str) -> bool {
    operation.starts_with(PREFIX)
}

/// One report's inputs.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Compose {
    pub context: Context,
    #[serde(default)]
    pub watchdog: Option<StallAggregate>,
    #[serde(default)]
    pub metric_kit: Vec<MetricKitInput>,
    #[serde(default)]
    pub app_bundle_path: Option<String>,
    #[serde(default)]
    pub forbidden_terms: Vec<String>,
    /// Bare image names the app found in an Apple folder.
    #[serde(default)]
    pub system_images: Vec<String>,
    /// The loaded images the app found for `hang_report_stack_refs`'s uuids.
    #[serde(default)]
    pub loaded_images: Vec<LoadedImage>,
}

impl Compose {
    fn parts(self) -> (Builder, Scanner, Context, StallAggregate, Vec<MetricKitInput>) {
        let classifier = Classifier::new(
            self.app_bundle_path.as_deref(),
            &self.forbidden_terms,
            self.system_images,
        );
        (
            Builder::new(classifier, self.loaded_images),
            Scanner::new(&self.forbidden_terms),
            self.context,
            self.watchdog.unwrap_or_default(),
            self.metric_kit,
        )
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Trees {
    trees: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Frames {
    addresses: Vec<Address>,
    #[serde(default)]
    app_bundle_path: Option<String>,
    #[serde(default)]
    forbidden_terms: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Body {
    body: String,
    #[serde(default)]
    app: Option<App>,
    #[serde(default)]
    forbidden_terms: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoteStall {
    duration_nanos: u64,
    #[serde(default)]
    cpu_nanos: u64,
    has_addresses: bool,
    #[serde(default)]
    stall_count: usize,
    #[serde(default)]
    last_stall_ms: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoteHang {
    duration_nanos: u64,
    has_addresses: bool,
    #[serde(default)]
    hang_count: usize,
    #[serde(default)]
    last_hang_ms: Option<i64>,
}

#[derive(Deserialize)]
struct Keep {
    aggregate: StallAggregate,
    sample: HangSample,
}

#[derive(Deserialize)]
struct Merge {
    aggregate: StallAggregate,
    other: StallAggregate,
}

#[derive(Deserialize)]
struct Aggregate {
    aggregate: StallAggregate,
}

#[derive(Deserialize)]
struct Slot {
    #[serde(default)]
    log: SendLog,
    now: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LaunchDue {
    #[serde(default)]
    last_sent_at: Option<f64>,
    now: f64,
    watchdog_empty: bool,
}

#[derive(Deserialize)]
struct Now {
    now: f64,
}

#[derive(Deserialize)]
struct Outbox {
    entries: Vec<OutboxEntry>,
    now: f64,
}

#[derive(Deserialize)]
struct InstallId {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    created: Option<f64>,
    now: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AskRequest {
    setting_on: bool,
    consented: bool,
    invited: bool,
    telemetry_opt_in: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Hardware {
    #[serde(default)]
    raw_arch: Option<String>,
    #[serde(default)]
    raw_chip: Option<String>,
    cores: i64,
    memory_bytes: u64,
}

#[derive(Deserialize)]
struct Counts {
    windows: i64,
    workspaces: i64,
    panes: i64,
    tabs: i64,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn encode<T: serde::Serialize>(value: &T) -> Result<Value, OpError> {
    serde_json::to_value(value).map_err(|error| OpError::Invalid(error.to_string()))
}

/// Runs one op.
pub fn call(operation: &str, request: Value) -> Result<Value, OpError> {
    let Some(op) = operation.strip_prefix(PREFIX) else {
        return Err(OpError::UnknownOp(operation.to_owned()));
    };
    match op {
        "stack_refs" => {
            let trees: Trees = parse(request)?;
            encode(&tree::refs(trees.trees.iter().map(|tree| tree.as_bytes())))
        }
        "compose" => {
            let (builder, scanner, context, watchdog, metric_kit) =
                parse::<Compose>(request)?.parts();
            encode(&service::compose(&builder, &scanner, &context, &watchdog, &metric_kit))
        }
        "preview" => {
            let (builder, scanner, context, watchdog, metric_kit) =
                parse::<Compose>(request)?.parts();
            Ok(
                json!({ "readable": service::preview(&builder, &scanner, &context, &watchdog, &metric_kit) }),
            )
        }
        "frames" => {
            let frames: Frames = parse(request)?;
            let classifier = Classifier::new(
                frames.app_bundle_path.as_deref(),
                &frames.forbidden_terms,
                Vec::new(),
            );
            Ok(json!({ "frames": encode(&address_frames(&classifier, &frames.addresses))? }))
        }
        "scan" => {
            let body: Body = parse(request)?;
            Ok(
                json!({ "findings": encode(&Scanner::new(&body.forbidden_terms).findings(body.body.as_bytes()))? }),
            )
        }
        "sendable" => {
            let body: Body = parse(request)?;
            let app = body.app.ok_or_else(|| OpError::Invalid("missing app".to_owned()))?;
            Ok(
                json!({ "sendable": service::sendable(body.body.as_bytes(), &app, &Scanner::new(&body.forbidden_terms)) }),
            )
        }
        "note_stall" => {
            let note: NoteStall = parse(request)?;
            encode(&aggregate::note_stall(
                note.duration_nanos,
                note.cpu_nanos,
                note.has_addresses,
                note.stall_count,
                note.last_stall_ms,
            ))
        }
        "note_hang" => {
            let note: NoteHang = parse(request)?;
            encode(&aggregate::note_hang(
                note.duration_nanos,
                note.has_addresses,
                note.hang_count,
                note.last_hang_ms,
            ))
        }
        "keep" => {
            let Keep { mut aggregate, sample } = parse(request)?;
            aggregate.keep(sample);
            Ok(json!({ "aggregate": encode(&aggregate)? }))
        }
        "merge" => {
            let Merge { mut aggregate, other } = parse(request)?;
            aggregate.merge(&other);
            Ok(json!({ "aggregate": encode(&aggregate)? }))
        }
        "aggregate" => {
            let Aggregate { aggregate } = parse(request)?;
            Ok(
                json!({ "isEmpty": aggregate.is_empty(), "histogram": encode(&aggregate.histogram())? }),
            )
        }
        "send_slot" => {
            let slot: Slot = parse(request)?;
            Ok(json!({ "log": encode(&service::take_send_slot(&slot.log, slot.now))? }))
        }
        "launch_due" => {
            let due: LaunchDue = parse(request)?;
            Ok(json!({ "due": service::launch_due(due.last_sent_at, due.now, due.watchdog_empty) }))
        }
        "day" => {
            let now: Now = parse(request)?;
            Ok(json!({ "day": service::day(now.now) }))
        }
        "outbox_plan" => {
            let outbox: Outbox = parse(request)?;
            encode(&service::outbox_plan(&outbox.entries, outbox.now))
        }
        "install_id" => {
            let id: InstallId = parse(request)?;
            Ok(json!({ "keep": service::install_id_valid(id.id.as_deref(), id.created, id.now) }))
        }
        "ask" => {
            let ask: AskRequest = parse(request)?;
            Ok(
                json!({ "decision": encode(&service::ask(ask.setting_on, ask.consented, ask.invited, ask.telemetry_opt_in))? }),
            )
        }
        "hardware" => {
            let raw: Hardware = parse(request)?;
            encode(&hardware(
                raw.raw_arch.as_deref(),
                raw.raw_chip.as_deref(),
                raw.cores,
                raw.memory_bytes,
            ))
        }
        "counts" => {
            let counts: Counts = parse(request)?;
            encode(&CoarseCounts::new(counts.windows, counts.workspaces, counts.panes, counts.tabs))
        }
        _ => Err(OpError::UnknownOp(operation.to_owned())),
    }
}
