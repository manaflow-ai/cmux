//! The rules and projection behind the Mac Home, its chat list and the Chief.
//!
//! The why-swift RFD (cmuxterm-hq `docs/rfd/drafts/why-swift.md`, "The Swift layer, by function") keeps
//! Home, the chat list and the Chief as AppKit views over a Rust projection: the views stay Swift (the
//! junction, `.github/language-boundaries.toml` area `imessage-home`), and what they show and decide moves
//! here, so Linux, Windows and iOS read the same rules.
//!
//! Every rule is a stateless JSON op: `ops::call("inbox.sections", &request)`. The app asks it through one C
//! ABI, `cmux_home_call` (cmux-app-ffi `src/home.rs`, `include/cmux_home.h`, Swift module `CCmuxHomeFFI`).
//! An op's name is `AREA.NAME`; each area is one module below and owns its ops, its types and its tests, so
//! the areas move in parallel without touching each other's files:
//!
//! - [`inbox`]: the conversation list (sections, order, pins, roster, rows, search, sidebar width).
//! - [`compose`]: New Message (recipient tokens, suggestions, existing-conversation match), send routing,
//!   mentions, the attachment check, group actions.
//! - [`chief_home`]: where each Chief lives (home paths per build, the home directory, adoption, the per-tag
//!   and hosted migrations, the acpmux move, app links).
//! - [`chief_brain`]: the brain host (start options, keep and restart, stop at quit, heal, reply watchdog,
//!   settle notice, page deadlines, turn trace lines, the model router lease).
//! - [`chief_settings`]: the Chief's settings snapshot (files, engines, model menu, names, avatars' crop).
//! - [`cloud`]: the cloud link state machine, the session lease, the cloud conversation client's rules,
//!   reply errors, server reach and cloud Chief tabs.
//! - [`dock`]: the Home dock (pins, placeholder shells, kept tabs, tab keys, action plans, launch cache,
//!   pin migration, Chief moves).
//! - [`welcome`]: first run (the welcome script and its timing, intros, switch keys, mascot picks, pet
//!   notices, Chief views' feeds, usage and memory tools, chat colors).
//! - [`mapping`]: owner, cloud and live wire rows mapped to Home rows (the projection the Mac and iOS share).

pub mod chief_brain;
pub mod chief_home;
pub mod chief_settings;
pub mod cloud;
pub mod compose;
pub mod dock;
pub mod inbox;
pub mod mapping;
pub mod ops;
pub mod welcome;

pub use ops::{OpError, call, call_json};
