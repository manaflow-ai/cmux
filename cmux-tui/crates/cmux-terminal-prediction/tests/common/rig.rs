//! A second harness, aimed at what the user sees rather than where each
//! glyph sits. It plays keystrokes through a bash-readline-shaped remote over
//! a link with per-key latency, presents a frame every 16.7 ms, and after
//! every event composes the visible row: ghostty's grid with the overlay
//! painted on top.
//!
//! The property it checks is the one a user notices: a character they
//! deleted, and saw disappear, must not come back.

use super::random::SimulationRandom;
use super::screen::{PROMPT, SimulatedScreen};
use super::us;
use cmux_terminal_prediction::{PredictedGlyph, PredictionConfiguration, Standing, TerminalPredictionEngine};
use std::collections::BTreeSet;
use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RigKey {
    Character(u8),
    Backspace,
    /// Ctrl-U, readline's unix-line-discard.
    KillLine,
    /// Ctrl-W, readline's unix-word-rubout.
    KillWord,
    /// A bracketed paste; its echo is untracked.
    Paste(Vec<u8>),
}

impl fmt::Display for RigKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Character(byte) => write!(f, "{}", char::from(*byte)),
            Self::Backspace => write!(f, "⌫"),
            Self::KillLine => write!(f, "^U"),
            Self::KillWord => write!(f, "^W"),
            Self::Paste(bytes) => write!(f, "paste({})", String::from_utf8_lossy(bytes)),
        }
    }
}

impl RigKey {
    pub fn text(string: &str) -> Vec<RigKey> {
        string.bytes().map(RigKey::Character).collect()
    }
}

#[derive(Clone, Debug)]
pub struct RigKeystroke {
    pub key: RigKey,
    /// Absolute time the key is typed, in microseconds.
    pub at: i64,
    pub uplink: i64,
    pub downlink: i64,
}

/// The remote line: readline with `\b\e[K` erases, as bash does under
/// TERM=xterm-ghostty.
#[derive(Clone, Debug, Default)]
pub struct RigLineEditor {
    pub line: Vec<u8>,
}

fn trim_word(line: &mut Vec<u8>) -> usize {
    let mut removed = 0;
    while line.last() == Some(&0x20) {
        line.pop();
        removed += 1;
    }
    while line.last().is_some_and(|&last| last != 0x20) {
        line.pop();
        removed += 1;
    }
    removed
}

fn erase_cells(count: usize) -> Vec<u8> {
    if count == 0 {
        return Vec::new();
    }
    let mut output = vec![0x08; count];
    output.extend_from_slice(&[0x1B, 0x5B, 0x4B]);
    output
}

impl RigLineEditor {
    pub fn read(&mut self, key: &RigKey) -> Vec<u8> {
        match key {
            RigKey::Character(byte) => {
                self.line.push(*byte);
                vec![*byte]
            }
            RigKey::Backspace => {
                if self.line.pop().is_none() {
                    return vec![0x07];
                }
                vec![0x08, 0x1B, 0x5B, 0x4B]
            }
            RigKey::KillLine => {
                let count = self.line.len();
                self.line.clear();
                erase_cells(count)
            }
            RigKey::KillWord => erase_cells(trim_word(&mut self.line)),
            RigKey::Paste(bytes) => {
                self.line.extend_from_slice(bytes);
                bytes.clone()
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct RigFinding {
    pub time: i64,
    pub column: usize,
    pub character: u8,
    pub visible: String,
    pub typed: String,
}

impl fmt::Display for RigFinding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} ms: column {} shows '{}' again after it was deleted and hidden; visible \"{}\", typed \"{}\"",
            self.time / 1000,
            self.column,
            char::from(self.character),
            self.visible,
            self.typed
        )
    }
}

#[derive(Clone, Debug)]
enum Event {
    Key(usize),
    /// The tee's copy reaches the engine (the main-thread drain).
    Output(Vec<u8>),
    /// Ghostty's parser applies the same bytes to the grid.
    Parse(Vec<u8>),
    Frame,
}

const FRAME_INTERVAL: i64 = 16_667;

