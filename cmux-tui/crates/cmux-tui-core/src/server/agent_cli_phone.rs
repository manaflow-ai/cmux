//! `agent-cli-phone-grid-v1`: a phone's viewer of a Claude Code terminal gets Claude Code drawn
//! at the phone's own grid, never the Mac's screen squeezed onto it, and the Mac is never
//! resized for it (Leo, 2026-11-25: "we know what a Mac's Claude code pane looks like. And we
//! know it/can know it for any variation/combination at various phone sizes ... do everything
//! at parity on the phone"; "you obviously fit to phone by default").
//!
//! The hybrid viewer (`agent_cli_hybrid.rs`) already keeps the Mac's screen in a terminal of its
//! own. For a viewer that declared this capability and gave its grid (`view_cols`, `view_rows`
//! on `attach-surface`), each frame is instead `cmux_agent_cli_render::claude::render` at that
//! grid, from:
//!
//! - the records: Claude Code's own transcript (the session the terminal's hook reported, read
//!   by acpmux's adopt reader, the same records an adopted chat replays), folded from where the
//!   last read stopped when it grows, so a long session costs only its new lines per change;
//! - the host facts only the screen has (`claude_facts::ScreenFacts`): the banner, mode, effort,
//!   done verb, placeholder, the person's unsent draft and whether a turn runs, read off the
//!   Mac's screen at each frame.
//!
//! The viewer's terminal stays on the primary screen with no mouse modes: the rows above the
//! phone's screen go into its own scrollback (`vt::history_bytes` before the first frame, the
//! frames' scroll after), so a swipe scrolls on the phone and never scrolls the Mac.
//! `tests/parity.rs` in cmux-agent-cli-render holds the drawing to real Claude Code screens at
//! iPhone grids.

use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;

use acpmux::adopt_replay::{Fold, PastTurn};

use cmux_agent_cli_render::claude::{self, Chrome};
use cmux_agent_cli_render::claude_facts::ScreenFacts;
use cmux_agent_cli_render::{Cell, Grid};
use serde_json::{Value, json};

/// Advertised in `identify`; a phone declares it in `set-client-info` with the hybrid stream.
pub const AGENT_CLI_PHONE_GRID_CAPABILITY: &str = "agent-cli-phone-grid-v1";

/// The smallest grid drawn natively; a smaller one keeps the Mac's screen.
const MIN_COLS: u16 = 20;
const MIN_ROWS: u16 = 8;

/// Claude Code's full-screen look starts here; a screen whose banner has scrolled away still
/// draws it.
const FULL_SCREEN_SINCE: &str = "2.1.320";

/// The newest turns drawn (acpmux's adopted-chat replay keeps as many): a long session's frame
/// costs the same as a short one's.
const KEEP_TURNS: usize = 200;
/// A transcript bigger than this, met for the first time, is folded from its newest part only.
const FIRST_READ_BYTES: u64 = 64 << 20;
/// An unended line held longer than this is dropped up to its end, so a runaway one cannot grow
/// the daemon. It is the whole reader's window ([`FIRST_READ_BYTES`], acpmux's `MAX_BYTES`):
/// every record that reader parsed, this one parses too.
const MAX_PARTIAL_BYTES: usize = FIRST_READ_BYTES as usize;
/// The last bytes folded, read again before each fold: a file rewritten in place (same inode,
/// as long or longer) that differs there is folded from its start.
///
/// The writer contract is append-only: Claude Code only appends records to a session
/// transcript. A shorter file, another inode or a changed seam is caught and refolded from the
/// start; a rewrite that keeps the length and these last bytes but changes earlier content is
/// not. Catching that would mean reading the whole file on each change, which is the cost this
/// incremental fold exists to avoid, so it is the stated limit, not a check.
const SEAM_BYTES: usize = 64;

