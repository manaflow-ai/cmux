//! Connector links (`cmux.terminal.connector/1`), owned by the host.
//!
//! The registry is the single writer of link state: it assigns channel ids,
//! keeps one link per app, kind and target, and checks every frame an app
//! sends for a link against the link's credit and offsets. Relayed bytes
//! wait in the link (at most the window, because credit is granted only as
//! the consumer takes them), so a slow consumer stops the far end instead of
//! growing a buffer.

use std::collections::BTreeMap;
use std::sync::Mutex;

use super::{
    BackendError, BackendId, DEFAULT_WINDOW_BYTES, Declaration, Direction, End, Frame, FrameBody,
    LocalId, Lost, OpenToken, ReceiveWindow, SendWindow, allow_kind,
};

/// Longest target (a connector-defined id such as a Cloud machine id).
const MAX_TARGET_BYTES: usize = 256;
/// Most links one app holds at once.
pub(crate) const MAX_LINKS_PER_APP: usize = 64;

/// Checks open tokens. The app supervisor implements it: a token works once,
/// for the app it was issued to, within 60 s; any lookup consumes it.
pub(crate) trait OpenTokenGate {
    /// Consumes `token` for `app`; answers the catalog op it was minted for.
    fn consume(&self, token: &str, app: &str) -> Option<String>;
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

/// A link that ended, exactly once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LinkEvent {
    pub app: String,
    pub channel: String,
    pub end: End,
}

/// What one frame from an app caused.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct FrameOutcome {
    /// Frames to send back to the app (the `end` after a violation).
    pub to_app: Vec<Frame>,
    /// The link ended.
    pub ended: Option<LinkEvent>,
}

struct Link {
    app: String,
    id: BackendId,
    target: String,
    window_bytes: u32,
    /// Host to app (viewer messages).
    to_app: SendWindow,
    /// App to host (viewer frames).
    from_app: ReceiveWindow,
    /// Bytes from the app the consumer has not taken yet.
    received: Vec<u8>,
}

impl Link {
    fn answer(&self, channel: &str) -> LinkAnswer {
        LinkAnswer { channel: channel.to_owned(), window_bytes: self.window_bytes }
    }
}

#[derive(Default)]
struct State {
    links: BTreeMap<String, Link>,
    next_channel: u64,
}

#[derive(Default)]
pub(crate) struct LinkRegistry {
    state: Mutex<State>,
}

impl LinkRegistry {
    /// Runs `cmux.terminal.connector.open` for `app`. The token is consumed
    /// before anything else is checked, so every attempt burns it. Then the
    /// app must implement the connector (`declaration`), the token must come
    /// from one of its `openOps`, and the kind must be declared (default
    /// deny). A second open of the same kind and target answers the same link.
    pub(crate) fn open(
        &self,
        app: &str,
        declaration: Result<Declaration, BackendError>,
        request: LinkOpen,
        tokens: &dyn OpenTokenGate,
    ) -> Result<LinkAnswer, BackendError> {
        let _ = (app, declaration, request, tokens);
        todo!("connector.open")
    }

    /// One frame `app` sent for a link. A frame for a channel the app does
    /// not hold is `invalid` and changes nothing. A gap, an overlap, data
    /// past the credit or a credit for the wrong direction ends the link
    /// with `lost` (sent back to the app).
    pub(crate) fn receive_from_app(
        &self,
        app: &str,
        frame: Frame,
    ) -> Result<FrameOutcome, BackendError> {
        let _ = (app, frame);
        todo!("link frames")
    }

    /// The consumer (the session host's relay) takes up to `max` relayed
    /// bytes; answers them and the credit frame to send to the app.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn take_received(
        &self,
        channel: &str,
        max: usize,
    ) -> Result<(Vec<u8>, Option<Frame>), BackendError> {
        let mut state = self.state.lock().unwrap();
        let link = state.links.get_mut(channel).ok_or_else(BackendError::not_open)?;
        let take = max.min(link.received.len());
        let bytes: Vec<u8> = link.received.drain(..take).collect();
        let credit = link.from_app.consume(Direction::Out, take as u64)?;
        let credit = credit.map(|body| Frame { channel: channel.to_owned(), body });
        Ok((bytes, credit))
    }

    /// The consumer sends viewer bytes to the app, within the link's credit;
    /// answers the data frame to write to the app's stream.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn send(&self, channel: &str, bytes: Vec<u8>) -> Result<Frame, BackendError> {
        let mut state = self.state.lock().unwrap();
        let link = state.links.get_mut(channel).ok_or_else(BackendError::not_open)?;
        let body = link.to_app.send(bytes)?;
        Ok(Frame { channel: channel.to_owned(), body })
    }

    /// The host closes a link. The app gets `cmux.terminal.connector.close`
    /// and answers with its `end`, which then finds no link and is dropped.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn close(&self, channel: &str) -> Result<LinkEvent, BackendError> {
        let mut state = self.state.lock().unwrap();
        let link = state.links.remove(channel).ok_or_else(BackendError::not_open)?;
        Ok(LinkEvent {
            app: link.app,
            channel: channel.to_owned(),
            end: End::Lost(Lost::new("closed", true)),
        })
    }

    /// Ends every link of `app` (its server stopped or exited, or the app
    /// was disabled or removed), in channel order.
    pub(crate) fn end_app(&self, app: &str, lost: &Lost) -> Vec<LinkEvent> {
        let mut state = self.state.lock().unwrap();
        let channels: Vec<String> =
            state.links.iter().filter(|(_, l)| l.app == app).map(|(c, _)| c.clone()).collect();
        channels
            .into_iter()
            .map(|channel| {
                state.links.remove(&channel);
                LinkEvent { app: app.to_owned(), channel, end: End::Lost(lost.clone()) }
            })
            .collect()
    }

    /// The registry id and target of an open link.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn link(&self, channel: &str) -> Option<(BackendId, String)> {
        let state = self.state.lock().unwrap();
        state.links.get(channel).map(|l| (l.id.clone(), l.target.clone()))
    }
}

/// A target is 1 to 256 bytes with no control characters.
fn check_target(target: &str) -> Result<(), BackendError> {
    if target.is_empty() || target.len() > MAX_TARGET_BYTES || target.chars().any(char::is_control)
    {
        return Err(BackendError::invalid(
            "target must be 1 to 256 bytes with no control characters",
        ));
    }
    Ok(())
}
