//! Predictive local echo for remote terminals, ported from classic cmux's
//! `CmuxTerminalPrediction` (PR #13967's design).
//!
//! - [`TerminalPredictionEngine`]: which typed characters may be drawn before
//!   the remote echoes them. Predictions are drawn in an overlay, never into
//!   the grid; only inside a confirmed echo run (a password prompt shows
//!   nothing); not under 25 ms measured echo latency, in the alternate screen,
//!   on bracketed paste, mouse reporting, cursor motion or erases, or for
//!   non-ASCII text. Editing keys, Return and chords withdraw; 4 visible
//!   withdrawals in 10 s suspend prediction for 30 s; a glyph the remote
//!   never echoes is withdrawn after 1.5 s (or three round trips).
//! - [`TerminalOutputScanner`]: classifies PTY output for the engine.
//! - [`PredictionOutputInbox`]: buffers output between the PTY reader thread
//!   and the thread that owns the engines.
//! - [`PredictionOverlayLayout`]: which glyphs fit on the cursor row.
//! - [`ffi`]: the C ABI the macOS app links through cmux-app-ffi
//!   (`include/cmux_terminal_prediction.h`).
//!
//! Nothing here reads a clock: every call takes the host's monotonic time
//! ([`PredictionInstant`]), so tests and the latency harness state exact
//! instants.

mod config;
mod engine;
pub mod ffi;
mod glyph;
mod inbox;
mod layout;
mod scanner;

pub use config::{PredictionConfiguration, PredictionInstant};
pub use engine::{Status, TerminalPredictionEngine};
pub use glyph::{PredictedGlyph, Standing};
pub use inbox::{PredictionOutputBatch, PredictionOutputInbox};
pub use layout::PredictionOverlayLayout;
pub use scanner::{TerminalOutputScanner, TerminalOutputSignal, TerminalOutputSkim};