/// One viewer's Claude Code drawn at its grid.
pub(super) struct PhoneGrid {
    pub(super) cols: u16,
    pub(super) rows: u16,
    transcript: PathBuf,
    /// The host facts seen so far: the banner's persist after it scrolls away.
    seen: Chrome,
    /// The transcript folded so far, up to `offset`; `partial` is a line not yet ended
    /// (`skipping`: one dropped for its length, up to its end).
    fold: Fold,
    offset: u64,
    partial: Vec<u8>,
    skipping: bool,
    /// The file read (device, inode): another file at the path is another transcript.
    file_id: Option<(u64, u64)>,
    /// The last [`SEAM_BYTES`] folded, ending at `offset`.
    seam: Vec<u8>,
}

/// The transcript of the Claude Code session `session_id`, under the login's Claude home.
pub(super) fn transcript_of(session_id: &str) -> Option<PathBuf> {
    let homes = acpmux::adopt::HarnessHomes::from_env();
    acpmux::adopt::find("claude", session_id, &homes).ok().map(|found| found.file)
}

impl PhoneGrid {
    /// `None` for a grid too small to draw.
    pub(super) fn new(cols: u16, rows: u16, transcript: PathBuf) -> Option<PhoneGrid> {
        (cols >= MIN_COLS && rows >= MIN_ROWS).then(|| PhoneGrid {
            cols,
            rows,
            transcript,
            seen: Chrome::default(),
            fold: Fold::new("claude", true),
            offset: 0,
            partial: Vec::new(),
            skipping: false,
            file_id: None,
            seam: Vec::new(),
        })
    }

    /// The phone's screen for the Mac's screen `mac` (Claude Code's own, at the Mac's grid),
    /// and the rows above it.
    pub(super) fn draw(&mut self, mac: &Grid, mac_alternate: bool) -> (Vec<Vec<Cell>>, Grid) {
        let facts = ScreenFacts::read(mac);
        facts.apply(&mut self.seen);
        if self.seen.version.is_none() && mac_alternate {
            self.seen.version = Some(FULL_SCREEN_SINCE.to_owned());
        }
        self.refresh();
        let records = records(self.turns(), facts.running);
        claude::render_with_history(&records, &self.seen, self.cols, self.rows)
    }

    /// The turns drawn: the newest [`KEEP_TURNS`] folded.
    fn turns(&self) -> &[PastTurn] {
        let turns = self.fold.held(false).1;
        turns.get(turns.len().saturating_sub(KEEP_TURNS)..).unwrap_or_default()
    }

    /// Folds what the transcript gained since the last read. Claude Code only appends to it; a
    /// file shorter than what was read is a new one, folded from its start.
    fn refresh(&mut self) {
        let Ok(mut file) = std::fs::File::open(&self.transcript) else { return };
        let Ok(meta) = file.metadata() else { return };
        let len = meta.len();
        let id = file_id(&meta);
        if len < self.offset || id != self.file_id || !self.seam_holds(&mut file) {
            self.fold = Fold::new("claude", true);
            self.offset = 0;
            self.partial.clear();
            self.skipping = false;
            self.file_id = id;
            self.seam.clear();
        }
        if len == self.offset {
            return;
        }
        // The first read of a huge transcript starts near its end, past the partial line there.
        if self.offset == 0 && len > FIRST_READ_BYTES {
            self.offset = len - FIRST_READ_BYTES;
            self.skipping = true;
        }
        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            return;
        }
        // No further than the file was when opened: one read is bounded however fast it grows.
        let mut bytes = Vec::new();
        if file.take(len - self.offset).read_to_end(&mut bytes).is_err() {
            return;
        }
        self.offset += bytes.len() as u64;
        let keep = self.seam.len().saturating_sub(SEAM_BYTES.saturating_sub(bytes.len()));
        self.seam.drain(..keep);
        self.seam.extend_from_slice(
            bytes.get(bytes.len().saturating_sub(SEAM_BYTES)..).unwrap_or_default(),
        );
        let mut rest = bytes.as_slice();
        while let Some(end) = rest.iter().position(|&b| b == b'\n') {
            let Some((line, tail)) = rest.split_at_checked(end) else { break };
            if std::mem::take(&mut self.skipping) {
                // The rest of a line dropped (cut by the first read, or too long): not a record.
            } else if self.partial.is_empty() {
                self.fold.line(line);
            } else {
                self.partial.extend_from_slice(line);
                self.fold.line(&std::mem::take(&mut self.partial));
            }
            rest = tail.get(1..).unwrap_or_default();
        }
        if !self.skipping {
            self.partial.extend_from_slice(rest);
            if self.partial.len() > MAX_PARTIAL_BYTES {
                self.partial = Vec::new();
                self.skipping = true;
            }
        }
        // Older turns never change again: let them go, so memory stays bounded too.
        self.fold.settle(KEEP_TURNS);
    }

    /// The file still holds, just before `offset`, the bytes last folded there.
    fn seam_holds(&self, file: &mut std::fs::File) -> bool {
        if self.seam.is_empty() {
            return true;
        }
        let mut now = vec![0; self.seam.len()];
        file.seek(SeekFrom::Start(self.offset - self.seam.len() as u64)).is_ok()
            && file.read_exact(&mut now).is_ok()
            && now == self.seam
    }

    /// Bytes held for a line not yet ended (at most [`MAX_PARTIAL_BYTES`]).
    #[cfg(test)]
    pub(super) fn partial_len(&self) -> usize {
        self.partial.len()
    }

    #[cfg(test)]
    pub(super) fn transcript(&self) -> &std::path::Path {
        &self.transcript
    }
}

