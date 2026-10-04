//! [`SshBackend`]: `cmux.terminal.backend/1` for kind `ssh`, over the
//! host-owned channel (`connection.channel.*`).
//!
//! The backend only moves bytes. The host owns the SSH transport (dial,
//! pinned host key, user auth). The local session host parses the bytes,
//! owns the VT state, the snapshots and the journal, and answers terminal
//! queries (DA, DSR), so `answers_queries` is false.

use crate::iface::{
    BackendCapabilities, BackendError, BackendId, ByteTerminal, ChannelOpenRequest, HostChannels,
    LocalId, OpenRequest, PtyRequest, ResumeRequest, Resumed, TerminalBackend, allow_kind,
    check_kinds,
};
use crate::session::{self, Registry, Session};
use crate::terminal::{LostTerminal, SshTerminal};
use std::sync::Arc;

/// The app id of this sample (manifest `id`).
pub const APP_ID: &str = "manaflow-ai/ssh-terminal";
/// The only kind this backend serves (`options.kinds`).
pub const SSH_KIND: &str = "ssh";
/// The implementation id; the registry id is `app:manaflow-ai/ssh-terminal/ssh`.
pub const SSH_ID: &str = "ssh";
/// One write at most; the session host splits a larger paste.
pub const MAX_WRITE_BYTES: usize = 64 * 1024;
/// Terminal type in the PTY request when the session host sends no TERM.
pub const DEFAULT_TERM: &str = "xterm-256color";

pub struct SshBackend {
    id: BackendId,
    kinds: Vec<LocalId>,
    host: Arc<dyn HostChannels>,
    registry: Arc<Registry>,
}

impl SshBackend {
    /// `host` is the app's view of the host ops for its connection handles.
    pub fn new(host: Arc<dyn HostChannels>) -> Result<Self, BackendError> {
        let kinds = vec![LocalId::new(SSH_KIND)?];
        check_kinds(&kinds)?;
        Ok(Self {
            id: BackendId::app(APP_ID, &LocalId::new(SSH_ID)?),
            kinds,
            host,
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
            max_write_bytes: MAX_WRITE_BYTES as u32,
            answers_queries: false,
        }
    }

    fn open(&mut self, request: OpenRequest) -> Result<Box<dyn ByteTerminal>, BackendError> {
        allow_kind(&self.kinds, &request.kind)?;
        if request.cwd.is_some() {
            // `connection.channel.open` has no cwd.
            return Err(BackendError::Unsupported);
        }
        if request.grid.cols == 0 || request.grid.rows == 0 {
            return Err(BackendError::invalid("the grid needs at least one cell"));
        }
        if self.registry.is_busy(&request.terminal) {
            return Err(BackendError::invalid(format!("terminal {} is open", request.terminal)));
        }
        let term = request
            .env
            .iter()
            .find(|(name, _)| name == "TERM")
            .map_or(DEFAULT_TERM, |(_, value)| value.as_str());
        // The handle and the token go to the host unchanged. The host checks
        // the pinned host key before any byte; its typed refusal is our answer.
        let channel = self.host.open(ChannelOpenRequest {
            connection: request.target,
            open_token: request.open_token,
            pty: PtyRequest {
                term: term.to_owned(),
                cols: request.grid.cols,
                rows: request.grid.rows,
            },
            command: request.command,
        })?;
        let session = Session::new(request.terminal, channel, self.host.clone());
        if let Err(error) = self.registry.insert(session.clone()) {
            Session::close_now(&session);
            return Err(error);
        }
        Ok(Box::new(SshTerminal::new(session, self.registry.clone())))
    }

    fn resume(&mut self, request: ResumeRequest) -> Result<Resumed, BackendError> {
        // The host issues one open_token per resume after a user gesture.
        // No host op consumes it yet (README, "Interface gaps"); a resume
        // without one is refused.
        if request.open_token.0.is_empty() {
            return Err(BackendError::invalid("resume needs an open_token"));
        }
        let (terminal, offset, nonce) = session::parse_token(&request.resume_token)?;
        let lost = |reason: &str| Resumed { terminal: Box::new(LostTerminal::new(reason)), offset };
        let session = self.registry.get(&terminal).filter(|s| s.nonce_matches(nonce));
        let Some(session) = session else {
            return Ok(lost("no live ssh session for this token"));
        };
        if !self.registry.is_detached(&session) {
            return Err(BackendError::invalid(format!("terminal {terminal} is attached")));
        }
        if !session.attach_at(offset) {
            return Ok(lost("the resume offset is outside the kept output"));
        }
        self.registry.attached(&session);
        Ok(Resumed { terminal: Box::new(SshTerminal::new(session, self.registry.clone())), offset })
    }
}

impl Drop for SshBackend {
    fn drop(&mut self) {
        for session in self.registry.drain() {
            Session::close_now(&session);
        }
    }
}
