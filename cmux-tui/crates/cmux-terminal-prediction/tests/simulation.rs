//! Port of classic cmux's `TerminalPredictionSimulationTests.swift`.
//!
//! A randomized, seeded simulation of the whole prediction loop: a user typing
//! and backspacing, a link with latency, a remote line editor echoing like bash
//! readline, ghostty's parser and renderer, and the host that drains output
//! and re-anchors the overlay. After every event it checks that each glyph the
//! overlay draws lands on the cell its character actually occupies.

mod common;

use SimulatedKey::{Backspace, Character};
use cmux_terminal_prediction::{PredictionConfiguration, Standing, TerminalPredictionEngine};
use common::{
    SimulatedEraseForm, SimulatedKey, SimulatedLineEditor, SimulatedScreen, SimulationRandom,
    micros,
};
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::fmt;
use std::ops::RangeInclusive;

/// One keystroke and every random choice that follows from it, so a case
/// shrinks by deleting keystrokes without disturbing the others' timing.
#[derive(Clone, Copy, Debug)]
struct SimulatedKeystroke {
    key: SimulatedKey,
    /// Microseconds after the previous keystroke.
    gap: i64,
    /// Keystroke to remote, and remote output back, in microseconds.
    uplink: i64,
    downlink: i64,
    /// Seeds the read boundaries of this keystroke's echo and the host's
    /// drain and render delays after each read.
    jitter_seed: u64,
}

const fn keystroke(
    key: SimulatedKey,
    gap: i64,
    uplink: i64,
    downlink: i64,
    jitter_seed: u64,
) -> SimulatedKeystroke {
    SimulatedKeystroke { key, gap, uplink, downlink, jitter_seed }
}

#[derive(Clone, Debug)]
struct SimulationCase {
    keystrokes: Vec<SimulatedKeystroke>,
    erase_form: SimulatedEraseForm,
    /// Readline and zle skip redisplay while more input is pending, so keys
    /// that reach the remote together come back as one redraw of the net
    /// change: back to where the lines diverge, the new tail, then `CSI K`
    /// if the line got shorter. A typo and its erase can echo nothing.
    coalesces_typeahead: bool,
}

impl SimulationCase {
    fn new(keystrokes: Vec<SimulatedKeystroke>, erase_form: SimulatedEraseForm) -> Self {
        Self { keystrokes, erase_form, coalesces_typeahead: false }
    }
}

#[derive(Debug)]
struct SimulationFailure {
    message: String,
    trace: Vec<String>,
}

