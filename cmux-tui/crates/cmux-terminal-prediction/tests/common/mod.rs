//! Shared harness for the prediction tests, ported from classic cmux's
//! `TerminalPredictionSimulationTests.swift` (the seeded generator, the remote
//! line editor and the screen model) and `PredictionBreakRig.swift`.
//!
//! Each test binary uses a different part of this module.
#![allow(dead_code)]

use cmux_terminal_prediction::{PredictionConfiguration, Standing, TerminalPredictionEngine};
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::ops::RangeInclusive;
use std::time::Duration;

/// Microseconds since the test's origin as an engine instant.
pub fn micros(time: i64) -> Duration {
    Duration::from_micros(u64::try_from(time).expect("instants are never before the origin"))
}

/// Deterministic generator, so a failing seed replays exactly.
///
/// `next_u64` is the Swift suite's splitmix64. The helpers draw the way
/// Swift's `RandomNumberGenerator` extensions do (`Int.random(in:using:)`,
/// `randomElement(using:)`, `Bool.random(using:)`), so a seed produces the
/// same case it did in the Swift suite.
#[derive(Clone, Debug)]
pub struct SimulationRandom {
    state: u64,
}

impl SimulationRandom {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Swift's `next(upperBound:)`: Lemire's nearly divisionless method.
    pub fn next_below(&mut self, upper_bound: u64) -> u64 {
        assert_ne!(upper_bound, 0, "upperBound cannot be zero.");
        let mut product = u128::from(self.next_u64()) * u128::from(upper_bound);
        if (product as u64) < upper_bound {
            let threshold = upper_bound.wrapping_neg() % upper_bound;
            while (product as u64) < threshold {
                product = u128::from(self.next_u64()) * u128::from(upper_bound);
            }
        }
        (product >> 64) as u64
    }

    /// Swift's `Int.random(in: lower...upper, using:)`.
    pub fn int_in(&mut self, range: RangeInclusive<i64>) -> i64 {
        let (lower, upper) = range.into_inner();
        let delta = upper.wrapping_sub(lower) as u64;
        if delta == u64::MAX {
            return self.next_u64() as i64;
        }
        lower.wrapping_add(self.next_below(delta + 1) as i64)
    }

    /// Swift's `Int.random(in: 0..<count, using:)`.
    pub fn int_below(&mut self, count: usize) -> usize {
        self.next_below(count as u64) as usize
    }

    /// Swift's `Bool.random(using:)`.
    pub fn bool(&mut self) -> bool {
        (self.next_u64() >> 17) & 1 == 0
    }

    /// Swift's `randomElement(using:)` on a non-empty collection.
    pub fn element<T: Copy>(&mut self, items: &[T]) -> T {
        items[self.int_below(items.len())]
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SimulatedKey {
    Character(u8),
    Backspace,
}

impl fmt::Display for SimulatedKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SimulatedKey::Character(byte) => write!(formatter, "{}", char::from(*byte)),
            SimulatedKey::Backspace => write!(formatter, "⌫"),
        }
    }
}

/// How the remote line editor erases one character at the end of the line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SimulatedEraseForm {
    /// bash readline with TERM=xterm-ghostty, as captured on big-red.
    BackspaceClearToEnd,
    /// Canonical tty echo.
    BackspaceSpaceBackspace,
    CursorLeftDeleteCharacter,
}

impl SimulatedEraseForm {
    /// Swift's `allCases`, in declaration order.
    pub const ALL: [SimulatedEraseForm; 3] = [
        SimulatedEraseForm::BackspaceClearToEnd,
        SimulatedEraseForm::BackspaceSpaceBackspace,
        SimulatedEraseForm::CursorLeftDeleteCharacter,
    ];

    pub fn bytes(self) -> &'static [u8] {
        match self {
            SimulatedEraseForm::BackspaceClearToEnd => &[0x08, 0x1B, 0x5B, 0x4B],
            SimulatedEraseForm::BackspaceSpaceBackspace => &[0x08, 0x20, 0x08],
            SimulatedEraseForm::CursorLeftDeleteCharacter => &[0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x50],
        }
    }
}

/// The remote's line: what bash readline holds after the keys it has read.
#[derive(Clone, Debug, Default)]
pub struct SimulatedLineEditor {
    pub line: Vec<u8>,
}

