//! `cmux-cloud-start-core`'s hybrid start over the JSON channel (`cloud_hybrid_*`): the app holds
//! the start's state between calls, sends it with each event and its monotonic clock, and runs the
//! effects the answer lists (start here, make the machine, move, deliver or hold a prompt, show).
//! `cloud_hybrid_start` reads back what a `cmux chat` start's driver shows now, for the chat
//! header's `place.start` (cmux-cloud-start-core `hybrid_show`). `cloud_hybrid_keep_count` answers
//! the keep-running switch's count (cmux-cloud-start-core `keep_count`). `cloud_hybrid_balance`
//! simulates where a chat's work should sit (cmux-cloud-start-core `balance`).
//! `cloud_computer_status` folds a
//! session's facts (that Show, a move, the machine's pause and shape, a refusal, the pins) into the
//! one `ComputerStatus` the chat header reads (cmux-cloud-start-core `computer_status`, RFD 0080);
//! `cloud_computer_status_live` builds those facts from what the header already holds (`place`'s
//! `at`, `move` and `start`, and the chat's cloud machine as the server lists it), reading the
//! driver's newest Show itself when the app names the sessions folder and sends no `start`.
//! `cloud_autosize_rows` adds one AutoSize notice (the Cloud wire's `cloud.machine.autosize`
//! frame) to the chat's AutoSize rows (cmux-cloud-start-core `autosize_row`, RFD 0080 piece 4).

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use cmux_cloud_start_core::autosize_row::{self, Row};
use cmux_cloud_start_core::balance;
use cmux_cloud_start_core::computer_status::{self, Facts, HybridFacts};
use cmux_cloud_start_core::hybrid::{self, Account, Event, State};
use cmux_cloud_start_core::hybrid_gui;
use cmux_cloud_start_core::hybrid_show;
use cmux_cloud_start_core::keep_count;
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_hybrid_")
        || matches!(
            operation,
            b"cloud_computer_status" | b"cloud_computer_status_live" | b"cloud_autosize_rows"
        )
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CallKey {
    chat_id: String,
    turn_id: String,
    call_seq: u64,
}

/// `cloud_autosize_rows`' ask: the rows the chat shows, the frame's `data`, and who looks.
#[derive(Deserialize)]
struct RowsAsk {
    #[serde(default)]
    rows: Vec<Row>,
    event: autosize_row::Event,
    #[serde(default)]
    viewer: Option<String>,
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

/// `cloud_computer_status_live`'s request: the live facts, and the sessions folder whose driver
/// says `start` when the app sends none.
#[derive(Deserialize)]
struct LiveAsk {
    #[serde(flatten)]
    live: computer_status::live::Live,
    #[serde(default, rename = "stateDir")]
    state_dir: Option<PathBuf>,
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
        // The app's Cloud send: run its first turn here while the machine boots, or not and why
        // (cmux-cloud-start-core `hybrid_gui`). The kill switches are this process's env.
        b"cloud_hybrid_gui_start" => {
            let mut send: hybrid_gui::Send = read(request)?;
            send.killed |= [hybrid_gui::ENV, hybrid_gui::GUI_ENV]
                .iter()
                .any(|name| hybrid_gui::says_off(std::env::var(name).ok().as_deref()));
            serde_json::to_value(hybrid_gui::decide(&send)).map_err(|_| ERR_INVALID)?
        }
        // One model call's `x-cmux-call-key` (cmux-platform#2074's dedupe).
        b"cloud_hybrid_call_key" => {
            let ask: CallKey = read(request)?;
            json!({
                "header": hybrid_gui::CALL_KEY_HEADER,
                "key": hybrid_gui::call_key(&ask.chat_id, &ask.turn_id, ask.call_seq),
            })
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
        // One session's computer as the chat header shows it: `ComputerStatus`, snake_case.
        b"cloud_computer_status" => {
            let facts: Facts = read(request)?;
            serde_json::to_value(computer_status::status(&facts)).map_err(|_| ERR_INVALID)?
        }
        // The same status from the header's live facts (`computer_status::live`).
        b"cloud_computer_status_live" => {
            let ask: LiveAsk = read(request)?;
            let mut live = ask.live;
            if let (None, Some(state_dir)) = (&live.start, &ask.state_dir) {
                live.start = start_of(state_dir, &live.session).map(|start| HybridFacts {
                    cloud: start.cloud,
                    reason: start.reason,
                    since_ms: start.since_ms,
                });
            }
            let facts = computer_status::live::facts(&live);
            serde_json::to_value(computer_status::status(&facts)).map_err(|_| ERR_INVALID)?
        }
        // One AutoSize notice added to the chat's rows: `{rows, added}`; `added` is false for a
        // wire version this build does not draw (the rows come back as they were).
        b"cloud_autosize_rows" => {
            let ask: RowsAsk = read(request)?;
            match autosize_row::row(&ask.event, ask.viewer.as_deref()) {
                Some(next) => json!({ "rows": autosize_row::push(ask.rows, next), "added": true }),
                None => json!({ "rows": ask.rows, "added": false }),
            }
        }
        // The keep-running switch's count (RFD 0135): `{plan?, kept, on, hoursUsed?}` answers the
        // plan's slots and hours, how many are kept, and what flipping this chat's switch does.
        b"cloud_hybrid_keep_count" => {
            let facts: keep_count::Facts = read(request)?;
            serde_json::to_value(keep_count::count(&facts)).map_err(|_| ERR_INVALID)?
        }
        // Where the chat's work should sit, simulated (cmux-cloud-start-core `balance`): the
        // measured folder, head, upload and wake answer each placement's first tool, whole copy,
        // awake hours and the pick. A read-out: it moves nothing.
        b"cloud_hybrid_balance" => {
            let facts: balance::Facts = read(request)?;
            serde_json::to_value(balance::simulate(&facts)).map_err(|_| ERR_INVALID)?
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
