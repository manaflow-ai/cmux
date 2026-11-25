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
//!   by acpmux's adopt reader, the same records an adopted chat replays), re-read when it grows;
//! - the host facts only the screen has (`claude_facts::ScreenFacts`): the banner, mode, effort,
//!   done verb, placeholder, the person's unsent draft and whether a turn runs, read off the
//!   Mac's screen at each frame.
//!
//! The viewer's terminal stays on the primary screen with no mouse modes: the rows above the
//! phone's screen go into its own scrollback (`vt::history_bytes` before the first frame, the
//! frames' scroll after), so a swipe scrolls on the phone and never scrolls the Mac.
//! `tests/parity.rs` in cmux-agent-cli-render holds the drawing to real Claude Code screens at
//! iPhone grids.

use std::path::PathBuf;
use std::time::SystemTime;

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

/// One viewer's Claude Code drawn at its grid.
pub(super) struct PhoneGrid {
    pub(super) cols: u16,
    pub(super) rows: u16,
    transcript: PathBuf,
    /// The host facts seen so far: the banner's persist after it scrolls away.
    seen: Chrome,
    /// The transcript's length and change time at the last read.
    read_at: Option<(u64, Option<SystemTime>)>,
    turns: Vec<acpmux::adopt_replay::PastTurn>,
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
            read_at: None,
            turns: Vec::new(),
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
        let records = records(&self.turns, facts.running);
        claude::render_with_history(&records, &self.seen, self.cols, self.rows)
    }

    /// Re-reads the transcript when it changed since the last read.
    fn refresh(&mut self) {
        let meta = std::fs::metadata(&self.transcript).ok();
        let now = meta.map(|m| (m.len(), m.modified().ok()));
        if now.is_some() && now != self.read_at {
            self.turns = acpmux::adopt_replay::read("claude", &self.transcript);
            self.read_at = now;
        }
    }

    #[cfg(test)]
    pub(super) fn transcript(&self) -> &std::path::Path {
        &self.transcript
    }
}

fn update(update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": update}})
}

fn record(kind: &str, msg: Value, at: Option<u64>) -> Value {
    json!({"kind": kind, "msg": msg, "at": at})
}

/// The records an adopted chat replays for `turns` (`hub/adoption.rs`), the last turn left
/// open when one runs.
pub(super) fn records(turns: &[acpmux::adopt_replay::PastTurn], open: bool) -> Vec<Value> {
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
            call["sessionUpdate"] = json!("tool_call");
            call["toolCallId"] = json!(tool.id);
            call["status"] = json!("in_progress");
            out.push(record("tool_call", update(call), tool.started_at));
            let mut done = tool.done.clone();
            done["sessionUpdate"] = json!("tool_call_update");
            done["toolCallId"] = json!(tool.id);
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

#[cfg(test)]
#[path = "agent_cli_phone_tests.rs"]
mod tests;
