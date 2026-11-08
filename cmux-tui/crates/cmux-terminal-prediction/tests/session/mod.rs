//! Drives the engine the way the host does: keystrokes in, PTY bytes back.
//! Shared by tests/engine.rs and tests/engine_backspace.rs.

#![allow(dead_code)]

use cmux_terminal_prediction::{PredictionConfiguration, Standing, TerminalPredictionEngine};
use std::time::Duration;

pub fn ms(milliseconds: u64) -> Duration {
    Duration::from_millis(milliseconds)
}

pub struct Session {
    pub engine: TerminalPredictionEngine,
    pub clock: Duration,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            engine: TerminalPredictionEngine::new(PredictionConfiguration::DEFAULT, true, true),
            clock: Duration::ZERO,
        }
    }
}

impl Session {
    pub fn advance(&mut self, step: Duration) {
        self.clock += step;
    }

    /// Types `text` 10 ms after the last event.
    pub fn r#type(&mut self, text: &str) {
        self.type_after(text, ms(10));
    }

    pub fn type_after(&mut self, text: &str, step: Duration) {
        self.advance(step);
        self.engine.typed(text.as_bytes(), self.clock);
    }

    /// The remote's output, 70 ms after the last event.
    pub fn remote(&mut self, text: &str) {
        self.remote_after(text, ms(70));
    }

    pub fn remote_after(&mut self, text: &str, step: Duration) {
        self.advance(step);
        self.engine.observed_output(text.as_bytes(), self.clock);
    }

    /// The characters drawn, without the blanks over deleted cells.
    pub fn drawn(&self) -> String {
        self.engine.glyphs().iter().filter(|g| g.standing != Standing::Erased).map(|g| g.character).collect()
    }

    /// Offsets of the cells drawn blank because the user deleted them.
    pub fn blanks(&self) -> Vec<i32> {
        self.engine.glyphs().iter().filter(|g| g.standing == Standing::Erased).map(|g| g.offset).collect()
    }

    pub fn live_offsets(&self) -> Vec<i32> {
        self.engine.glyphs().iter().filter(|g| g.standing != Standing::Erased).map(|g| g.offset).collect()
    }

    pub fn standings(&self) -> Vec<Standing> {
        self.engine.glyphs().iter().map(|g| g.standing).collect()
    }

    pub fn present_frame(&mut self) -> bool {
        self.engine.presented_frame(self.clock)
    }

    pub fn tick(&mut self) -> bool {
        self.engine.tick(self.clock)
    }
}

/// Reaches the state where the engine is willing to draw: two echoed
/// characters over a link slow enough to be worth predicting.
pub fn armed_session() -> Session {
    let mut session = Session::default();
    session.r#type("l");
    session.remote("l");
    session.r#type("s");
    session.remote("s");
    session.present_frame();
    session
}