fn describe(glyphs: &[PredictedGlyph]) -> String {
    format!("{:?}", glyphs.iter().map(|g| format!("{}@{}", g.character, g.offset)).collect::<Vec<_>>())
}

pub struct PredictionBreakRig {
    /// How long after the remote reply arrives Ghostty spends applying a
    /// read. Ghostty PR #242 moved the tee after the parser, so both events
    /// share the parser's completion time and the grid always receives the
    /// bytes before the host can drain them.
    pub parse_lag_micros: i64,
    /// Characters drawn over cells that hold, or will hold, something else.
    pub wrong_text: Vec<String>,
    /// Microseconds during which a typed character the grid already showed
    /// was blank on screen.
    pub blanked_micros: i64,
    blanked_now: bool,
    /// A typed character that was on screen went blank before it was deleted.
    pub blankings: Vec<String>,

    pub engine: TerminalPredictionEngine,
    pub screen: SimulatedScreen,
    typed: Vec<u8>,
    events: Vec<(i64, usize, Event)>,
    order: usize,
    keystrokes: Vec<RigKeystroke>,
    /// Columns the user deleted and then saw blank.
    hidden_after_delete: BTreeSet<usize>,
    pub resurrections: Vec<RigFinding>,
    /// Microseconds during which some deleted-and-hidden column showed text.
    pub resurrected_micros: i64,
    last_visible_check: i64,
    resurrected_now: bool,
    last_visible: Vec<u8>,
    pub trace: Vec<String>,
    pub ever_drew_speculative: bool,
    /// What the user sees: the last frame ghostty presented, and the overlay
    /// as the host last anchored it. Neither follows the grid between their
    /// own updates.
    presented_row: Vec<u8>,
    overlay: Vec<(i64, u8)>,
    is_tracking_frames: bool,
}

impl PredictionBreakRig {
    pub fn new(keystrokes: Vec<RigKeystroke>) -> Self {
        Self::with_configuration(keystrokes, PredictionConfiguration::DEFAULT)
    }

    pub fn with_configuration(keystrokes: Vec<RigKeystroke>, configuration: PredictionConfiguration) -> Self {
        Self {
            parse_lag_micros: 0,
            wrong_text: Vec::new(),
            blanked_micros: 0,
            blanked_now: false,
            blankings: Vec::new(),
            engine: TerminalPredictionEngine::new(configuration, true, true),
            screen: SimulatedScreen::default(),
            typed: Vec::new(),
            events: Vec::new(),
            order: 0,
            keystrokes,
            hidden_after_delete: BTreeSet::new(),
            resurrections: Vec::new(),
            resurrected_micros: 0,
            last_visible_check: 0,
            resurrected_now: false,
            last_visible: Vec::new(),
            trace: Vec::new(),
            ever_drew_speculative: false,
            presented_row: PROMPT.to_vec(),
            overlay: Vec::new(),
            is_tracking_frames: false,
        }
    }

    fn schedule(&mut self, event: Event, time: i64) {
        self.events.push((time, self.order, event));
        self.order += 1;
    }

    pub fn prompt_width() -> usize {
        PROMPT.len()
    }

    pub fn visible_row(&self) -> Vec<u8> {
        let mut row = self.presented_row.clone();
        for &(column, byte) in &self.overlay {
            if column < 0 {
                continue;
            }
            let column = column as usize;
            while row.len() <= column {
                row.push(0x20);
            }
            row[column] = byte;
        }
        row
    }

    /// `syncPredictionOverlay`: re-anchor on the cursor ghostty has parsed.
    fn sync(&mut self) {
        let glyphs = self.engine.glyphs();
        let cursor = self.screen.cursor;
        self.overlay = glyphs
            .iter()
            .map(|g| (cursor + i64::from(g.offset), if g.character.is_ascii() { g.character as u8 } else { 0x3F }))
            .collect();
        self.is_tracking_frames = !glyphs.is_empty();
    }

    fn apply_typed(&mut self, key: &RigKey) {
        match key {
            RigKey::Character(byte) => self.typed.push(*byte),
            RigKey::Backspace => {
                self.typed.pop();
            }
            RigKey::KillLine => self.typed.clear(),
            RigKey::KillWord => {
                trim_word(&mut self.typed);
            }
            RigKey::Paste(bytes) => self.typed.extend_from_slice(bytes),
        }
    }

