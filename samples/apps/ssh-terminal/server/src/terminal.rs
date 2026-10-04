//! The [`ByteTerminal`] handles the session host holds.

use crate::iface::{
    BackendError, ByteEvent, ByteTerminal, Close, Grid, Input, ResumeToken, Signal,
};
use crate::session::{Registry, Session};
use std::sync::Arc;

/// A handle on a live SSH session. Dropping it without `close` detaches the
/// session (it stays for `resume`); `close` ends it.
pub struct SshTerminal {
    session: Arc<Session>,
    registry: Arc<Registry>,
}

impl SshTerminal {
    pub(crate) fn new(session: Arc<Session>, registry: Arc<Registry>) -> Self {
        Self { session, registry }
    }
}

impl ByteTerminal for SshTerminal {
    fn take_events(&mut self) -> Vec<ByteEvent> {
        self.session.output.take()
    }

    fn write(&self, input: Input) -> Result<(), BackendError> {
        if input.bytes.len() > crate::backend::MAX_WRITE_BYTES {
            return Err(BackendError::Invalid("the write is larger than max_write_bytes".into()));
        }
        self.session.write(input)
    }

    fn resize(&self, grid: Grid) -> Result<(), BackendError> {
        if grid.cols == 0 || grid.rows == 0 {
            return Err(BackendError::Invalid("the grid needs at least one cell".into()));
        }
        self.session.resize(grid)
    }

    fn signal(&self, signal: Signal) -> Result<(), BackendError> {
        self.session.signal(signal)
    }

    fn close(&self, how: Close) -> Result<(), BackendError> {
        self.registry.remove(&self.session.terminal);
        self.session.close(how)
    }

    fn resume_token(&self) -> Option<ResumeToken> {
        Some(self.session.resume_token())
    }
}

impl Drop for SshTerminal {
    fn drop(&mut self) {
        if self.registry.contains(&self.session.terminal) {
            self.session.output.detach();
            self.registry.detached(&self.session);
        }
    }
}

/// What `resume` gives when it cannot resume: one `Lost` event, then
/// nothing; every call is refused.
pub struct LostTerminal {
    reason: Option<String>,
}

impl LostTerminal {
    pub(crate) fn new(reason: &str) -> Self {
        Self { reason: Some(reason.to_owned()) }
    }
}

impl ByteTerminal for LostTerminal {
    fn take_events(&mut self) -> Vec<ByteEvent> {
        self.reason.take().map(ByteEvent::Lost).into_iter().collect()
    }

    fn write(&self, _input: Input) -> Result<(), BackendError> {
        Err(BackendError::Closed)
    }

    fn resize(&self, _grid: Grid) -> Result<(), BackendError> {
        Err(BackendError::Closed)
    }

    fn signal(&self, _signal: Signal) -> Result<(), BackendError> {
        Err(BackendError::Closed)
    }

    fn close(&self, _how: Close) -> Result<(), BackendError> {
        Err(BackendError::Closed)
    }

    fn resume_token(&self) -> Option<ResumeToken> {
        None
    }
}
