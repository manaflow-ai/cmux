//! A randomized, seeded simulation of the whole prediction loop: a user
//! typing and backspacing, a link with latency, a remote line editor echoing
//! like bash readline, ghostty's parser and renderer, and the host that
//! drains output and re-anchors the overlay. After every event it checks that
//! each glyph the overlay draws lands on the cell its character actually
//! occupies.

use super::random::SimulationRandom;
use super::screen::{SimulatedEraseForm, SimulatedKey, SimulatedLineEditor, SimulatedScreen};
use super::us;
use cmux_terminal_prediction::{PredictedGlyph, Standing, TerminalPredictionEngine};
use std::fmt;

/// One keystroke and every random choice that follows from it, so a case
/// shrinks by deleting keystrokes without disturbing the others' timing.
#[derive(Clone, Copy, Debug)]
pub struct SimulatedKeystroke {
    pub key: SimulatedKey,
    /// Microseconds after the previous keystroke.
    pub gap: i64,
    /// Keystroke to remote, and remote output back, in microseconds.
    pub uplink: i64,
    pub downlink: i64,
    /// Seeds the read boundaries of this keystroke's echo and the host's
    /// drain and render delays after each read.
    pub jitter_seed: u64,
}

/// Shorthand for the pinned regression literals.
pub fn ks(key: SimulatedKey, gap: i64, uplink: i64, downlink: i64, jitter_seed: u64) -> SimulatedKeystroke {
    SimulatedKeystroke { key, gap, uplink, downlink, jitter_seed }
}

#[derive(Clone, Debug)]
pub struct SimulationCase {
    pub keystrokes: Vec<SimulatedKeystroke>,
    pub erase_form: SimulatedEraseForm,
    /// Readline and zle skip redisplay while more input is pending, so keys
    /// that reach the remote together come back as one redraw of the net
    /// change: back to where the lines diverge, the new tail, then `CSI K`
    /// if the line got shorter. A typo and its erase can echo nothing.
    pub coalesces_typeahead: bool,
}

#[derive(Clone, Debug)]
pub struct SimulationFailure {
    pub message: String,
    pub trace: Vec<String>,
}

impl fmt::Display for SimulationFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", std::iter::once(&self.message).chain(&self.trace).cloned().collect::<Vec<_>>().join("\n"))
    }
}

#[derive(Clone, Debug)]
enum Event {
    Keystroke(usize),
    /// A read from the PTY: the tee and ghostty's parser see it at once.
    Read { bytes: Vec<u8>, drain_delay: i64, render_delay: i64 },
    /// The main thread drains the tee's inbox into the engine.
    Drain,
    /// A rendered frame reaches the main thread.
    Frame,
}

struct Scheduled {
    time: i64,
    order: usize,
    event: Event,
}

#[derive(Clone, Copy)]
struct DrawnGlyph {
    column: i64,
    character: char,
    standing: Standing,
}

struct SettledBlank {
    column: i64,
    seen_by_engine: bool,
    writes: usize,
    message: String,
    trace_count: usize,
}

/// Plays one case through the engine and a model of the host around it.
pub struct PredictionSimulation {
    simulation_case: SimulationCase,
    engine: TerminalPredictionEngine,
    queue: Vec<Scheduled>,
    order: usize,
    screen: SimulatedScreen,
    /// The screen as far as the engine has read it.
    screen_seen_by_engine: SimulatedScreen,
    /// What the remote will show once every key typed so far is echoed.
    intended: SimulatedLineEditor,
    inbox: Vec<(i64, Vec<u8>)>,
    is_drain_scheduled: bool,
    is_frame_scheduled: bool,
    /// Presented-frame delivery, on only while the overlay holds glyphs.
    is_tracking_frames: bool,
    expiry_task: Option<i64>,
    /// What the overlay shows, anchored at the cursor when it last synced.
    overlay: Vec<DrawnGlyph>,
    pub trace: Vec<String>,
    /// Blanks drawn over text already where it belongs. Fine while the remote
    /// has yet to rewrite that cell (the user deleted the text and typed the
    /// same character again); a failure if nothing ever touches it again.
    blanks_over_settled_text: Vec<SettledBlank>,
    /// Events after which the overlay drew a speculative glyph, so a pass
    /// cannot come from a simulation that never predicts.
    pub predicted_events: usize,
}

fn describe_bytes(bytes: &[u8]) -> String {
    let inner: String = bytes
        .iter()
        .map(|&byte| match byte {
            0x08 => "\\b".to_string(),
            0x07 => "\\a".to_string(),
            0x1B => "\\e".to_string(),
            _ => char::from(byte).to_string(),
        })
        .collect();
    format!("\"{inner}\"")
}