#[cfg(unix)]
fn file_id(meta: &std::fs::Metadata) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    Some((meta.dev(), meta.ino()))
}

#[cfg(not(unix))]
fn file_id(_: &std::fs::Metadata) -> Option<(u64, u64)> {
    None
}

fn update(update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": update}})
}

fn record(kind: &str, msg: Value, at: Option<u64>) -> Value {
    json!({"kind": kind, "msg": msg, "at": at})
}

/// The records an adopted chat replays for `turns` (`hub/adoption.rs`), the last turn left
/// open when one runs.
pub(super) fn records(turns: &[PastTurn], open: bool) -> Vec<Value> {
    let last = turns.len().saturating_sub(1);
    let mut out = Vec::new();
    for (i, turn) in turns.iter().enumerate() {
        out.push(record(
            "turn_started",
            json!({"prompt": turn.prompt, "client": "adopt"}),
            turn.prompt_at,
        ));
        if !turn.prompt.is_empty() {
            out.push(record(
                "user_message",
                json!({"text": turn.prompt, "client": "adopt"}),
                turn.prompt_at,
            ));
        }
        for tool in &turn.tools {
            let mut call = tool.call.clone();
            set_key(&mut call, "sessionUpdate", json!("tool_call"));
            set_key(&mut call, "toolCallId", json!(tool.id));
            set_key(&mut call, "status", json!("in_progress"));
            out.push(record("tool_call", update(call), tool.started_at));
            let mut done = tool.done.clone();
            set_key(&mut done, "sessionUpdate", json!("tool_call_update"));
            set_key(&mut done, "toolCallId", json!(tool.id));
            out.push(record("tool_call_update", update(done), tool.ended_at.or(tool.started_at)));
        }
        if !turn.answer.is_empty() {
            let msg = update(
                json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": turn.answer}}),
            );
            out.push(record("agent_message_chunk", msg, turn.answer_at));
        }
        if !(open && i == last) {
            let ended = turn.tools.iter().filter_map(|t| t.ended_at).chain(turn.answer_at).max();
            out.push(record("turn_end", json!({"stopReason": "end_turn"}), ended));
            out.push(record(
                "turn_result",
                json!({"status": "completed", "stopReason": "end_turn"}),
                ended,
            ));
        }
    }
    out
}

/// Sets `key` on a JSON object, as `value[key] = v` would, without its panic on a non-object: a
/// null becomes an object first, and anything else is left alone.
fn set_key(value: &mut Value, key: &str, v: Value) {
    if value.is_null() {
        *value = Value::Object(serde_json::Map::new());
    }
    if let Some(object) = value.as_object_mut() {
        object.insert(key.to_owned(), v);
    }
}

#[cfg(test)]
#[path = "agent_cli_phone_tests.rs"]
mod tests;
