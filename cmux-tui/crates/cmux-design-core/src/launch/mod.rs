//! The launch reveal's rules (CmuxNextDesign/Launch, Windows/Launch*): frame file names, the
//! launch display, the record request, the layout settle tally, page deferral and stage 0's
//! pure parts.
//!
//! Ops: `launch.NAME` (see [`call`]).

pub mod deferral;
pub mod display;
pub mod files;
pub mod record;
pub mod settle;
pub mod shell;

use crate::ops::{OpError, OpResult, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileRequest {
    #[serde(default)]
    key: String,
    #[serde(default = "one")]
    scale: i64,
    #[serde(default)]
    file: String,
}

fn one() -> i64 {
    1
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DisplayRequest {
    value: Option<String>,
    #[serde(default)]
    is_dev_build: bool,
    display: Option<display::LaunchDisplay>,
    #[serde(default)]
    built_in: Vec<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecordRequest {
    arguments: Vec<String>,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NameRequest {
    name: String,
}

/// One tally input: `first`, or `note` with its change and move.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum TallyEvent {
    First {
        ms: f64,
    },
    Note {
        ms: f64,
        change: String,
        #[serde(rename = "move")]
        mv: Option<settle::Move>,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TallyRequest {
    #[serde(default)]
    tally: settle::Tally,
    #[serde(default)]
    events: Vec<TallyEvent>,
    at: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeferralRequest {
    #[serde(default)]
    state: deferral::PageDeferral,
    events: Vec<deferral::Event>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuildRequest {
    version: Option<String>,
    commit: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KindRequest {
    event_type: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookRequest {
    background: [u8; 4],
    bar: [u8; 4],
    #[serde(default)]
    appearance: u8,
    #[serde(default)]
    reason: u8,
    #[serde(default)]
    image_path: String,
}

/// Runs `launch.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "frameFileName" => {
            let r: FileRequest = parse(request)?;
            reply(&files::name(&r.key, r.scale))
        }
        "frameFileOwner" => {
            let r: FileRequest = parse(request)?;
            reply(&files::owner(&r.file))
        }
        "isFileSafe" => {
            let r: FileRequest = parse(request)?;
            reply(&files::is_file_safe(&r.key))
        }
        "displayParse" => {
            let r: DisplayRequest = parse(request)?;
            reply(&display::LaunchDisplay::parse(r.value.as_deref(), r.is_dev_build))
        }
        "displayScreenIndex" => {
            let r: DisplayRequest = parse(request)?;
            let d = r.display.ok_or_else(|| OpError::Invalid("display is required".into()))?;
            reply(&d.screen_index(&r.built_in))
        }
        "recordRequest" => {
            let r: RecordRequest = parse(request)?;
            reply(&record::LaunchRecordRequest::parse(&r.arguments, &r.home))
        }
        "markName" => {
            let r: NameRequest = parse(request)?;
            reply(&settle::mark_name(&r.name))
        }
        "settleTally" => {
            let mut r: TallyRequest = parse(request)?;
            for e in r.events {
                match e {
                    TallyEvent::First { ms } => r.tally.first(ms),
                    TallyEvent::Note { ms, change, mv } => r.tally.note(ms, &change, mv),
                }
            }
            let over = r.at.map(|ms| r.tally.is_over(ms));
            reply(&json!({ "tally": r.tally, "isOver": over, "marks": r.tally.marks() }))
        }
        "pageDeferral" => {
            let mut r: DeferralRequest = parse(request)?;
            let effects: Vec<_> = r.events.iter().map(|e| r.state.step(e)).collect();
            reply(&json!({ "state": r.state, "holds": r.state.holds(), "effects": effects }))
        }
        "shellBuildKey" => {
            let r: BuildRequest = parse(request)?;
            reply(&shell::build_key(r.version.as_deref(), r.commit.as_deref()))
        }
        "replayKind" => {
            let r: KindRequest = parse(request)?;
            reply(&shell::replay_kind(r.event_type))
        }
        "shellFrame" => {
            let r: shell::FrameRequest = parse(request)?;
            reply(&shell::frame(&r))
        }
        "shellLook" => {
            let r: LookRequest = parse(request)?;
            reply(&json!({
                "background": shell::color(r.background),
                "bar": shell::color(r.bar),
                "dark": r.appearance == 1,
                "imagePath": shell::image_path(r.reason, &r.image_path),
            }))
        }
        "constants" => reply(&json!({
            "backstopSeconds": shell::BACKSTOP_SECONDS,
            "bareBoundMs": shell::BARE_BOUND_MS,
            "recordFile": shell::RECORD_FILE,
            "imagesDir": shell::IMAGES_DIR,
            "quietMs": settle::QUIET_MS,
            "capMs": settle::CAP_MS,
            "displayEnvironmentKey": display::ENVIRONMENT_KEY,
        })),
        _ => Err(OpError::Unknown),
    }
}