    fn check(&mut self, time: i64) {
        let visible = self.visible_row();
        let typed_end = PROMPT.len() + self.typed.len();
        if self.resurrected_now {
            self.resurrected_micros += time - self.last_visible_check;
        }
        if self.blanked_now {
            self.blanked_micros += time - self.last_visible_check;
        }
        self.blanked_now = false;
        for column in 0..PROMPT.len().min(visible.len()) {
            if visible[column] != PROMPT[column] && self.wrong_text.len() < 20 {
                self.wrong_text.push(format!(
                    "{} ms: '{}' drawn over prompt column {column} ('{}')",
                    time / 1000,
                    char::from(visible[column]),
                    char::from(PROMPT[column])
                ));
            }
        }
        for (index, &expected) in self.typed.iter().enumerate() {
            let column = PROMPT.len() + index;
            let shown = visible.get(column).copied().unwrap_or(0x20);
            let was_shown = self.last_visible.get(column) == Some(&expected);
            if shown != expected && shown != 0x20 && self.wrong_text.len() < 20 {
                self.wrong_text.push(format!(
                    "{} ms: '{}' drawn at column {column}, typed '{}'",
                    time / 1000,
                    char::from(shown),
                    char::from(expected)
                ));
            }
            if shown == 0x20 && was_shown && expected != 0x20 {
                self.blanked_now = true;
                if self.blankings.len() < 20 {
                    self.blankings.push(format!(
                        "{} ms: typed '{}' at column {column} went blank",
                        time / 1000,
                        char::from(expected)
                    ));
                }
            }
        }
        self.last_visible_check = time;
        self.resurrected_now = false;
        self.hidden_after_delete.retain(|&column| column >= typed_end);
        let width = visible
            .len()
            .max(self.last_visible.len())
            .max(self.hidden_after_delete.last().copied().unwrap_or(0) + 1);
        for column in typed_end..typed_end.max(width) {
            let shown = visible.get(column).copied().unwrap_or(0x20);
            let before = self.last_visible.get(column).copied().unwrap_or(0x20);
            if shown == 0x20 {
                if before != 0x20 {
                    self.hidden_after_delete.insert(column);
                }
            } else if self.hidden_after_delete.contains(&column) {
                self.resurrected_now = true;
                if self.resurrections.len() < 20 {
                    self.resurrections.push(RigFinding {
                        time,
                        column,
                        character: shown,
                        visible: String::from_utf8_lossy(&visible[PROMPT.len().min(visible.len())..]).into_owned(),
                        typed: String::from_utf8_lossy(&self.typed).into_owned(),
                    });
                }
            }
        }
        self.last_visible = visible;
        if self.engine.glyphs().iter().any(|g| g.standing == Standing::Speculative) {
            self.ever_drew_speculative = true;
        }
    }