fn describe_overlay(overlay: &[DrawnGlyph]) -> String {
    overlay
        .iter()
        .map(|g| format!("{}@{}{}", g.character, g.column, if g.standing == Standing::Confirmed { "✓" } else { "" }))
        .collect::<Vec<_>>()
        .join(" ")
}

fn describe_glyphs(glyphs: &[PredictedGlyph]) -> String {
    format!("{:?}", glyphs.iter().map(|g| format!("{}@{}", g.character, g.offset)).collect::<Vec<_>>())
}

impl PredictionSimulation {
    pub fn new(simulation_case: SimulationCase) -> Self {
        Self {
            simulation_case,
            engine: TerminalPredictionEngine::new(Default::default(), true, true),
            queue: Vec::new(),
            order: 0,
            screen: SimulatedScreen::default(),
            screen_seen_by_engine: SimulatedScreen::default(),
            intended: SimulatedLineEditor::default(),
            inbox: Vec::new(),
            is_drain_scheduled: false,
            is_frame_scheduled: false,
            is_tracking_frames: false,
            expiry_task: None,
            overlay: Vec::new(),
            trace: Vec::new(),
            blanks_over_settled_text: Vec::new(),
            predicted_events: 0,
        }
    }

    fn schedule(&mut self, event: Event, time: i64) {
        self.queue.push(Scheduled { time, order: self.order, event });
        self.order += 1;
    }

    /// Lays out the keystrokes and the remote's replies. The remote reads in
    /// order and the link preserves order, so both are fixed in advance.
    fn schedule_inputs(&mut self) {
        let mut remote = SimulatedLineEditor::default();
        let mut typed_at = 0;
        let mut read_at = 0;
        let mut replied_at = 0;
        // Keys reaching the remote within this of the first in a group are
        // pending when it would redisplay, when it coalesces at all.
        let typeahead_window = 10_000;
        let mut group_start: Option<i64> = None;
        let mut group_keys: Vec<SimulatedKey> = Vec::new();
        let mut group_downlink = 0;
        let mut group_jitter = 0;
        let mut arrivals: Vec<i64> = Vec::new();
        let mut read_cursor = 0;
        let keystrokes = self.simulation_case.keystrokes.clone();
        for (index, keystroke) in keystrokes.iter().enumerate() {
            typed_at += keystroke.gap;
            self.schedule(Event::Keystroke(index), typed_at);
            read_cursor = read_cursor.max(typed_at + keystroke.uplink);
            arrivals.push(read_cursor);
        }
        if self.simulation_case.coalesces_typeahead {
            let mut flush = |this: &mut Self,
                             group_start: &mut Option<i64>,
                             group_keys: &mut Vec<SimulatedKey>,
                             group_downlink: i64,
                             group_jitter: u64| {
                let Some(start) = *group_start else { return };
                if group_keys.is_empty() {
                    return;
                }
                let reply = remote.read_together(group_keys);
                replied_at = replied_at.max(start + typeahead_window + group_downlink);
                this.schedule_reply(&reply, &mut replied_at, group_jitter);
                *group_start = None;
                group_keys.clear();
            };
            for (index, keystroke) in keystrokes.iter().enumerate() {
                let arrival = arrivals[index];
                if group_start.is_some_and(|start| arrival > start + typeahead_window) {
                    flush(self, &mut group_start, &mut group_keys, group_downlink, group_jitter);
                }
                if group_start.is_none() {
                    group_start = Some(arrival);
                    group_downlink = keystroke.downlink;
                    group_jitter = keystroke.jitter_seed;
                }
                group_keys.push(keystroke.key);
            }
            flush(self, &mut group_start, &mut group_keys, group_downlink, group_jitter);
            return;
        }
        for (index, keystroke) in keystrokes.iter().enumerate() {
            read_at = read_at.max(arrivals[index]);
            let reply = remote.read(keystroke.key, self.simulation_case.erase_form);
            replied_at = replied_at.max(read_at + keystroke.downlink);
            self.schedule_reply(&reply, &mut replied_at, keystroke.jitter_seed);
        }
    }

    /// Splits one reply into reads at random boundaries, starting at `time`.
    fn schedule_reply(&mut self, reply: &[u8], time: &mut i64, jitter_seed: u64) {
        let mut random = SimulationRandom::new(jitter_seed);
        let mut start = 0;
        while start < reply.len() {
            let length = random.int_in(1, (reply.len() - start) as i64) as usize;
            let drain_delay = random.int_in(0, 4_000);
            let render_delay = random.int_in(0, 8_000);
            self.schedule(
                Event::Read { bytes: reply[start..start + length].to_vec(), drain_delay, render_delay },
                *time,
            );
            start += length;
            *time += random.int_in(0, 3_000);
        }
    }

