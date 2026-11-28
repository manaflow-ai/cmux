//! Byte-backend terminals (`cmux.terminal.backend/1`), owned by the host:
//! the open checks, the host-assigned terminal id and the channel the
//! session host's local runtime reads and writes ([`super::pty`]).

use std::sync::Arc;

use super::channel::{ChannelEnd, ChannelTable, FrameOutcome};
use super::links::{check_open, check_target};
use super::{
    BackendError, BackendId, DEFAULT_WINDOW_BYTES, Declaration, End, Frame, Lost, OpenToken,
    OpenTokenGate, TokenUse,
};

/// Most terminals one app holds at once.
pub(crate) const MAX_TERMINALS_PER_APP: usize = 64;

/// What the host records for a terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalMeta {
    pub id: BackendId,
    pub target: String,
    /// The idempotency key of the user run whose token opened it: the
    /// client that made the gesture places the terminal by it.
    pub run_key: Option<String>,
}

/// The host op `cmux.terminal.backend.open {kind, target, open_token}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalOpen {
    pub kind: String,
    pub target: String,
    pub open_token: OpenToken,
}

/// The backend terminals on this machine.
pub(crate) struct TerminalRegistry {
    channels: Arc<ChannelTable<TerminalMeta>>,
}

impl Default for TerminalRegistry {
    fn default() -> Self {
        Self { channels: Arc::new(ChannelTable::new("term")) }
    }
}

impl TerminalRegistry {
    /// The shared channel table (the local runtime reads and writes it).
    pub(crate) fn channels(&self) -> &Arc<ChannelTable<TerminalMeta>> {
        &self.channels
    }

    /// Runs the checks of `cmux.terminal.backend.open` for `app` (token
    /// first, then openOps, kind, target and the per-app limit) and adds the
    /// terminal's channel. Answers the terminal id and window.
    pub(crate) fn open(
        &self,
        app: &str,
        declaration: Result<Declaration, BackendError>,
        request: TerminalOpen,
        tokens: &dyn OpenTokenGate,
    ) -> Result<(String, u32), BackendError> {
        let (kind, used) =
            check_open(app, declaration, &request.kind, &request.open_token, tokens)?;
        check_target(&request.target)?;
        if self.channels.count(app) >= MAX_TERMINALS_PER_APP {
            return Err(BackendError::Unavailable {
                reason: format!("{app} already holds {MAX_TERMINALS_PER_APP} terminals"),
                retryable: true,
            });
        }
        let TokenUse { run_key, .. } = used;
        let meta = TerminalMeta { id: BackendId::app(app, &kind), target: request.target, run_key };
        let window = DEFAULT_WINDOW_BYTES;
        Ok((self.channels.insert(app, meta, window, true), window))
    }

    pub(crate) fn receive_from_app(
        &self,
        app: &str,
        frame: Frame,
    ) -> Result<FrameOutcome, BackendError> {
        self.channels.receive_from_app(app, frame)
    }

    /// The host closes a terminal (its session ended or was killed).
    pub(crate) fn close(&self, terminal: &str) -> Result<ChannelEnd, BackendError> {
        self.channels.close(terminal, End::Lost(Lost::new("closed", true)))
    }

    /// Ends every terminal of `app`.
    pub(crate) fn end_app(&self, app: &str, lost: &Lost) -> Vec<ChannelEnd> {
        self.channels.end_app(app, lost)
    }

    /// The app and record of an open terminal.
    pub(crate) fn get(&self, terminal: &str) -> Option<(String, TerminalMeta)> {
        self.channels.get(terminal)
    }
}

/// `connection.channel.open` after the host's checks: the host-owned SSH
/// transport for `connection` handles of kind `ssh` (it dials, checks the
/// pinned host key, authenticates with the user's credential and opens a
/// PTY channel). Not built yet: [`NoSshTransport`] answers for production.
pub(crate) trait SshTransport: Send {
    fn open(
        &mut self,
        app: &str,
        terminal: &str,
        request: ChannelRequest,
    ) -> Result<super::ChannelOpen, BackendError>;
}

/// The params of `cmux.terminal.channel.open {terminal, connection, pty, command?}`
/// after the terminal check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChannelRequest {
    pub connection: String,
    pub pty: super::PtyRequest,
    pub command: Option<Vec<String>>,
}

/// Production until the transport is decided (plan 3.3, "Host-owned SSH
/// transport").
pub(crate) struct NoSshTransport;

impl SshTransport for NoSshTransport {
    fn open(
        &mut self,
        _app: &str,
        _terminal: &str,
        _request: ChannelRequest,
    ) -> Result<super::ChannelOpen, BackendError> {
        Err(BackendError::Unavailable {
            reason: "the host-owned SSH transport is not available yet".into(),
            retryable: false,
        })
    }
}
