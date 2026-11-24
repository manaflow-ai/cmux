//! `cmux github` (git's credential helper, the `gh` shim, GitHub MCP) on a machine the person
//! added from their Mac (an SSH machine, remote-integrations slice 2): no Cloud agent and no hub
//! join, so the ask goes to the acpmux daemon of the agent session it runs in, which asks the
//! Mac that lends the machine GitHub (acpmux `github_broker.rs` `token`). The Mac mints a GitHub
//! App installation token for one repository with the ask's permissions and nothing else.
//!
//! acpmux depends on this crate, not the reverse, so the binary that has both installs the asker
//! here once ([`set_lane_source`]); with none installed, or outside an acpmux agent session (the
//! source answers `None`), an ask with no agent socket and no join keeps its
//! `vm.agent_unreachable`.
//!
//! The token lives in this process only: never written, never logged.

use std::sync::OnceLock;

use crate::cloud::github::TokenAsk;
use crate::github_cli::{Minted, Refused};

/// Asks this session's acpmux daemon for `ask`; None when this process is not in an acpmux
/// agent session on a machine a Mac lends GitHub to (nothing to ask).
pub type LaneSource = fn(&TokenAsk) -> Option<Result<Minted, Refused>>;

static SOURCE: OnceLock<LaneSource> = OnceLock::new();

/// Installs the asker (once per process; a later call keeps the first).
pub fn set_lane_source(source: LaneSource) {
    let _ = SOURCE.set(source);
}

/// The installed asker's answer for `ask`; None with no asker or nothing to ask.
pub fn ask_lane(ask: &TokenAsk) -> Option<Result<Minted, Refused>> {
    SOURCE.get().and_then(|source| source(ask))
}
