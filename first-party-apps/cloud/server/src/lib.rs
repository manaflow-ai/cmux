//! cmux Cloud app server (`cmux/cloud`, plans/cmux-next/cloud-app.md L3).
//!
//! The server runs the Cloud catalog ops (`catalog/cloud-catalog.json`) and
//! keeps the machine projection on this machine. It reaches the cmux-next
//! Cloud backend (`cmux.wire/1`, owner `cloud:CloudDO`, the owner of every
//! machine record) only through a [`api::ControlPlane`]: the host relay adds
//! the install token, so the server never sees a credential.

pub mod api;
pub mod app_env;
pub mod clock;
pub mod connector;
pub mod fs;
pub mod link;
pub mod ops;
pub mod ports;
pub mod proxy;
pub mod rescue;

pub use api::{
    CloudError, ControlPlane, Origin, RelayError, Request, SessionStatus, WireCall, WireError,
    WireReply, WireResult,
};
pub use ops::Server;

/// The server process: the host supervisor's JSON lines on stdin and stdout
/// (shape in `api/relay.rs`), until stdin ends. The `cmux-cloud` binary
/// (src/main.rs) and the multicall cmux binary, which runs it when argv[0]'s
/// file name is `cmux-cloud` (cmux_tui::main, CMUX-570), both call this.
pub fn run_stdio() -> std::io::Result<()> {
    use std::io::{self, BufReader};
    // The serve loop reads stdin on its own thread (a stdin lock cannot move
    // there), so link events wake it while it waits for the host.
    api::serve(api::HostRelay::new(BufReader::new(io::stdin()), io::stdout().lock()))
}
