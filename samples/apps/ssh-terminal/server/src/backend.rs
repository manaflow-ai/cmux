//! STUB (red commit): only enough to compile the tests. The next commit
//! replaces it with the SSH backend.

use crate::handles::ConnectionHandles;
use crate::iface::{
    BackendCapabilities, BackendError, BackendId, ByteTerminal, LocalId, OpenRequest, ResumeToken,
    TerminalBackend,
};
use std::sync::Arc;

pub const APP_ID: &str = "example/ssh-terminal";
pub const SSH_KIND: &str = "ssh";
pub const SSH_ID: &str = "ssh";
pub const ANSWERS_QUERIES: bool = true;
pub const MAX_WRITE_BYTES: usize = 0;

pub struct SshBackend {
    id: BackendId,
    kinds: Vec<LocalId>,
}

impl SshBackend {
    pub fn new(_handles: Arc<dyn ConnectionHandles>) -> Result<Self, BackendError> {
        Ok(Self { id: BackendId::app(APP_ID, &LocalId::new("stub")?), kinds: Vec::new() })
    }
}

impl TerminalBackend for SshBackend {
    fn id(&self) -> &BackendId {
        &self.id
    }

    fn kinds(&self) -> &[LocalId] {
        &self.kinds
    }

    fn capabilities(&self) -> BackendCapabilities {
        BackendCapabilities::default()
    }

    fn open(&mut self, _request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError> {
        Err(BackendError::Unsupported("stub".into()))
    }

    fn resume(&mut self, _token: &ResumeToken) -> Result<Box<dyn ByteTerminal>, BackendError> {
        Err(BackendError::Unsupported("stub".into()))
    }
}