impl SimulatedLineEditor {
    pub const PROMPT: &'static [u8] = b"leo@big-red:~$ ";

    /// Applies a key and returns what the remote writes back.
    pub fn read(&mut self, key: SimulatedKey, erase_form: SimulatedEraseForm) -> Vec<u8> {
        match key {
            SimulatedKey::Character(byte) => {
                self.line.push(byte);
                vec![byte]
            }
            SimulatedKey::Backspace => {
                if self.line.pop().is_none() {
                    return vec![0x07];
                }
                erase_form.bytes().to_vec()
            }
        }
    }

    /// The row as it looks once every key read so far is echoed.
    pub fn row(&self) -> Vec<u8> {
        let mut row = Self::PROMPT.to_vec();
        row.extend_from_slice(&self.line);
        row
    }

    /// Applies keys read together and returns one redisplay of the net change.
    pub fn read_together(&mut self, keys: &[SimulatedKey]) -> Vec<u8> {
        let before = self.line.clone();
        for key in keys {
            match key {
                SimulatedKey::Character(byte) => self.line.push(*byte),
                SimulatedKey::Backspace => {
                    self.line.pop();
                }
            }
        }
        let common = before.iter().zip(&self.line).take_while(|(old, new)| old == new).count();
        let mut output = vec![0x08; before.len() - common];
        output.extend_from_slice(&self.line[common..]);
        if self.line.len() < before.len() {
            output.extend_from_slice(&[0x1B, 0x5B, 0x4B]);
        }
        output
    }
}

/// Just enough of a terminal to track the cursor row: printables, BS, BEL,
/// and CSI K, D and P with the counts a line editor uses.
#[derive(Clone, Debug)]
pub struct SimulatedScreen {
    pub row: Vec<u8>,
    pub cursor: i64,
    escape: Option<Vec<u8>>,
    /// How many times each column was written or cleared.
    writes: HashMap<i64, i64>,
}

impl Default for SimulatedScreen {
    fn default() -> Self {
        Self {
            row: SimulatedLineEditor::PROMPT.to_vec(),
            cursor: SimulatedLineEditor::PROMPT.len() as i64,
            escape: None,
            writes: HashMap::new(),
        }
    }
}

impl SimulatedScreen {
    pub fn character(&self, column: i64) -> Option<u8> {
        usize::try_from(column).ok().and_then(|column| self.row.get(column).copied())
    }

    pub fn write_count(&self, column: i64) -> i64 {
        self.writes.get(&column).copied().unwrap_or_default()
    }

    /// Every column from `column` to the end of the row changed.
    fn touch_through_end(&mut self, column: i64) {
        for touched in column..(column + 1).max(self.row.len() as i64) {
            *self.writes.entry(touched).or_insert(0) += 1;
        }
    }

    pub fn apply(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.apply_byte(byte);
        }
    }

    fn apply_byte(&mut self, byte: u8) {
        if let Some(mut sequence) = self.escape.take() {
            sequence.push(byte);
            if sequence.len() < 2 || !(0x40..=0x7E).contains(&byte) {
                self.escape = Some(sequence);
                return;
            }
            let count = std::str::from_utf8(&sequence[1..sequence.len() - 1])
                .ok()
                .and_then(|digits| digits.parse::<i64>().ok())
                .unwrap_or(1)
                .max(1);
            let cursor = self.cursor;
            let index = usize::try_from(cursor).unwrap_or_default();
            match byte {
                b'K' => {
                    self.touch_through_end(cursor);
                    if index < self.row.len() {
                        self.row.truncate(index);
                    }
                }
                b'D' => self.cursor = (cursor - count).max(0),
                b'P' => {
                    self.touch_through_end(cursor);
                    if index < self.row.len() {
                        let end = self.row.len().min(index + count as usize);
                        self.row.drain(index..end);
                    }
                }
                _ => {}
            }
            return;
        }
        match byte {
            0x1B => self.escape = Some(Vec::new()),
            0x08 => self.cursor = (self.cursor - 1).max(0),
            0x20..=0x7E => {
                let index = self.cursor as usize;
                if self.row.len() <= index {
                    self.row.resize(index + 1, 0x20);
                }
                self.row[index] = byte;
                *self.writes.entry(self.cursor).or_insert(0) += 1;
                self.cursor += 1;
            }
            // BEL and everything else leave the row alone.
            _ => {}
        }
    }
}