    pub fn run(&mut self) {
        let mut read_at = 0;
        let mut replied_at = 0;
        let mut remote_model = RigLineEditor::default();
        let keystrokes = self.keystrokes.clone();
        for (index, keystroke) in keystrokes.iter().enumerate() {
            self.schedule(Event::Key(index), keystroke.at);
            read_at = read_at.max(keystroke.at + keystroke.uplink);
            let reply = remote_model.read(&keystroke.key);
            replied_at = replied_at.max(read_at + keystroke.downlink);
            if !reply.is_empty() {
                let parser_finished_at = replied_at + self.parse_lag_micros;
                self.schedule(Event::Parse(reply.clone()), parser_finished_at);
                self.schedule(Event::Output(reply), parser_finished_at);
            }
        }
        let end = self.events.iter().map(|e| e.0).max().unwrap_or(0) + 2_000_000;
        let mut frame_time = FRAME_INTERVAL;
        while frame_time < end {
            self.schedule(Event::Frame, frame_time);
            frame_time += FRAME_INTERVAL;
        }
        let mut events = std::mem::take(&mut self.events);
        events.sort_by_key(|e| (e.0, e.1));
        for (time, _, event) in events {
            let now = us(time);
            match event {
                Event::Key(index) => {
                    let key = keystrokes[index].key.clone();
                    self.apply_typed(&key);
                    let changed = match &key {
                        RigKey::Character(byte) => self.engine.typed_printable_ascii(Some(*byte), now),
                        RigKey::Backspace => self.engine.typed_backspace(now),
                        RigKey::KillLine | RigKey::KillWord => self.engine.typed_line_erase(now),
                        RigKey::Paste(_) => self.engine.sent_untracked_input(now),
                    };
                    if changed {
                        self.sync();
                    }
                    let overlay = describe(&self.engine.glyphs());
                    self.trace.push(format!("{}ms type {key} -> overlay {overlay}", time / 1000));
                }
                Event::Parse(bytes) => {
                    self.screen.apply(&bytes);
                    self.trace.push(format!("{}ms parse {}B cursor {}", time / 1000, bytes.len(), self.screen.cursor));
                }
                Event::Output(bytes) => {
                    if self.engine.observed_output(&bytes, now) && !self.engine.holds_layout_until_frame() {
                        self.sync();
                    }
                    let overlay = describe(&self.engine.glyphs());
                    self.trace.push(format!("{}ms echo {}B -> overlay {overlay}", time / 1000, bytes.len()));
                }
                Event::Frame => {
                    self.presented_row = self.screen.row.clone();
                    let expired = self.engine.tick(now);
                    if self.is_tracking_frames {
                        self.engine.presented_frame(now);
                        self.sync();
                    } else if expired {
                        self.sync();
                    }
                }
            }
            self.check(time);
        }
    }
}

/// Builds keystroke lists with a fixed or jittered round trip.
pub struct RigScript {
    pub keystrokes: Vec<RigKeystroke>,
    pub clock: i64,
    pub round_trip: i64,
    pub jitter: i64,
    pub random: SimulationRandom,
}

impl RigScript {
    pub fn new(round_trip_milliseconds: i64) -> Self {
        Self::jittered(round_trip_milliseconds, 0, 1)
    }

    pub fn jittered(round_trip_milliseconds: i64, jitter_milliseconds: i64, seed: u64) -> Self {
        Self {
            keystrokes: Vec::new(),
            clock: 0,
            round_trip: round_trip_milliseconds * 1000,
            jitter: jitter_milliseconds * 1000,
            random: SimulationRandom::new(seed),
        }
    }

    pub fn wait(&mut self, milliseconds: i64) {
        self.clock += milliseconds * 1000;
    }

    pub fn press(&mut self, key: RigKey, gap_milliseconds: i64) {
        self.clock += gap_milliseconds * 1000;
        let trip = self.round_trip + if self.jitter > 0 { self.random.int_in(-self.jitter, self.jitter) } else { 0 };
        let uplink = (trip / 2).max(1);
        self.keystrokes.push(RigKeystroke { key, at: self.clock, uplink, downlink: (trip - uplink).max(1) });
    }

    /// `type` with the default 30 ms gap.
    pub fn type_text(&mut self, text: &str) {
        self.type_text_gap(text, 30);
    }

    pub fn type_text_gap(&mut self, text: &str, gap_milliseconds: i64) {
        for key in RigKey::text(text) {
            self.press(key, gap_milliseconds);
        }
    }

    /// `hold` with the default 33 ms repeat.
    pub fn hold(&mut self, key: RigKey, count: usize, initial_delay_milliseconds: i64) {
        self.hold_repeat(key, count, initial_delay_milliseconds, 33);
    }

    pub fn hold_repeat(&mut self, key: RigKey, count: usize, initial_delay_milliseconds: i64, repeat_milliseconds: i64) {
        for index in 0..count {
            self.press(key.clone(), if index == 0 { initial_delay_milliseconds } else { repeat_milliseconds });
        }
    }

    /// Two echoed keystrokes so the run is armed, then a pause. (One is not
    /// enough: a tty in cooked mode echoes the first key typed ahead of a
    /// password prompt.)
    pub fn arm(&mut self) {
        self.type_text_gap("l", 10);
        self.wait(1_000);
        self.type_text_gap("s", 10);
        self.wait(1_000);
    }
}
