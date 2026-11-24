//! `cmux-cloud-start-core`'s hybrid start over the JSON channel (`cloud_hybrid_*`): the app holds
//! the start's state between calls, sends it with each event and its monotonic clock, and runs the
//! effects the answer lists (start here, make the machine, move, deliver or hold a prompt, show).
//! `cloud_hybrid_start` reads back what a `cmux chat` start's driver shows now, for the chat
//! header's `place.start` (cmux-cloud-start-core `hybrid_show`). `cloud_hybrid_keep_count` answers
//! the keep-running switch's count (cmux-cloud-start-core `keep_count`).

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use cmux_cloud_start_core::hybrid::{self, Account, Event, State};
use cmux_cloud_start_core::hybrid_show;
use cmux_cloud_start_core::keep_count;
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_hybrid_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    state: Option<State>,
    event: Event,
    now: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartAsk {
    /// The cmux-tui sessions folder (the app's `CMUX_TUI_STATE_DIR`).
    state_dir: PathBuf,
    session: String,
}

/// How much of a driver's log is read, from its end: its Shows are a handful of short lines among
/// a few hundred others, and the newest is at the end.
const LOG_TAIL: u64 = 64 * 1024;

/// The newest Show of `session`'s driver, or None when it has no log (no hybrid start) or shows
/// nothing. A cut at the tail's start leaves a partial first line, skipped as any torn line is.
pub(crate) fn start_of(sessions: &Path, session: &str) -> Option<hybrid_show::Start> {
    let mut file = std::fs::File::open(hybrid_show::log_file(sessions, session)).ok()?;
    let len = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(LOG_TAIL))).ok()?;
    let mut bytes = Vec::new();
    file.take(LOG_TAIL).read_to_end(&mut bytes).ok()?;
    hybrid_show::newest(&String::from_utf8_lossy(&bytes))
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // Whether a Cloud start of this account is hybrid, and why not.
        b"cloud_hybrid_enabled" => {
            let account: Account = read(request)?;
            match hybrid::enabled(&account) {
                Ok(()) => json!({ "enabled": true }),
                Err(off) => json!({ "enabled": false, "off": off }),
            }
        }
        // One event: the next state and the effects to run, in order.
        b"cloud_hybrid_step" => {
            let step: Step = read(request)?;
            serde_json::to_value(hybrid::step(step.state.unwrap_or_default(), step.event, step.now))
                .map_err(|_| ERR_INVALID)?
        }
        // What the session's hybrid start shows now: `{"start": {cloud, reason?, sinceMs?}}`, or
        // `{}` with no hybrid start.
        b"cloud_hybrid_start" => {
            let ask: StartAsk = read(request)?;
            match start_of(&ask.state_dir, &ask.session) {
                Some(start) => json!({ "start": start }),
                None => json!({}),
            }
        }
        // The keep-running switch's count (RFD 0135): `{plan?, kept, on, hoursUsed?}` answers the
        // plan's slots and hours, how many are kept, and what flipping this chat's switch does.
        b"cloud_hybrid_keep_count" => {
            let facts: keep_count::Facts = read(request)?;
            serde_json::to_value(keep_count::count(&facts)).map_err(|_| ERR_INVALID)?
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
