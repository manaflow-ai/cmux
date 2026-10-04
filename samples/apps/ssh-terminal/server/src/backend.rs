//! RED STEP stub: every open and resume is refused.

use crate::iface::{
    BackendCapabilities, BackendError, BackendId, ByteTerminal, HostChannels, LocalId,
    OpenRequest, ResumeRequest, Resumed, TerminalBackend,
};
use std::sync::Arc;

pub const APP_ID: &str = "manaflow-ai/ssh-terminal";
pub const SSH_KIND: &str = "ssh";
pub const SSH_ID: &str = "ssh";
pub const MAX_WRITE_BYTES: usize = 64 * 1024;
pub const DEFAULT_TERM: &str = "xterm-256color";
pub const MAX_UNREAD: usize = 64 * 1024;
pub const RETAINED: usize = 64 * 1024;
pub const MAX_BUFFERED_BYTES: usize = 1024 * 1024;
pub const MAX_DETACHED: usize = 16;

pub struct SshBackend {
    id: BackendId,
    kinds: Vec<LocalId>,
    _host: Arc<dyn HostChannels>,
}

impl SshBackend {
    pub fn new(host: Arc<dyn HostChannels>) -> Result<Self, BackendError> {
        Ok(Self {
            id: BackendId::app(APP_ID, &LocalId::new(SSH_ID)?),
            kinds: vec![LocalId::new(SSH_KIND)?],
            _host: host,
        })
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
        // The capabilities the sample declares; the behavior is missing.
        BackendCapabilities { resume: true, ..BackendCapabilities::default() }
    }

    fn open(&mut self, _request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError> {
        Err(BackendError::Unsupported)
    }

    fn resume(&mut self, _request: ResumeRequest) -> Result<Resumed, BackendError> {
        Err(BackendError::Unsupported)
    }
}