    pub fn run(&mut self) -> Option<SimulationFailure> {
        self.schedule_inputs();
        loop {
            let next = (0..self.queue.len()).min_by_key(|&i| (self.queue[i].time, self.queue[i].order));
            if let Some(deadline) = self.expiry_task {
                if next.is_none_or(|i| deadline < self.queue[i].time) {
                    self.expiry_task = None;
                    self.trace.push(format!("{deadline}µs expiry tick"));
                    if self.engine.tick(us(deadline)) {
                        self.sync(deadline);
                    }
                    self.reschedule_expiry(deadline);
                    if let Some(failure) = self.check(deadline) {
                        return Some(failure);
                    }
                    continue;
                }
            }
            let Some(next) = next else { return self.blank_that_hid_settled_text() };
            let scheduled = self.queue.remove(next);
            self.handle(scheduled.event, scheduled.time);
            self.reschedule_expiry(scheduled.time);
            if let Some(failure) = self.check(scheduled.time) {
                return Some(failure);
            }
        }
    }

    fn handle(&mut self, event: Event, time: i64) {
        let now = us(time);
        match event {
            Event::Keystroke(index) => {
                let key = self.simulation_case.keystrokes[index].key;
                let _ = self.intended.read(key, self.simulation_case.erase_form);
                let changed = match key {
                    SimulatedKey::Character(byte) => self.engine.typed_printable_ascii(Some(byte), now),
                    SimulatedKey::Backspace => self.engine.typed_backspace(now),
                };
                self.trace.push(format!("{time}µs type {key}{}", if changed { " (redraw)" } else { "" }));
                if changed {
                    self.sync(time);
                }
            }
            Event::Read { bytes, drain_delay, render_delay } => {
                self.screen.apply(&bytes);
                self.trace.push(format!("{time}µs read {} cursor={}", describe_bytes(&bytes), self.screen.cursor));
                self.inbox.push((time, bytes));
                if !self.is_drain_scheduled {
                    self.is_drain_scheduled = true;
                    self.schedule(Event::Drain, time + drain_delay);
                }
                if !self.is_frame_scheduled {
                    self.is_frame_scheduled = true;
                    self.schedule(Event::Frame, time + render_delay);
                }
            }
            Event::Drain => {
                self.is_drain_scheduled = false;
                let changed = self.drain_inbox();
                let held = self.engine.holds_layout_until_frame();
                self.trace.push(format!(
                    "{time}µs drain{}{}",
                    if changed { " (redraw)" } else { "" },
                    if held { " (held)" } else { "" }
                ));
                if changed && !held {
                    self.sync(time);
                }
            }
            Event::Frame => {
                self.is_frame_scheduled = false;
                if !self.is_tracking_frames {
                    return;
                }
                // The host drains what the parser already applied before it
                // retires and re-anchors, so the engine matches the grid.
                let _ = self.drain_inbox();
                let _ = self.engine.presented_frame(now);
                self.trace.push(format!("{time}µs frame"));
                self.sync(time);
            }
        }
    }

    fn drain_inbox(&mut self) -> bool {
        let mut changed = false;
        for (time, bytes) in std::mem::take(&mut self.inbox) {
            self.screen_seen_by_engine.apply(&bytes);
            changed = self.engine.observed_output(&bytes, us(time)) || changed;
        }
        changed
    }

    /// The host's `syncPredictionOverlay`: re-anchor on the live cursor.
    fn sync(&mut self, time: i64) {
        self.engine.tick(us(time));
        let glyphs = self.engine.glyphs();
        if glyphs.is_empty() {
            self.overlay.clear();
            self.is_tracking_frames = false;
            return;
        }
        self.is_tracking_frames = true;
        let cursor = self.screen.cursor;
        self.overlay = glyphs
            .iter()
            .map(|g| DrawnGlyph { column: cursor + i64::from(g.offset), character: g.character, standing: g.standing })
            .collect();
        self.trace.push(format!("    overlay {} at cursor {cursor}", describe_overlay(&self.overlay)));
        if self.overlay.iter().any(|g| g.standing == Standing::Speculative) {
            self.predicted_events += 1;
        }
    }

