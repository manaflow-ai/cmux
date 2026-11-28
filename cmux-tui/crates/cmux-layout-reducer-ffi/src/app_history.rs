//! `cmux-app-history` over the JSON channel (ops `app_history_*`): the rules
//! of the app's history, global search, file explorer and window hints. The
//! app lists folders, reads transcripts, walks accessibility trees and runs
//! timers; it sends the facts and acts on the answer.

use cmux_app_history::{commands, files, find, hints, retention, search};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"app_history_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: serde::Serialize>(answer: T) -> Result<serde_json::Value, i32> {
    serde_json::to_value(answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Query {
    #[serde(default)]
    query: String,
}

#[derive(Deserialize)]
struct Lines {
    #[serde(default)]
    lines: Vec<String>,
}

#[derive(Deserialize)]
struct Sources {
    #[serde(default)]
    sources: Vec<search::ReadSource>,
}

#[derive(Deserialize)]
struct SearchRow {
    line: String,
}

#[derive(Deserialize)]
struct SearchRows {
    #[serde(default)]
    words: Vec<String>,
    #[serde(default)]
    rows: Vec<SearchRow>,
}

#[derive(Deserialize)]
struct GitStatus {
    top: String,
    #[serde(default)]
    entries: Vec<files::StatusEntry>,
}

#[derive(Deserialize)]
struct Relative {
    #[serde(default)]
    root: Option<String>,
    path: String,
}

#[derive(Deserialize)]
struct MayRead {
    #[serde(default)]
    protected: bool,
    folder: String,
    #[serde(default)]
    asked: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FindQuery {
    #[serde(default)]
    text: String,
    #[serde(default)]
    has_root: bool,
}

#[derive(Deserialize)]
struct FindOutcome {
    outcome: find::Outcome,
}

#[derive(Deserialize)]
struct HintRects {
    #[serde(default)]
    frames: Vec<hints::Rect>,
    bounds: hints::Rect,
    limit: usize,
}

#[derive(Deserialize)]
struct HintPage {
    answer: String,
    view: hints::PageView,
}

#[derive(Deserialize)]
struct HintPageRect {
    near: [f64; 2],
    far: [f64; 2],
    clip: hints::Rect,
}

/// Answers one `app_history_*` operation.
pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // Global search: the query's words (lowercased, split on whitespace).
        b"app_history_search_words" => {
            let request: Query = read(request)?;
            json!({ "words": search::words(&request.query) })
        }
        // A text's searchable lines (blank ones dropped).
        b"app_history_search_lines" => {
            let request: Lines = read(request)?;
            json!({ "lines": search::content_lines(&request.lines) })
        }
        // Which transcripts to read first: readable ones, local before remote.
        b"app_history_search_read_order" => {
            let request: Sources = read(request)?;
            json!({ "order": search::read_order(&request.sources) })
        }
        // Each hit line's snippet around the first word, and the find needle.
        b"app_history_search_rows" => {
            let request: SearchRows = read(request)?;
            let rows: Vec<_> = request
                .rows
                .iter()
                .map(|row| {
                    json!({
                        "snippet": search::snippet(&row.line, &request.words, search::BEFORE, search::AFTER),
                        "needle": search::needle(&row.line, &request.words),
                    })
                })
                .collect();
            json!({ "rows": rows })
        }
        // The file explorer's visible rows with their git states.
        b"app_history_file_rows" => {
            let tree: files::Tree = read(request)?;
            json!({ "rows": tree.rows() })
        }
        // Git's states by absolute path and the folders with changes inside.
        b"app_history_file_git" => {
            let request: GitStatus = read(request)?;
            value(files::git_tree(&request.top, &request.entries))?
        }
        b"app_history_file_relative" => {
            let request: Relative = read(request)?;
            json!({ "path": files::relative_path(request.root.as_deref(), &request.path) })
        }
        b"app_history_file_may_read" => {
            let request: MayRead = read(request)?;
            json!({ "mayRead": files::may_read(request.protected, &request.folder, &request.asked) })
        }
        // Closed-tab retention: prune now, when to look again, and the failed-delete retry.
        b"app_history_closed_check" => {
            let check: retention::Check = read(request)?;
            let decision = retention::decide(&check);
            json!({
                "prune": decision.prune,
                "recheckAfterMs": decision.recheck_after_ms,
                "cancelDeadline": decision.cancel_deadline,
                "retryMs": retention::RETRY_MS,
            })
        }
        // Command history settings: which machines to tell, and whether to offer deletion.
        b"app_history_command_sync" => {
            let state: commands::Sync = read(request)?;
            value(commands::sync(&state))?
        }
        // Find in files: the query to run (none: show nothing).
        b"app_history_find_query" => {
            let request: FindQuery = read(request)?;
            json!({ "query": find::query(&request.text, request.has_root) })
        }
        b"app_history_find_state" => {
            let request: FindOutcome = read(request)?;
            value(find::state(request.outcome))?
        }
        // Window hints: the accessibility frames kept, by index, with their clipped rects.
        b"app_history_hint_rects" => {
            let request: HintRects = read(request)?;
            let kept: Vec<_> = hints::accept(&request.frames, request.bounds, request.limit)
                .into_iter()
                .map(|(index, rect)| json!({ "index": index, "rect": rect }))
                .collect();
            json!({ "kept": kept })
        }
        // A page's links as view-local corners.
        b"app_history_hint_page" => {
            let request: HintPage = read(request)?;
            json!({ "links": hints::page_points(&request.answer, request.view) })
        }
        b"app_history_hint_page_rect" => {
            let request: HintPageRect = read(request)?;
            json!({ "rect": hints::page_rect(request.near, request.far, request.clip) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
