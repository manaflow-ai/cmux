//! Predictive local echo for a terminal whose shell runs on another machine: a
//! Cloud VM or an SSH host, where every key would otherwise wait a round trip
//! before it shows. Asked over the app FFI (`include/cmux_terminal_prediction.h`,
//! Swift module `CCmuxTerminalPredictionFFI`, linked through cmux-app-ffi).
//!
//! The port of classic cmux's prediction engine (Packages/Shared/CmuxTerminalPrediction,
//! #13967, on by default for remote terminals since #15217). Policy only: the
//! engine never writes to the terminal grid, so a wrong guess is withdrawn by
//! dropping an overlay glyph, and the screen stays whatever the remote said.
//!
//! - [`config`]: the thresholds;
//! - [`glyph`]: one predicted cell;
//! - [`scanner`]: what each byte of remote output means for a prediction;
//! - [`engine`]: what may be drawn, from keystrokes, output and presented frames;
//! - [`input`]: what a chunk of encoded input (the bytes Ghostty writes) was;
//! - [`layout`]: which glyphs fit on the cursor row;
//! - [`ffi`]: the C ABI.

pub mod config;
pub mod engine;
pub mod ffi;
pub mod glyph;
pub mod input;
pub mod layout;
pub mod scanner;

pub use config::PredictionConfiguration;
pub use engine::{Status, TerminalPredictionEngine};
pub use glyph::{PredictedGlyph, Standing};
pub use input::InputKind;
pub use layout::PredictionOverlayLayout;
pub use scanner::{OutputSignal, OutputSkim, TerminalOutputScanner};
