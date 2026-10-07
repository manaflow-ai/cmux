//! The two terminal interfaces, shared by the cmux-tui daemon and the app
//! servers that implement them (plans/cmux-next/ghostty-next-switch.md 3.3).
//!
//! - `cmux.terminal.backend/1` (bytes mode): the backend carries raw
//!   terminal bytes; the local session host parses them and owns snapshots
//!   and the journal.
//! - `cmux.terminal.connector/1` (host mode): the far end runs its own
//!   session host; the local host relays the viewer protocol.
//!
//! Rules every side follows:
//! - Synchronous and non-blocking: no method waits. Outbound items are
//!   pulled with `take_frames`; the caller drains when its transport has
//!   something for it, so nothing polls.
//! - Bytes move only as [`Frame`]s (`data`, `credit`, `end`), never as
//!   method calls. [`SendWindow`] and [`ReceiveWindow`] are the one credit
//!   and offset rule. One exception, in-process connectors only: a link
//!   whose bytes move on a carrier socket says so with
//!   [`DataPlane::Socket`] and then carries only its `end` as a frame.
//! - Each channel ends exactly once. A [`HostLink::close`] is answered by
//!   the link's `end`; after [`ByteTerminal::close`] no `end` follows (the
//!   session host already ended the terminal; [`check_closed`]).
//! - The session host assigns every wire channel id (terminals, host
//!   channels, connector links). Implementations never mint wire ids or
//!   open tokens; an in-process connector names its links
//!   ([`HostLink::channel`]).
//! - A kind outside `options.kinds` is [`BackendError::Denied`] (default deny).
//!
//! The JSON source of truth is
//! `cmux-tui/crates/cmux-app-host/interfaces/cmux.terminal.{backend,connector}/1.json`.

mod backend;
mod conformance;
mod connector;
mod credit;
mod error;
mod frames;
mod host_channel;
mod ids;
mod tokens;

pub use backend::{
    BACKEND_INTERFACE, BackendCapabilities, ByteTerminal, Close, Grid, MAX_EXIT_MESSAGE,
    OpenRequest, ResumeRequest, Resumed, Signal, TerminalBackend,
};
pub use conformance::check_closed;
pub use connector::{
    CONNECTOR_INTERFACE, ConnectRequest, ConnectorEvent, DataPlane, HostLink, TerminalConnector,
};
pub use credit::{ReceiveWindow, SendWindow};
pub use error::{BackendError, HostKeyRefusal};
pub use frames::{
    DEFAULT_WINDOW_BYTES, Direction, End, ExitStatus, Frame, FrameBody, Lost, MAX_WINDOW_BYTES,
    MIN_WINDOW_BYTES, check_window,
};
pub use host_channel::{ChannelOpen, ChannelOpenRequest, HostChannels, PtyRequest};
pub use ids::{BackendId, LocalId, MAX_LOCAL_ID, allow_kind, check_kinds};
pub use tokens::{OpenToken, ResumeToken};

#[cfg(test)]
mod tests;
