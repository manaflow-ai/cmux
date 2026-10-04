//! [`SshBackend`]: `cmux.terminal.backend/1` for kind `ssh`.
//!
//! The backend only moves bytes. The local session host parses them, owns
//! the VT state, the snapshots and the journal, and answers terminal queries
//! (DA, DSR), so [`ANSWERS_QUERIES`] is false.

use crate::client;
use crate::handles::ConnectionHandles;
use crate::iface::{
    BackendCapabilities, BackendError, BackendId, ByteTerminal, LocalId, OpenRequest, ResumeToken,
    TerminalBackend, allow_kind, check_kinds,
};
use crate::session::{self, Registry, Session};
use crate::terminal::{LostTerminal, SshTerminal};
use std::sync::Arc;
use tokio::runtime::Runtime;

/// The app id of this sample (manifest `id`).
pub const APP_ID: &str = "example/ssh-terminal";
/// The only kind this backend serves (`options.kinds`).
pub const SSH_KIND: &str = "ssh";
/// The implementation id; the registry id is `app:example/ssh-terminal/ssh`.
pub const SSH_ID: &str = "ssh";
/// Plain SSH: the far end is a shell, not a session host, so the local host
/// answers terminal queries. Not in the mirrored capabilities yet (README).
pub const ANSWERS_QUERIES: bool = false;
/// One write at most; the session host splits a larger paste.
pub const MAX_WRITE_BYTES: usize = 64 * 1024;
/// Terminal type sent in the PTY request when the session host sends no TERM.
const DEFAULT_TERM: &str = "xterm-256color";

pub struct SshBackend {
    id: BackendId,
    kinds: Vec<LocalId>,
    handles: Arc<dyn ConnectionHandles>,
    /// Always `Some` until drop.
    runtime: Option<Runtime>,
    registry: Arc<Registry>,
}

/// `open` and `resume` wait for the network on the backend's own runtime;
/// called from inside another async runtime, that wait would panic.
fn outside_async_runtime() -> Result<(), BackendError> {
    if tokio::runtime::Handle::try_current().is_ok() {
        Err(BackendError::Unsupported(
            "call the ssh backend from a plain thread, not from an async task".into(),
        ))
    } else {
        Ok(())
    }
}

impl SshBackend {
    /// Starts the backend with its own async runtime. Call it, `open` and
    /// `resume` from a thread that is not inside an async runtime (they
    /// return `Unsupported` there). The other calls never wait.
    pub fn new(handles: Arc<dyn ConnectionHandles>) -> Result<Self, BackendError> {
        let kinds = vec![LocalId::new(SSH_KIND)?];
        check_kinds(&kinds)?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("ssh-terminal")
            .enable_all()
            .build()
            .map_err(|e| BackendError::Unavailable {
                reason: format!("runtime: {e}"),
                retryable: false,
            })?;
        Ok(Self {
            id: BackendId::app(APP_ID, &LocalId::new(SSH_ID)?),
            kinds,
            handles,
            runtime: Some(runtime),
            registry: Arc::new(Registry::default()),
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
        BackendCapabilities {
            resize: true,
            signals: true,
            exit_status: true,
            resume: true,
            cwd_reports: false,
            max_write_bytes: MAX_WRITE_BYTES,
        }
    }

    fn open(&mut self, request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError> {
        allow_kind(&self.kinds, &request.kind)?;
        outside_async_runtime()?;
        if request.command.is_some() || request.cwd.is_some() {
            return Err(BackendError::Unsupported(
                "the ssh sample opens the login shell only (no command, no cwd)".into(),
            ));
        }
        if request.grid.cols == 0 || request.grid.rows == 0 {
            return Err(BackendError::Invalid("the grid needs at least one cell".into()));
        }
        if self.registry.is_busy(&request.terminal) {
            return Err(BackendError::Invalid(format!("terminal {} is open", request.terminal)));
        }
        // The handle is resolved before any network access: an unknown or
        // revoked handle never reaches a socket.
        let connection = self.handles.resolve(&request.kind, &request.target)?;
        let term = request
            .env
            .iter()
            .find(|(name, _)| name == "TERM")
            .map_or(DEFAULT_TERM, |(_, value)| value.as_str());
        let grid = request.grid;
        let runtime = self.runtime.as_ref().ok_or(BackendError::Closed)?;
        let opened = runtime.block_on(async { client::connect(&connection, term, grid).await })?;
        let session = session::start(
            runtime,
            request.terminal.clone(),
            opened.ssh,
            opened.read,
            opened.write,
            &opened.early,
        );
        if let Err(error) = self.registry.insert(session.clone()) {
            Session::close_now(&session);
            return Err(error);
        }
        Ok(Box::new(SshTerminal::new(session, self.registry.clone())))
    }

    fn resume(&mut self, token: &ResumeToken) -> Result<Box<dyn ByteTerminal>, BackendError> {
        let (terminal, offset, nonce) = session::parse_token(token)?;
        let session = self.registry.get(&terminal).filter(|s| s.nonce_matches(nonce));
        let Some(session) = session else {
            return Ok(Box::new(LostTerminal::new("no live ssh session for this token")));
        };
        if !self.registry.is_detached(&session) {
            return Err(BackendError::Invalid(format!("terminal {terminal} is attached")));
        }
        if !session.output.attach_at(offset) {
            return Ok(Box::new(LostTerminal::new("the resume offset is outside the kept output")));
        }
        self.registry.attached(&session);
        Ok(Box::new(SshTerminal::new(session, self.registry.clone())))
    }
}

impl Drop for SshBackend {
    fn drop(&mut self) {
        for session in self.registry.drain() {
            Session::close_now(&session);
        }
        // Does not wait and does not panic inside another runtime; the
        // tasks stop and every connection drops.
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}