    fn reschedule_expiry(&mut self, time: i64) {
        let Some(deadline) = self.engine.next_expiry() else {
            self.expiry_task = None;
            return;
        };
        let micros = deadline.as_micros() as i64;
        // The host's timer fires after the deadline, never on it, and the
        // engine expires only what is strictly past it.
        self.expiry_task = Some(time.max(micros) + 1);
    }

    fn note_blank(&mut self, column: i64, seen_by_engine: bool, prefix: &str, glyphs: &str, cursor: i64) {
        let view = if seen_by_engine { &self.screen_seen_by_engine } else { &self.screen };
        let row = self.intended.row();
        if column < 0 || column as usize >= row.len() {
            return;
        }
        let Some(shown) = view.character(column) else { return };
        if shown != row[column as usize] || shown == 0x20 {
            return;
        }
        let writes = view.write_count(column);
        self.blanks_over_settled_text.push(SettledBlank {
            column,
            seen_by_engine,
            writes,
            message: format!(
                "{prefix}: blank drawn at column {column} hides '{}', which stays; glyphs {glyphs} cursor {cursor}",
                char::from(shown)
            ),
            trace_count: self.trace.len(),
        });
    }

    /// At the end of the run: a blank over settled text whose cell the remote
    /// never wrote again hid text the user was meant to see.
    fn blank_that_hid_settled_text(&self) -> Option<SimulationFailure> {
        self.blanks_over_settled_text.iter().find_map(|blank| {
            let view = if blank.seen_by_engine { &self.screen_seen_by_engine } else { &self.screen };
            (view.write_count(blank.column) == blank.writes).then(|| SimulationFailure {
                message: blank.message.clone(),
                trace: self.trace[..blank.trace_count].to_vec(),
            })
        })
    }

    fn check(&mut self, time: i64) -> Option<SimulationFailure> {
        // The engine against the output it has read: exact after every event.
        let glyphs = self.engine.glyphs();
        for glyph in &glyphs {
            let cursor = self.screen_seen_by_engine.cursor;
            let column = cursor + i64::from(glyph.offset);
            if glyph.standing == Standing::Erased {
                let prefix = format!("engine at {time}µs");
                self.note_blank(column, true, &prefix, &describe_glyphs(&glyphs), cursor);
                continue;
            }
            if let Some(problem) =
                self.misplacement(column, glyph.character, glyph.standing, &self.screen_seen_by_engine)
            {
                return Some(SimulationFailure {
                    message: format!(
                        "engine at {time}µs: {problem}; glyphs {} cursor {cursor}",
                        describe_glyphs(&glyphs)
                    ),
                    trace: self.trace.clone(),
                });
            }
        }
        // The overlay once the host has caught up with the parser: every read
        // drained and the frame after it presented.
        if self.is_drain_scheduled || self.is_frame_scheduled {
            return None;
        }
        let overlay = self.overlay.clone();
        for glyph in &overlay {
            if glyph.standing == Standing::Erased {
                let prefix = format!("overlay at {time}µs");
                let cursor = self.screen.cursor;
                self.note_blank(glyph.column, false, &prefix, &describe_overlay(&overlay), cursor);
                continue;
            }
            if let Some(problem) = self.misplacement(glyph.column, glyph.character, glyph.standing, &self.screen) {
                return Some(SimulationFailure {
                    message: format!(
                        "overlay at {time}µs: {problem}; overlay {} cursor {}",
                        describe_overlay(&overlay),
                        self.screen.cursor
                    ),
                    trace: self.trace.clone(),
                });
            }
        }
        None
    }

    fn misplacement(&self, column: i64, character: char, standing: Standing, screen: &SimulatedScreen) -> Option<String> {
        let byte = character.is_ascii().then_some(character as u8);
        let show = |b: Option<u8>| b.map_or("nothing".to_string(), |b| format!("'{}'", char::from(b)));
        match standing {
            Standing::Speculative => {
                // Where the remote will put it once every typed key is echoed.
                let row = self.intended.row();
                let landing = (column >= 0 && (column as usize) < row.len()).then(|| row[column as usize]);
                if landing != byte {
                    return Some(format!(
                        "speculative '{character}' drawn at column {column}, which will hold {}",
                        show(landing)
                    ));
                }
            }
            Standing::Confirmed => {
                if screen.character(column) != byte {
                    return Some(format!(
                        "confirmed '{character}' drawn at column {column}, which holds {}",
                        show(screen.character(column))
                    ));
                }
            }
            // Checked by `note_blank`: a blank may only hide a cell the remote
            // is about to clear or overwrite.
            Standing::Erased => {}
        }
        None
    }
}
