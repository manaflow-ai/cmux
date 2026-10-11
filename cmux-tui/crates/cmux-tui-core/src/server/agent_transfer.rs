//! Guarded chat moves between daemons (`agent-transfer-v1`, cmuxterm-hq#1874
//! slice 1). Not served yet: the verbs come with the next commit.

use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use super::MessageWriter;
use crate::mux::Mux;

pub const AGENT_TRANSFER_CAPABILITY: &str = "agent-transfer-v1";

/// The largest page of bundle data a write takes or a read answers.
pub(crate) const MAX_PAGE_BYTES: usize = 4 << 20;

/// What machine this daemon takes chats on, as the binary reads it at start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentTransferHost {
    /// A cmux Cloud host (the `fs-v1` test).
    pub cloud: bool,
    /// This user's home.
    pub home: PathBuf,
}

#[derive(Default)]
pub(crate) struct AgentTransfers {
    host: RwLock<Option<AgentTransferHost>>,
}

impl Mux {
    /// The machine this daemon takes moved chats on.
    pub fn set_agent_transfer_host(&self, host: Option<AgentTransferHost>) {
        *self.agent_transfers.host.write().unwrap_or_else(|e| e.into_inner()) = host;
    }

    pub(crate) fn serves_agent_transfer(&self) -> bool {
        false
    }
}

pub(super) fn try_handle(
    _mux: &Arc<Mux>,
    _client: u64,
    _message: &str,
    _writer: &MessageWriter,
) -> Option<bool> {
    None
}

#[cfg(test)]
#[path = "agent_transfer_tests.rs"]
mod tests;