// A second harness, aimed at what the user sees rather than where each glyph
// sits. It plays keystrokes through a bash-readline-shaped remote over a link
// with per-key latency, presents a frame every 16.7 ms, and after every event
// composes the visible row: ghostty's grid with the overlay painted on top.
//
// The property it checks is the one a user notices: a character they deleted,
// and saw disappear, must not come back.

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
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RigKey::Character(byte) => write!(formatter, "{}", char::from(*byte)),
            RigKey::Backspace => write!(formatter, "⌫"),
            RigKey::KillLine => write!(formatter, "^U"),
            RigKey::KillWord => write!(formatter, "^W"),
            RigKey::Paste(bytes) => write!(formatter, "paste({})", String::from_utf8_lossy(bytes)),
        }
    }
}

impl RigKey {
    pub fn text(text: &str) -> Vec<RigKey> {
        text.bytes().map(RigKey::Character).collect()
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
                Self::erase_reply(count)
            }
            RigKey::KillWord => {
                let mut removed = 0;
                while self.line.last() == Some(&0x20) {
                    self.line.pop();
                    removed += 1;
                }
                while self.line.last().is_some_and(|&last| last != 0x20) {
                    self.line.pop();
                    removed += 1;
                }
                Self::erase_reply(removed)
            }
            RigKey::Paste(bytes) => {
                self.line.extend_from_slice(bytes);
                bytes.clone()
            }
        }
    }

    fn erase_reply(count: usize) -> Vec<u8> {
        if count == 0 {
            return Vec::new();
        }
        let mut reply = vec![0x08; count];
        reply.extend_from_slice(&[0x1B, 0x5B, 0x4B]);
        reply
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
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
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
enum RigEvent {
    Key(usize),
    /// The tee's copy reaches the engine (the main-actor drain).
    Output(Vec<u8>),
    /// Ghostty's parser applies the same bytes to the grid.
    Parse(Vec<u8>),
    Frame,
}

#[derive(Clone, Debug)]
struct ScheduledRigEvent {
    time: i64,
    order: usize,
    event: RigEvent,
}

const FRAME_INTERVAL: i64 = 16_667;

pub struct PredictionBreakRig {
    /// How long after the remote reply arrives Ghostty spends applying a read.
    /// Ghostty PR #242 moved the tee after the parser, so both events share
    /// the parser's completion time and the grid always receives the bytes
    /// before the host can drain them.
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
    remote: RigLineEditor,
    typed: Vec<u8>,
    events: Vec<ScheduledRigEvent>,
    order: usize,
    keystrokes: Vec<RigKeystroke>,
    /// Columns the user deleted and then saw blank.
    hidden_after_delete: HashSet<usize>,
    pub resurrections: Vec<RigFinding>,
    /// Microseconds during which some deleted-and-hidden column showed text.
    pub resurrected_micros: i64,
    last_visible_check: i64,
    resurrected_now: bool,
    last_visible: Vec<u8>,
    pub trace: Vec<String>,
    pub ever_drew_speculative: bool,

    /// What the user sees: the grid with the overlay painted over it.
    /// The last frame ghostty presented, and the overlay as the host last
    /// anchored it. Neither follows the grid between their own updates.
    presented_row: Vec<u8>,
    overlay: Vec<(i64, u8)>,
    is_tracking_frames: bool,
}

impl PredictionBreakRig {
    pub fn new(keystrokes: Vec<RigKeystroke>) -> Self {
        Self::with_configuration(keystrokes, PredictionConfiguration::default())
    }

    pub fn with_configuration(
        keystrokes: Vec<RigKeystroke>,
        configuration: PredictionConfiguration,
    ) -> Self {
        Self {
            parse_lag_micros: 0,
            wrong_text: Vec::new(),
            blanked_micros: 0,
            blanked_now: false,
            blankings: Vec::new(),
            engine: TerminalPredictionEngine::new(configuration, true, true),
            screen: SimulatedScreen::default(),
            remote: RigLineEditor::default(),
            typed: Vec::new(),
            events: Vec::new(),
            order: 0,
            keystrokes,
            hidden_after_delete: HashSet::new(),
            resurrections: Vec::new(),
            resurrected_micros: 0,
            last_visible_check: 0,
            resurrected_now: false,
            last_visible: Vec::new(),
            trace: Vec::new(),
            ever_drew_speculative: false,
            presented_row: SimulatedLineEditor::PROMPT.to_vec(),
            overlay: Vec::new(),
            is_tracking_frames: false,
        }
    }

    fn schedule(&mut self, event: RigEvent, time: i64) {
        self.events.push(ScheduledRigEvent { time, order: self.order, event });
        self.order += 1;
    }

    pub fn prompt_width() -> usize {
        SimulatedLineEditor::PROMPT.len()
    }

    pub fn visible_row(&self) -> Vec<u8> {
        let mut row = self.presented_row.clone();
        for &(column, byte) in &self.overlay {
            let Ok(column) = usize::try_from(column) else { continue };
            if row.len() <= column {
                row.resize(column + 1, 0x20);
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
            .map(|glyph| (cursor + i64::from(glyph.offset), glyph.character))
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
                while self.typed.last() == Some(&0x20) {
                    self.typed.pop();
                }
                while self.typed.last().is_some_and(|&last| last != 0x20) {
                    self.typed.pop();
                }
            }
            RigKey::Paste(bytes) => self.typed.extend_from_slice(bytes),
        }
    }

    fn check(&mut self, time: i64) {
        let visible = self.visible_row();
        let typed_end = Self::prompt_width() + self.typed.len();
        if self.resurrected_now {
            self.resurrected_micros += time - self.last_visible_check;
        }
        if self.blanked_now {
            self.blanked_micros += time - self.last_visible_check;
        }
        self.blanked_now = false;
        let prompt = SimulatedLineEditor::PROMPT;
        for (column, (&shown, &expected)) in visible.iter().zip(prompt).enumerate() {
            if shown != expected && self.wrong_text.len() < 20 {
                self.wrong_text.push(format!(
                    "{} ms: '{}' drawn over prompt column {column} ('{}')",
                    time / 1000,
                    char::from(shown),
                    char::from(expected)
                ));
            }
        }
        for (index, &expected) in self.typed.iter().enumerate() {
            let column = prompt.len() + index;
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
            .max(self.hidden_after_delete.iter().max().copied().unwrap_or_default() + 1);
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
                    let shown_after_prompt =
                        visible.get(Self::prompt_width()..).unwrap_or_default();
                    self.resurrections.push(RigFinding {
                        time,
                        column,
                        character: shown,
                        visible: String::from_utf8_lossy(shown_after_prompt).into_owned(),
                        typed: String::from_utf8_lossy(&self.typed).into_owned(),
                    });
                }
            }
        }
        self.last_visible = visible;
        if self.engine.glyphs().iter().any(|glyph| glyph.standing == Standing::Speculative) {
            self.ever_drew_speculative = true;
        }
    }

    fn describe_glyphs(&self) -> String {
        let glyphs: Vec<String> = self
            .engine
            .glyphs()
            .iter()
            .map(|glyph| format!("{}@{}", char::from(glyph.character), glyph.offset))
            .collect();
        format!("{glyphs:?}")
    }

    pub fn run(&mut self) {
        let mut read_at = 0;
        let mut replied_at = 0;
        let mut remote_model = RigLineEditor::default();
        let keystrokes = self.keystrokes.clone();
        for (index, keystroke) in keystrokes.iter().enumerate() {
            self.schedule(RigEvent::Key(index), keystroke.at);
            read_at = i64::max(read_at, keystroke.at + keystroke.uplink);
            let reply = remote_model.read(&keystroke.key);
            replied_at = i64::max(replied_at, read_at + keystroke.downlink);
            if !reply.is_empty() {
                let parser_finished_at = replied_at + self.parse_lag_micros;
                self.schedule(RigEvent::Parse(reply.clone()), parser_finished_at);
                self.schedule(RigEvent::Output(reply), parser_finished_at);
            }
        }
        self.remote = remote_model;
        let end = self.events.iter().map(|event| event.time).max().unwrap_or_default() + 2_000_000;
        let mut frame_time = FRAME_INTERVAL;
        while frame_time < end {
            self.schedule(RigEvent::Frame, frame_time);
            frame_time += FRAME_INTERVAL;
        }
        self.events.sort_by_key(|event| (event.time, event.order));
        let events = std::mem::take(&mut self.events);
        for scheduled in events {
            let time = scheduled.time;
            let now = micros(time);
            match scheduled.event {
                RigEvent::Key(index) => {
                    let key = self.keystrokes[index].key.clone();
                    self.apply_typed(&key);
                    let changed = match key {
                        RigKey::Character(byte) => self.engine.typed(Some(byte), now),
                        RigKey::Backspace => self.engine.typed_backspace(now),
                        RigKey::KillLine | RigKey::KillWord => self.engine.typed_line_erase(now),
                        RigKey::Paste(_) => self.engine.sent_untracked_input(now),
                    };
                    if changed {
                        self.sync();
                    }
                    let overlay = self.describe_glyphs();
                    self.trace.push(format!("{}ms type {key} -> overlay {overlay}", time / 1000));
                }
                RigEvent::Parse(bytes) => {
                    self.screen.apply(&bytes);
                    self.trace.push(format!(
                        "{}ms parse {}B cursor {}",
                        time / 1000,
                        bytes.len(),
                        self.screen.cursor
                    ));
                }
                RigEvent::Output(bytes) => {
                    if self.engine.observed_output(&bytes, now)
                        && !self.engine.holds_layout_until_frame()
                    {
                        self.sync();
                    }
                    let overlay = self.describe_glyphs();
                    self.trace.push(format!(
                        "{}ms echo {}B -> overlay {overlay}",
                        time / 1000,
                        bytes.len()
                    ));
                }
                RigEvent::Frame => {
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
#[derive(Clone, Debug)]
pub struct RigScript {
    pub keystrokes: Vec<RigKeystroke>,
    pub clock: i64,
    pub round_trip: i64,
    pub jitter: i64,
    pub random: SimulationRandom,
}

impl RigScript {
    pub fn new(round_trip_milliseconds: i64) -> Self {
        Self::with_jitter(round_trip_milliseconds, 0, 1)
    }

    pub fn with_jitter(round_trip_milliseconds: i64, jitter_milliseconds: i64, seed: u64) -> Self {
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

    /// Presses a key 30 ms after the previous one.
    pub fn press(&mut self, key: RigKey) {
        self.press_after(key, 30);
    }

    pub fn press_after(&mut self, key: RigKey, gap_milliseconds: i64) {
        self.clock += gap_milliseconds * 1000;
        let jitter = self.jitter;
        let trip =
            self.round_trip + if jitter > 0 { self.random.int_in(-jitter..=jitter) } else { 0 };
        let uplink = (trip / 2).max(1);
        self.keystrokes.push(RigKeystroke {
            key,
            at: self.clock,
            uplink,
            downlink: (trip - uplink).max(1),
        });
    }

    /// Types `text` at 30 ms a key.
    pub fn type_text(&mut self, text: &str) {
        self.type_text_after(text, 30);
    }

    pub fn type_text_after(&mut self, text: &str, gap_milliseconds: i64) {
        for key in RigKey::text(text) {
            self.press_after(key, gap_milliseconds);
        }
    }

    /// Holds a key at a 33 ms autorepeat.
    pub fn hold(&mut self, key: RigKey, count: usize, initial_delay_milliseconds: i64) {
        self.hold_repeating(key, count, initial_delay_milliseconds, 33);
    }

    pub fn hold_repeating(
        &mut self,
        key: RigKey,
        count: usize,
        initial_delay_milliseconds: i64,
        repeat_milliseconds: i64,
    ) {
        for index in 0..count {
            let gap = if index == 0 { initial_delay_milliseconds } else { repeat_milliseconds };
            self.press_after(key.clone(), gap);
        }
    }

    /// Two echoed keystrokes so the run is armed, then a pause. (One is not
    /// enough: a tty in cooked mode echoes the first key typed ahead of a
    /// password prompt.)
    pub fn arm(&mut self) {
        self.type_text_after("l", 10);
        self.wait(1_000);
        self.type_text_after("s", 10);
        self.wait(1_000);
    }
}
