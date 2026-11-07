//! Opt-in usage recording for cmux NEXT, on the person's own machine.
//!
//! Off until the person turns `diagnostics.usageRecording` on in the app (the app then writes the
//! on-switch, [`UsageDir::set_enabled`]). While it is on, the app, the daemon and acpmux each append
//! the shape of use to their own bounded file: focus moves between terminals, browsers and agent
//! chats, action ids and how they were started (splits, new tabs and closes are actions), counts of what is open, latencies,
//! and agent turns with the token counts their harness reports. Never content: no message text,
//! file paths, URLs or titles; object ids are hashed with a per-install salt ([`event`]).
//! `cmux usage report` reads the files back as distributions ([`report`]).

pub mod event;
pub mod report;
pub mod store;

pub use event::{Entry, Event, Id, Record, Source, Surface, Token};
pub use report::{Dist, Report};
pub use store::{MAX_FILE_BYTES, Recorder, UsageDir, default_dir, now_ms};
