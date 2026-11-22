//! Connector links (`cmux.terminal.connector/1`), owned by the host: the
//! open checks and one link per app, kind and target, over the shared
//! [`ChannelTable`].

use super::channel::{ChannelEnd, ChannelTable, FrameOutcome};
use super::{
    BackendError, BackendId, DEFAULT_WINDOW_BYTES, Declaration, End, Frame, LocalId, Lost,
    OpenToken, allow_kind,
};

/// Longest target (a connector-defined id such as a Cloud machine id).
const MAX_TARGET_BYTES: usize = 256;
/// Most links one app holds at once.
pub(crate) const MAX_LINKS_PER_APP: usize = 64;

/// A link that ended, exactly once.
pub(crate) type LinkEvent = ChannelEnd;

/// What a consumed open token was minted for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TokenUse {
    /// The catalog op of the user run.
    pub op: String,
    /// That run's idempotency key.
    pub run_key: Option<String>,
}

/// Checks open tokens. The app supervisor implements it: a token works once,
/// for the app it was issued to, within 60 s; any lookup consumes it.
pub(crate) trait OpenTokenGate {
    /// Consumes `token` for `app`; answers what it was minted for.
    fn consume(&self, token: &str, app: &str) -> Option<TokenUse>;
}

/// The host op `cmux.terminal.connector.open {kind, target, open_token}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LinkOpen {
    pub kind: String,
    pub target: String,
    pub open_token: OpenToken,
}

/// Its answer `{channel, window_bytes}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LinkAnswer {
    pub channel: String,
    pub window_bytes: u32,
}

/// What the host records for a link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LinkMeta {
    pub id: BackendId,
    pub target: String,
}

/// The connector links on this machine.
pub(crate) struct LinkRegistry {
    channels: ChannelTable<LinkMeta>,
}

impl Default for LinkRegistry {
    fn default() -> Self {
        Self { channels: ChannelTable::new("link") }
    }
}

/// The checks every open shares, in order: the token is consumed before
/// anything else, so every attempt burns it; then the declaration, the
/// token's op (`openOps`) and the kind (default deny). Answers the kind.
pub(crate) fn check_open(
    app: &str,
    declaration: Result<Declaration, BackendError>,
    kind: &str,
    open_token: &OpenToken,
    tokens: &dyn OpenTokenGate,
) -> Result<(LocalId, TokenUse), BackendError> {
    open_token.check()?;
    let used = tokens.consume(open_token.as_str(), app).ok_or_else(|| {
        BackendError::denied(
            "open_token is not valid: it is unknown, expired, used, or issued to another app",
        )
    })?;
    let declaration = declaration?;
    if !declaration.open_ops.contains(&used.op) {
        return Err(BackendError::denied(format!(
            "open_token was issued for {}, which is not in options.openOps",
            used.op
        )));
    }
    allow_kind(&declaration.kinds, kind)?;
    Ok((LocalId::new(kind)?, used))
}

impl LinkRegistry {
    /// The shared channel table (the relay moves bytes through it).
    pub(crate) fn channels(&self) -> &ChannelTable<LinkMeta> {
        &self.channels
    }

    /// Runs `cmux.terminal.connector.open` for `app` ([`check_open`], then
    /// the target). A second open of the same kind and target answers the
    /// same link.
    pub(crate) fn open(
        &self,
        app: &str,
        declaration: Result<Declaration, BackendError>,
        request: LinkOpen,
        tokens: &dyn OpenTokenGate,
    ) -> Result<LinkAnswer, BackendError> {
        let (kind, _) = check_open(app, declaration, &request.kind, &request.open_token, tokens)?;
        check_target(&request.target)?;
        let id = BackendId::app(app, &kind);
        let window_bytes = DEFAULT_WINDOW_BYTES;
        let same = |_: &str, m: &LinkMeta| m.id == id && m.target == request.target;
        if let Some(channel) = self.channels.find(same) {
            return Ok(LinkAnswer { channel, window_bytes });
        }
        if self.channels.count(app) >= MAX_LINKS_PER_APP {
            return Err(BackendError::Unavailable {
                reason: format!("{app} already holds {MAX_LINKS_PER_APP} links"),
                retryable: true,
            });
        }
        let meta = LinkMeta { id, target: request.target };
        let channel = self.channels.insert(app, meta, window_bytes, false);
        Ok(LinkAnswer { channel, window_bytes })
    }

    pub(crate) fn receive_from_app(
        &self,
        app: &str,
        frame: Frame,
    ) -> Result<FrameOutcome, BackendError> {
        self.channels.receive_from_app(app, frame)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn take_received(
        &self,
        channel: &str,
        max: usize,
    ) -> Result<(Vec<u8>, Option<Frame>), BackendError> {
        self.channels.take_received(channel, max)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn send(&self, channel: &str, bytes: Vec<u8>) -> Result<Frame, BackendError> {
        self.channels.send(channel, bytes)
    }

    /// The host closes a link. The app gets `cmux.terminal.connector.close`
    /// and answers with its `end`, which then finds no link and is dropped.
    pub(crate) fn close(&self, channel: &str) -> Result<LinkEvent, BackendError> {
        self.channels.close(channel, End::Lost(Lost::new("closed", true)))
    }

    /// Ends every link of `app`, in channel order.
    pub(crate) fn end_app(&self, app: &str, lost: &Lost) -> Vec<LinkEvent> {
        self.channels.end_app(app, lost)
    }

    /// Every open link: channel, app, registry id and target.
    pub(crate) fn list(&self) -> Vec<(String, String, BackendId, String)> {
        let links = self.channels.list().into_iter();
        links.map(|(channel, app, meta)| (channel, app, meta.id, meta.target)).collect()
    }

    /// The registry id and target of an open link.
    pub(crate) fn link(&self, channel: &str) -> Option<(BackendId, String)> {
        self.channels.get(channel).map(|(_, meta)| (meta.id, meta.target))
    }
}

/// A target is 1 to 256 bytes with no control characters.
pub(crate) fn check_target(target: &str) -> Result<(), BackendError> {
    if target.is_empty() || target.len() > MAX_TARGET_BYTES || target.chars().any(char::is_control)
    {
        return Err(BackendError::invalid(
            "target must be 1 to 256 bytes with no control characters",
        ));
    }
    Ok(())
}
