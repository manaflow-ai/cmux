//! cmux-terminal: Terminal emulation library
//!
//! This crate provides:
//! - `VirtualTerminal`: Full ANSI/VT100 terminal emulator with scrollback
//! - `EscapeFilter` (alias: `DaFilter`): Filter for terminal escape sequence responses
//!   to prevent feedback loops and unwanted display of query responses
//! - `Grid`, `Row`, `TerminalCharacter`: Terminal buffer types
//!
//! # Usage
//!
//! ```rust
//! use cmux_terminal::{VirtualTerminal, EscapeFilter};
//!
//! // Create a terminal emulator
//! let mut term = VirtualTerminal::new(24, 80);
//! term.process(b"Hello, World!\r\n");
//!
//! // Filter escape sequence responses from PTY output
//! let mut filter = EscapeFilter::new();
//! let filtered = filter.filter(b"\x1b[c"); // DA1 query filtered out
//! let filtered = filter.filter(b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\"); // OSC color response filtered
//! ```

mod character;
mod filter;
mod grid;
mod terminal;

pub use character::{CharacterStyles, ColorPalette, Row, SharedStyles, TerminalCharacter};
pub use filter::{filter_da_queries, filter_escape_responses, DaFilter, EscapeFilter};
pub use grid::Grid;
pub use terminal::{Cell, VirtualTerminal};

// Re-export ratatui types that are used in the public API
pub use ratatui::style::{Color, Modifier, Style};