impl fmt::Display for SimulationFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)?;
        for line in &self.trace {
            write!(formatter, "\n{line}")?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
enum SimulationEvent {
    Keystroke(usize),
    /// A read from the PTY: the tee and ghostty's parser see it at once.
    Read {
        bytes: Vec<u8>,
        drain_delay: i64,
        render_delay: i64,
    },
    /// The main actor drains the tee's inbox into the engine.
    Drain,
    /// A rendered frame reaches the main actor.
    Frame,
}

#[derive(Clone, Copy, Debug)]
struct DrawnGlyph {
    column: i64,
    character: u8,
    standing: Standing,
}

/// A blank drawn over text already where it belongs.
#[derive(Clone, Debug)]
struct SettledBlank {
    column: i64,
    seen_by_engine: bool,
    writes: i64,
    message: String,
    trace_count: usize,
}

/// Keys that reach the remote within the typeahead window of the first.
struct TypeaheadGroup {
    start: i64,
    keys: Vec<SimulatedKey>,
    downlink: i64,
    jitter_seed: u64,
}

/// Keys reaching the remote within this of the first in a group are
/// pending when it would redisplay, when it coalesces at all.
const TYPEAHEAD_WINDOW: i64 = 10_000;

/// Plays one case through the engine and a model of the host around it.
struct PredictionSimulation {
    simulation_case: SimulationCase,
    engine: TerminalPredictionEngine,
    /// Pending events by `(time, order)`, earliest first; the events
    /// themselves sit in `scheduled`, indexed by `order`.
    queue: BinaryHeap<Reverse<(i64, usize)>>,
    scheduled: Vec<Option<SimulationEvent>>,
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
    trace: Vec<String>,
    /// Blanks drawn over text already where it belongs. Fine while the remote
    /// has yet to rewrite that cell (the user deleted the text and typed the
    /// same character again); a failure if nothing ever touches it again.
    blanks_over_settled_text: Vec<SettledBlank>,
    /// Events after which the overlay drew a speculative glyph, so a pass
    /// cannot come from a simulation that never predicts.
    predicted_events: usize,
}

impl PredictionSimulation {
    fn new(simulation_case: SimulationCase) -> Self {
        Self {
            simulation_case,
            engine: TerminalPredictionEngine::new(PredictionConfiguration::default(), true, true),
            queue: BinaryHeap::new(),
            scheduled: Vec::new(),
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

    fn schedule(&mut self, event: SimulationEvent, time: i64) {
        let order = self.scheduled.len();
        self.scheduled.push(Some(event));
        self.queue.push(Reverse((time, order)));
    }

    /// Lays out the keystrokes and the remote's replies. The remote reads in
    /// order and the link preserves order, so both are fixed in advance.
    fn schedule_inputs(&mut self) {
        let mut remote = SimulatedLineEditor::default();
        let mut typed_at = 0;
        let mut read_at = 0;
        let mut replied_at = 0;
        let keystrokes = self.simulation_case.keystrokes.clone();
        let mut arrivals = Vec::with_capacity(keystrokes.len());
        let mut read_cursor = 0;
        for (index, keystroke) in keystrokes.iter().enumerate() {
            typed_at += keystroke.gap;
            self.schedule(SimulationEvent::Keystroke(index), typed_at);
            read_cursor = i64::max(read_cursor, typed_at + keystroke.uplink);
            arrivals.push(read_cursor);
        }
        if self.simulation_case.coalesces_typeahead {
            let mut group: Option<TypeaheadGroup> = None;
            for (keystroke, &arrival) in keystrokes.iter().zip(&arrivals) {
                if let Some(full) = group.take_if(|group| arrival > group.start + TYPEAHEAD_WINDOW)
                {
                    self.flush_group(&mut remote, full, &mut replied_at);
                }
                group
                    .get_or_insert_with(|| TypeaheadGroup {
                        start: arrival,
                        keys: Vec::new(),
                        downlink: keystroke.downlink,
                        jitter_seed: keystroke.jitter_seed,
                    })
                    .keys
                    .push(keystroke.key);
            }
            if let Some(last) = group {
                self.flush_group(&mut remote, last, &mut replied_at);
            }
            return;
        }
        for (keystroke, &arrival) in keystrokes.iter().zip(&arrivals) {
            read_at = i64::max(read_at, arrival);
            let reply = remote.read(keystroke.key, self.simulation_case.erase_form);
            replied_at = i64::max(replied_at, read_at + keystroke.downlink);
            self.schedule_reply(&reply, &mut replied_at, keystroke.jitter_seed);
        }
    }

    fn flush_group(
        &mut self,
        remote: &mut SimulatedLineEditor,
        group: TypeaheadGroup,
        replied_at: &mut i64,
    ) {
        if group.keys.is_empty() {
            return;
        }
        let reply = remote.read_together(&group.keys);
        *replied_at = i64::max(*replied_at, group.start + TYPEAHEAD_WINDOW + group.downlink);
        self.schedule_reply(&reply, replied_at, group.jitter_seed);
    }

    /// Splits one reply into reads at random boundaries, starting at `time`.
    fn schedule_reply(&mut self, reply: &[u8], time: &mut i64, jitter_seed: u64) {
        let mut random = SimulationRandom::new(jitter_seed);
        let mut start = 0;
        while start < reply.len() {
            let length = random.int_in(1..=(reply.len() - start) as i64) as usize;
            let drain_delay = random.int_in(0..=4_000);
            let render_delay = random.int_in(0..=8_000);
            self.schedule(
                SimulationEvent::Read {
                    bytes: reply[start..start + length].to_vec(),
                    drain_delay,
                    render_delay,
                },
                *time,
            );
            start += length;
            *time += random.int_in(0..=3_000);
        }
    }

    fn run(&mut self) -> Option<SimulationFailure> {
        self.schedule_inputs();
        loop {
            let next_time = self.queue.peek().map(|&Reverse((time, _))| time);
            if let Some(deadline) = self.expiry_task
                && next_time.is_none_or(|time| deadline < time)
            {
                self.expiry_task = None;
                self.trace.push(format!("{deadline}µs expiry tick"));
                if self.engine.tick(micros(deadline)) {
                    self.sync(deadline);
                }
                self.reschedule_expiry(deadline);
                if let Some(failure) = self.check(deadline) {
                    return Some(failure);
                }
                continue;
            }
            let Some(Reverse((time, order))) = self.queue.pop() else {
                return self.blank_that_hid_settled_text();
            };
            let event = self.scheduled[order].take().expect("each event runs once");
            self.handle(event, time);
            self.reschedule_expiry(time);
            if let Some(failure) = self.check(time) {
                return Some(failure);
            }
        }
    }

    fn handle(&mut self, event: SimulationEvent, time: i64) {
        let now = micros(time);
        match event {
            SimulationEvent::Keystroke(index) => {
                let key = self.simulation_case.keystrokes[index].key;
                let _ = self.intended.read(key, self.simulation_case.erase_form);
                let changed = match key {
                    Character(byte) => self.engine.typed(Some(byte), now),
                    Backspace => self.engine.typed_backspace(now),
                };
                let redraw = if changed { " (redraw)" } else { "" };
                self.trace.push(format!("{time}µs type {key}{redraw}"));
                if changed {
                    self.sync(time);
                }
            }
            SimulationEvent::Read { bytes, drain_delay, render_delay } => {
                self.screen.apply(&bytes);
                self.trace.push(format!(
                    "{time}µs read {} cursor={}",
                    describe_bytes(&bytes),
                    self.screen.cursor
                ));
                self.inbox.push((time, bytes));
                if !self.is_drain_scheduled {
                    self.is_drain_scheduled = true;
                    self.schedule(SimulationEvent::Drain, time + drain_delay);
                }
                if !self.is_frame_scheduled {
                    self.is_frame_scheduled = true;
                    self.schedule(SimulationEvent::Frame, time + render_delay);
                }
            }
            SimulationEvent::Drain => {
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
            SimulationEvent::Frame => {
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
            changed = self.engine.observed_output(&bytes, micros(time)) || changed;
        }
        changed
    }

    /// The host's `syncPredictionOverlay`: re-anchor on the live cursor.
    fn sync(&mut self, time: i64) {
        self.engine.tick(micros(time));
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
            .map(|glyph| DrawnGlyph {
                column: cursor + i64::from(glyph.offset),
                character: glyph.character,
                standing: glyph.standing,
            })
            .collect();
        self.trace
            .push(format!("    overlay {} at cursor {cursor}", describe_overlay(&self.overlay)));
        if self.overlay.iter().any(|glyph| glyph.standing == Standing::Speculative) {
            self.predicted_events += 1;
        }
    }

    fn reschedule_expiry(&mut self, time: i64) {
        let Some(deadline) = self.engine.next_expiry() else {
            self.expiry_task = None;
            return;
        };
        let deadline_micros = deadline.as_micros() as i64;
        // The host's timer fires after the deadline, never on it, and the
        // engine expires only what is strictly past it.
        self.expiry_task = Some(i64::max(time, deadline_micros) + 1);
    }

    fn view(&self, seen_by_engine: bool) -> &SimulatedScreen {
        if seen_by_engine { &self.screen_seen_by_engine } else { &self.screen }
    }

    fn note_blank(
        &mut self,
        column: i64,
        seen_by_engine: bool,
        prefix: &str,
        glyphs: &str,
        cursor: i64,
    ) {
        let view = self.view(seen_by_engine);
        let row = self.intended.row();
        let Ok(index) = usize::try_from(column) else { return };
        let Some(&intended) = row.get(index) else { return };
        let Some(shown) = view.character(column) else { return };
        if shown != intended || shown == 0x20 {
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
            let view = self.view(blank.seen_by_engine);
            (view.write_count(blank.column) == blank.writes).then(|| SimulationFailure {
                message: blank.message.clone(),
                trace: self.trace[..blank.trace_count].to_vec(),
            })
        })
    }

    fn check(&mut self, time: i64) -> Option<SimulationFailure> {
        // The engine against the output it has read: exact after every event.
        let glyphs = self.engine.glyphs();
        let described: Vec<String> = glyphs
            .iter()
            .map(|glyph| format!("{}@{}", char::from(glyph.character), glyph.offset))
            .collect();
        let described = format!("{described:?}");
        let cursor = self.screen_seen_by_engine.cursor;
        for glyph in &glyphs {
            let column = cursor + i64::from(glyph.offset);
            if glyph.standing == Standing::Erased {
                self.note_blank(column, true, &format!("engine at {time}µs"), &described, cursor);
                continue;
            }
            if let Some(problem) = self.misplacement(column, glyph.character, glyph.standing, true)
            {
                return Some(SimulationFailure {
                    message: format!(
                        "engine at {time}µs: {problem}; glyphs {described} cursor {cursor}"
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
        let described = describe_overlay(&overlay);
        let cursor = self.screen.cursor;
        for glyph in &overlay {
            if glyph.standing == Standing::Erased {
                self.note_blank(
                    glyph.column,
                    false,
                    &format!("overlay at {time}µs"),
                    &described,
                    cursor,
                );
                continue;
            }
            if let Some(problem) =
                self.misplacement(glyph.column, glyph.character, glyph.standing, false)
            {
                return Some(SimulationFailure {
                    message: format!(
                        "overlay at {time}µs: {problem}; overlay {described} cursor {cursor}"
                    ),
                    trace: self.trace.clone(),
                });
            }
        }
        None
    }

    fn misplacement(
        &self,
        column: i64,
        character: u8,
        standing: Standing,
        seen_by_engine: bool,
    ) -> Option<String> {
        let shown = char::from(character);
        match standing {
            Standing::Speculative => {
                // Where the remote will put it once every typed key is echoed.
                let row = self.intended.row();
                let landing =
                    usize::try_from(column).ok().and_then(|index| row.get(index).copied());
                if landing != Some(character) {
                    let holds = landing.map_or_else(
                        || "nothing".to_owned(),
                        |byte| format!("'{}'", char::from(byte)),
                    );
                    return Some(format!(
                        "speculative '{shown}' drawn at column {column}, which will hold {holds}"
                    ));
                }
            }
            Standing::Confirmed => {
                let actual = self.view(seen_by_engine).character(column);
                if actual != Some(character) {
                    let holds = actual.map_or_else(
                        || "nothing".to_owned(),
                        |byte| format!("'{}'", char::from(byte)),
                    );
                    return Some(format!(
                        "confirmed '{shown}' drawn at column {column}, which holds {holds}"
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

fn describe_bytes(bytes: &[u8]) -> String {
    let mut described = String::from("\"");
    for &byte in bytes {
        match byte {
            0x08 => described.push_str("\\b"),
            0x07 => described.push_str("\\a"),
            0x1B => described.push_str("\\e"),
            _ => described.push(char::from(byte)),
        }
    }
    described.push('"');
    described
}

fn describe_overlay(overlay: &[DrawnGlyph]) -> String {
    overlay
        .iter()
        .map(|glyph| {
            let confirmed = if glyph.standing == Standing::Confirmed { "✓" } else { "" };
            format!("{}@{}{confirmed}", char::from(glyph.character), glyph.column)
        })
        .collect::<Vec<_>>()
        .join(" ")
}

// Simulation cases

const ALPHABET: &[u8] = b"asdfjo";

/// Adds keystrokes with a per-key round trip drawn around `round_trip`.
struct CaseBuilder {
    random: SimulationRandom,
    keystrokes: Vec<SimulatedKeystroke>,
    round_trip: i64,
    trip_percent: RangeInclusive<i64>,
    uplink_percent: RangeInclusive<i64>,
}

impl CaseBuilder {
    fn add(&mut self, key: SimulatedKey, gap: i64) {
        let trip = self.round_trip * self.random.int_in(self.trip_percent.clone()) / 100;
        let uplink = trip * self.random.int_in(self.uplink_percent.clone()) / 100;
        let jitter_seed = self.random.next_u64();
        self.keystrokes.push(keystroke(key, gap, uplink, trip - uplink, jitter_seed));
    }

    fn character(&mut self) -> SimulatedKey {
        Character(self.random.element(ALPHABET))
    }
}

fn make(seed: u64) -> SimulationCase {
    let mut random = SimulationRandom::new(seed);
    // Both sides of the 25 ms engage threshold.
    let round_trip = random.element(&[3_000, 12_000, 30_000, 50_000, 70_000, 120_000, 250_000]);
    let mut builder = CaseBuilder {
        random,
        keystrokes: Vec::new(),
        round_trip,
        trip_percent: 60..=140,
        uplink_percent: 30..=70,
    };

    let length = builder.random.int_in(4..=60) as usize;
    while builder.keystrokes.len() < length {
        match builder.random.int_in(0..=9) {
            0..=3 => {
                for _ in 0..builder.random.int_in(1..=8) {
                    let key = builder.character();
                    let gap = builder.random.int_in(15_000..=180_000);
                    builder.add(key, gap);
                }
            }
            4..=5 => {
                for _ in 0..builder.random.int_in(1..=6) {
                    let gap = builder.random.int_in(30_000..=160_000);
                    builder.add(Backspace, gap);
                }
            }
            6 => {
                // A held key: the initial delay, then autorepeat.
                let key = if builder.random.bool() { Backspace } else { builder.character() };
                let gap = builder.random.int_in(20_000..=200_000);
                builder.add(key, gap);
                for _ in 0..builder.random.int_in(2..=12) {
                    builder.add(key, 33_000);
                }
            }
            7 => {
                let key = builder.character();
                let gap = builder.random.int_in(300_000..=2_500_000);
                builder.add(key, gap);
            }
            _ => {
                // A typo corrected at typing speed.
                let key = builder.character();
                let gap = builder.random.int_in(30_000..=120_000);
                builder.add(key, gap);
                let gap = builder.random.int_in(40_000..=140_000);
                builder.add(Backspace, gap);
            }
        }
    }
    let erase_form = builder.random.element(&SimulatedEraseForm::ALL);
    SimulationCase::new(builder.keystrokes, erase_form)
}

/// The dogfood report: a fast burst, then Backspace mashed or held at
/// key-repeat speed, over a link slow enough to predict. Sometimes the
/// Backspaces run past the burst into the prompt, where bash rings the
/// bell, and sometimes they start after part of the burst was echoed.
fn make_burst_then_delete(seed: u64) -> SimulationCase {
    let mut random = SimulationRandom::new(seed);
    let round_trip = random.int_in(30_000..=250_000);
    let mut builder = CaseBuilder {
        random,
        keystrokes: Vec::new(),
        round_trip,
        trip_percent: 80..=120,
        uplink_percent: 40..=60,
    };

    // Two keys echoed one at a time first: the run arms only after two
    // echoes in a row, and this case is about what happens once it has.
    for _ in 0..2 {
        let key = builder.character();
        builder.add(key, round_trip * 3);
    }
    for _ in 0..builder.random.int_in(1..=3) {
        let burst = builder.random.int_in(1..=12);
        for _ in 0..burst {
            let key = builder.character();
            let gap = builder.random.int_in(15_000..=70_000);
            builder.add(key, gap);
        }
        let pause = if builder.random.bool() {
            builder.random.int_in(20_000..=60_000)
        } else {
            builder.random.int_in(100_000..=600_000)
        };
        let deletes = i64::max(1, burst + builder.random.int_in(-3..=3));
        for index in 0..deletes {
            let gap = if index == 0 { pause } else { builder.random.int_in(28_000..=40_000) };
            builder.add(Backspace, gap);
        }
        let key = builder.character();
        let gap = builder.random.int_in(50_000..=900_000);
        builder.add(key, gap);
    }
    let erase_form = if builder.random.int_below(4) == 0 {
        builder.random.element(&SimulatedEraseForm::ALL)
    } else {
        SimulatedEraseForm::BackspaceClearToEnd
    };
    SimulationCase::new(builder.keystrokes, erase_form)
}

/// Runs the seeds and reports the first failure, shrunk, with the case
/// as a literal to pin as a regression.
fn first_failure(
    seeds: RangeInclusive<u64>,
    make: impl Fn(u64) -> SimulationCase,
) -> Option<String> {
    for seed in seeds {
        let simulation_case = make(seed);
        if PredictionSimulation::new(simulation_case.clone()).run().is_none() {
            continue;
        }
        let (minimal, failure) = shrink(simulation_case);
        return Some(format!("seed {seed}\n{}\n{failure}", literal(&minimal)));
    }
    None
}

fn literal(simulation_case: &SimulationCase) -> String {
    let keystrokes: Vec<String> = simulation_case
        .keystrokes
        .iter()
        .map(|keystroke| {
            let key = match keystroke.key {
                Character(byte) => format!("Character(b'{}')", char::from(byte)),
                Backspace => "Backspace".to_owned(),
            };
            format!(
                "    keystroke({key}, {}, {}, {}, {}),",
                keystroke.gap, keystroke.uplink, keystroke.downlink, keystroke.jitter_seed
            )
        })
        .collect();
    format!(
        "SimulationCase::new(vec![\n{}\n], {:?})",
        keystrokes.join("\n"),
        simulation_case.erase_form
    )
}

/// Deletes keystrokes while the case still fails, for a readable trace.
fn shrink(failing: SimulationCase) -> (SimulationCase, SimulationFailure) {
    let mut current = failing;
    let mut failure =
        PredictionSimulation::new(current.clone()).run().expect("shrinking a failing case");
    let mut progress = true;
    while progress {
        progress = false;
        let mut index = 0;
        while index < current.keystrokes.len() {
            let mut candidate = current.clone();
            let removed = candidate.keystrokes.remove(index);
            if let Some(next) = candidate.keystrokes.get_mut(index) {
                next.gap += removed.gap;
            }
            if let Some(smaller) = PredictionSimulation::new(candidate.clone()).run() {
                current = candidate;
                failure = smaller;
                progress = true;
            } else {
                index += 1;
            }
        }
    }
    (current, failure)
}

#[test]
fn every_drawn_glyph_lands_where_its_character_will() {
    if let Some(failure) = first_failure(1..=4_000, make) {
        panic!("{failure}");
    }
}

#[test]
fn a_burst_then_mashed_backspace_keeps_every_glyph_on_its_cell() {
    if let Some(failure) = first_failure(1..=4_000, make_burst_then_delete) {
        panic!("{failure}");
    }
}

#[test]
fn a_remote_that_coalesces_typeahead_keeps_every_glyph_on_its_cell() {
    let mut failures = Vec::new();
    for make in [make as fn(u64) -> SimulationCase, make_burst_then_delete] {
        let coalescing = |seed| {
            let mut simulation_case = make(seed);
            simulation_case.coalesces_typeahead = true;
            simulation_case
        };
        if let Some(failure) = first_failure(1..=4_000, coalescing) {
            failures.push(failure);
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

#[test]
fn the_simulation_actually_predicts() {
    let mut predicting = 0;
    for seed in 1..=200 {
        let mut simulation = PredictionSimulation::new(make_burst_then_delete(seed));
        let _ = simulation.run();
        if simulation.predicted_events > 0 {
            predicting += 1;
        }
    }
    assert!(predicting > 150, "only {predicting} of 200 cases ever predicted");
}

fn expect_passes(simulation_case: SimulationCase) {
    if let Some(failure) = PredictionSimulation::new(simulation_case).run() {
        panic!("{failure}");
    }
}

/// Minimal trace behind the dogfood report of a burst's own glyph drawn
/// cells right of the cursor. "d" and "f" go out before any echo, so
/// neither is drawn; "a" is. Ghostty parses the echo of "f" and renders a
/// frame before the engine drains it, so the overlay re-anchors on the
/// advanced cursor with the old offsets. Draining the echo of an undrawn
/// keystroke changed nothing drawn, so nothing asked for a redraw, and
/// "a" stayed one cell right per such echo until the next frame.
#[test]
fn an_undrawn_echo_still_reanchors_the_overlay() {
    expect_passes(SimulationCase::new(
        vec![
            keystroke(Character(b'd'), 39435, 99559, 72095, 9648886400068060533),
            keystroke(Character(b'f'), 97648, 70486, 62507, 15040563541741120241),
            keystroke(Character(b'a'), 94418, 62630, 62631, 13166747327335888811),
        ],
        SimulatedEraseForm::CursorLeftDeleteCharacter,
    ));
}

/// Backspace on an empty line withdraws. The engine then dropped every
/// keystroke in flight, so the echo of the first "d" was matched to the
/// second, arming a run one cell behind the remote, and "a" was drawn
/// where the second "d" lands.
#[test]
fn echoes_of_dropped_keystrokes_do_not_arm_a_new_run() {
    expect_passes(SimulationCase::new(
        vec![
            keystroke(Backspace, 2307225, 181125, 81375, 15060688257749113825),
            keystroke(Character(b's'), 93828, 90200, 129800, 12550267593603473558),
            keystroke(Character(b'd'), 173569, 106750, 68250, 4262448622762034288),
            keystroke(Character(b'd'), 109962, 112500, 112500, 10403133260724467383),
            keystroke(Character(b'a'), 125999, 98175, 94325, 16371842306727156016),
        ],
        SimulatedEraseForm::CursorLeftDeleteCharacter,
    ));
}

/// The same misalignment from Backspace over echoed text followed by
/// fast typing, over bash's `\b\e[K`.
#[test]
fn backspace_over_echoed_text_then_typing_stays_aligned() {
    expect_passes(SimulationCase::new(
        vec![
            keystroke(Character(b's'), 464991, 82596, 59812, 12520115931017865071),
            keystroke(Backspace, 518660, 54152, 52030, 16642402136693730543),
            keystroke(Character(b'a'), 91549, 59624, 79037, 15997237259192702023),
            keystroke(Character(b'j'), 117581, 61385, 84771, 9661113692231963010),
            keystroke(Character(b's'), 73487, 56663, 44522, 11641246956492036942),
            keystroke(Character(b's'), 88214, 56214, 68706, 2456294479701936419),
            keystroke(Character(b'a'), 103111, 64083, 78325, 16277613484114632174),
        ],
        SimulatedEraseForm::BackspaceClearToEnd,
    ));
}

/// Backspace over the echoed "f" withdraws, and a remote that coalesces
/// typeahead sends nothing for "⌫f", whose net change is none. The echo
/// of the second "f" arrived after the untracked window and was matched
/// to the first, re-arming one cell behind the remote, so "d" was drawn
/// right of where it lands and stayed there until it expired.
#[test]
fn a_key_typed_while_echoes_are_untracked_does_not_arm_a_run() {
    let mut simulation_case = SimulationCase::new(
        vec![
            keystroke(Character(b'f'), 245673, 30870, 42630, 2300655970432197423),
            keystroke(Backspace, 139067, 47124, 24276, 13452741299809415594),
            keystroke(Character(b'f'), 17750, 20384, 43316, 14211843459011219229),
            keystroke(Character(b'f'), 116774, 52542, 44758, 5850673420601723284),
            keystroke(Character(b'd'), 909700, 28980, 13020, 16764482466942078549),
        ],
        SimulatedEraseForm::BackspaceClearToEnd,
    );
    simulation_case.coalesces_typeahead = true;
    expect_passes(simulation_case);
}

/// The link measures fast mid-run, so "j" is typed undrawn behind a held
/// "s". Removing "j" at its echo dropped a cell the cursor had passed,
/// and the held "s" slid onto the cell after it.
#[test]
fn a_held_glyph_keeps_its_cell_when_an_undrawn_echo_follows() {
    expect_passes(SimulationCase::new(
        vec![
            keystroke(Character(b's'), 57475, 13398, 9702, 13857595088430517430),
            keystroke(Character(b'j'), 666034, 16638, 18762, 8691134027776269367),
            keystroke(Character(b'a'), 329636, 19323, 14577, 4221019582071791041),
            keystroke(Character(b's'), 6539567, 9792, 10608, 1270321287885520511),
            keystroke(Character(b's'), 18044, 8118, 11682, 17235541091325165141),
            keystroke(Character(b'j'), 60004, 9936, 11664, 5103199448813725791),
        ],
        SimulatedEraseForm::CursorLeftDeleteCharacter,
    ));
}

/// Backspace at the prompt withdraws, and "s" goes out right behind it,
/// untracked. The two "s" typed later are tracked, so the untracked "s"
/// echoed first and was taken for the first tracked one: the window closed
/// a key early and "o" was drawn where the last "s" lands. Output that fits
/// both an untracked key and the next tracked one now withdraws.
#[test]
fn an_untracked_echo_like_the_next_tracked_key_does_not_close_the_window() {
    let case = SimulationCase::new(
        vec![
            keystroke(Backspace, 132692, 94875, 192625, 18239813732381436499),
            keystroke(Character(b's'), 30569, 183600, 156400, 3222175671410532008),
            keystroke(Character(b's'), 137770, 106425, 141075, 7567831139240784298),
            keystroke(Character(b's'), 35418, 146625, 140875, 4984424437519692256),
            keystroke(Character(b'o'), 270461, 136500, 58500, 13820163519234489272),
        ],
        SimulatedEraseForm::CursorLeftDeleteCharacter,
    );
    expect_passes(case.clone());
    let mut coalescing = case;
    coalescing.coalesces_typeahead = true;
    expect_passes(coalescing);
}
