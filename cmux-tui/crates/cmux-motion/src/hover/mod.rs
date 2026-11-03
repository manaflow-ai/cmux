//! Hover: the hover card state machine, tooltip hover intent, the safe
//! triangle, the row card's placement and the hover timing tokens. Ported
//! from cmux-next macOS (`CmuxNextDesign/HoverCards/HoverCardMachine.swift`,
//! `HoverCardTiming.swift`, `CmuxNextDesignTokens/HoverIntent/HoverIntent.swift`,
//! `HoverCards/HoverCardEscapeGeometry.swift`; plans/cmux-next/hovercards.md)
//! with the same inputs and outputs: the app's coordinator only hit-tests,
//! feeds events and runs effects (per pointer move, in process through the
//! app's C ABI, `c`). Timing values were tuned by Leo and Lawrence; each
//! carries its history in `timing`.

pub mod c;
mod geometry;
mod intent;
mod machine;
mod timing;

pub use geometry::*;
pub use intent::*;
pub use machine::*;
pub use timing::*;

#[cfg(test)]
mod tests;
