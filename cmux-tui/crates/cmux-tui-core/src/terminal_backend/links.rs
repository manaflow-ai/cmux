//! Connector links (`cmux.terminal.connector/1`), owned by the host.
//!
//! The registry is the single writer of link state: it assigns channel ids,
//! keeps one link per app, kind and target, and checks every frame an app
//! sends for a link against the link's credit and offsets. Relayed bytes
//! wait in the link (at most the window, because credit is granted only as
//! the consumer takes them), so a slow consumer stops the far end instead of
//! growing a buffer.

use std::collections::BTreeMap;
use std::sync::{Condvar, Mutex};

use super::{
    BackendError, BackendId, DEFAULT_WINDOW_BYTES, Declaration, Direction, End, Frame, FrameBody,
    LocalId, Lost, OpenToken, ReceiveWindow, SendWindow, allow_kind,
};

/// Longest target (a connector-defined id such as a Cloud machine id).
const MAX_TARGET_BYTES: usize = 256;
/// Most links one app holds at once.
pub(crate) const MAX_LINKS_PER_APP: usize = 64;
/// Largest data frame the host sends to an app.
const MAX_FRAME_BYTES: usize = 64 * 1024;

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
    /// Signalled on every change a relay waits for: data or credit from an
    /// app, and every end.
    changed: Condvar,
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
        request.open_token.check()?;
        let op = tokens.consume(request.open_token.as_str(), app).ok_or_else(|| {
            BackendError::denied(
                "open_token is not valid: it is unknown, expired, used, or issued to another app",
            )
        })?;
        let declaration = declaration?;
        if !declaration.open_ops.contains(&op) {
            return Err(BackendError::denied(format!(
                "open_token was issued for {op}, which is not in options.openOps"
            )));
        }
        allow_kind(&declaration.kinds, &request.kind)?;
        let kind = LocalId::new(&request.kind)?;
        check_target(&request.target)?;
        let id = BackendId::app(app, &kind);
        let mut state = self.state.lock().unwrap();
        if let Some((channel, link)) =
            state.links.iter().find(|(_, l)| l.id == id && l.target == request.target)
        {
            return Ok(link.answer(channel));
        }
        if state.links.values().filter(|l| l.app == app).count() >= MAX_LINKS_PER_APP {
            return Err(BackendError::Unavailable {
                reason: format!("{app} already holds {MAX_LINKS_PER_APP} links"),
                retryable: true,
            });
        }
        state.next_channel += 1;
        let channel = format!("link-{}", state.next_channel);
        let window_bytes = DEFAULT_WINDOW_BYTES;
        let link = Link {
            app: app.to_owned(),
            id,
            target: request.target,
            window_bytes,
            to_app: SendWindow::new(window_bytes),
            from_app: ReceiveWindow::new(window_bytes),
            received: Vec::new(),
        };
        let answer = link.answer(&channel);
        state.links.insert(channel, link);
        Ok(answer)
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
        let outcome = receive_locked(&mut self.state.lock().unwrap(), app, frame);
        self.changed.notify_all();
        outcome
    }

    /// Takes up to `max` relayed bytes without waiting and credits them at
    /// once; answers the bytes and the credit frame for the app.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn take_received(
        &self,
        channel: &str,
        max: usize,
    ) -> Result<(Vec<u8>, Option<Frame>), BackendError> {
        let bytes = {
            let mut state = self.state.lock().unwrap();
            let link = state.links.get_mut(channel).ok_or_else(BackendError::not_open)?;
            let take = max.min(link.received.len());
            link.received.drain(..take).collect::<Vec<u8>>()
        };
        let credit = self.consumed(channel, bytes.len() as u64)?;
        Ok((bytes, credit))
    }

    /// Waits until the link holds relayed bytes, then takes up to `max` of
    /// them. They stay uncredited until [`Self::consumed`], so the app
    /// cannot send more while the relay's client has not taken them.
    /// `invalid` once the link ended.
    pub(crate) fn wait_received(&self, channel: &str, max: usize) -> Result<Vec<u8>, BackendError> {
        let mut state = self.state.lock().unwrap();
        loop {
            let link = state.links.get_mut(channel).ok_or_else(BackendError::not_open)?;
            if !link.received.is_empty() {
                let take = max.min(link.received.len());
                return Ok(link.received.drain(..take).collect());
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    /// The relay's client took `bytes`; answers the credit frame for the app.
    pub(crate) fn consumed(
        &self,
        channel: &str,
        bytes: u64,
    ) -> Result<Option<Frame>, BackendError> {
        let mut state = self.state.lock().unwrap();
        let link = state.links.get_mut(channel).ok_or_else(BackendError::not_open)?;
        let credit = link.from_app.consume(Direction::Out, bytes)?;
        Ok(credit.map(|body| Frame { channel: channel.to_owned(), body }))
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

    /// Sends all of `bytes` to the app as data frames of at most 64 KiB,
    /// waiting for the app's credit between frames. Each frame goes to
    /// `emit` outside the registry lock, in order. `invalid` once the link
    /// ended.
    pub(crate) fn send_all(
        &self,
        channel: &str,
        mut bytes: &[u8],
        emit: &dyn Fn(Frame),
    ) -> Result<(), BackendError> {
        while !bytes.is_empty() {
            let (frame, sent) = {
                let mut state = self.state.lock().unwrap();
                loop {
                    let link = state.links.get_mut(channel).ok_or_else(BackendError::not_open)?;
                    let room = usize::try_from(link.to_app.available()).unwrap_or(usize::MAX);
                    let n = room.min(bytes.len()).min(MAX_FRAME_BYTES);
                    if n > 0 {
                        let body = link.to_app.send(bytes[..n].to_vec())?;
                        break (Frame { channel: channel.to_owned(), body }, n);
                    }
                    state = self.changed.wait(state).unwrap();
                }
            };
            emit(frame);
            bytes = &bytes[sent..];
        }
        Ok(())
    }

    /// The host closes a link. The app gets `cmux.terminal.connector.close`
    /// and answers with its `end`, which then finds no link and is dropped.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn close(&self, channel: &str) -> Result<LinkEvent, BackendError> {
        let mut state = self.state.lock().unwrap();
        let link = state.links.remove(channel).ok_or_else(BackendError::not_open)?;
        self.changed.notify_all();
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
        let ended = channels
            .into_iter()
            .map(|channel| {
                state.links.remove(&channel);
                LinkEvent { app: app.to_owned(), channel, end: End::Lost(lost.clone()) }
            })
            .collect();
        self.changed.notify_all();
        ended
    }

    /// Every open link: channel, app, registry id and target.
    pub(crate) fn list(&self) -> Vec<(String, String, BackendId, String)> {
        let state = self.state.lock().unwrap();
        state
            .links
            .iter()
            .map(|(c, l)| (c.clone(), l.app.clone(), l.id.clone(), l.target.clone()))
            .collect()
    }

    /// The registry id and target of an open link.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn link(&self, channel: &str) -> Option<(BackendId, String)> {
        let state = self.state.lock().unwrap();
        state.links.get(channel).map(|l| (l.id.clone(), l.target.clone()))
    }
}

/// One frame from `app` under the registry lock ([`LinkRegistry::receive_from_app`]).
fn receive_locked(
    state: &mut State,
    app: &str,
    frame: Frame,
) -> Result<FrameOutcome, BackendError> {
    let link = state
        .links
        .get_mut(&frame.channel)
        .filter(|l| l.app == app)
        .ok_or_else(BackendError::not_open)?;
    let violation = match frame.body {
        FrameBody::Data { offset, bytes } => match link.from_app.receive(offset, bytes.len()) {
            Ok(()) => {
                link.received.extend_from_slice(&bytes);
                None
            }
            Err(lost) => Some(lost),
        },
        FrameBody::Credit { direction: Direction::In, bytes } => link.to_app.grant(bytes).err(),
        FrameBody::Credit { direction: Direction::Out, .. } => {
            Some(Lost::new("credit direction", false))
        }
        FrameBody::End(end) => {
            state.links.remove(&frame.channel);
            let ended = LinkEvent { app: app.to_owned(), channel: frame.channel, end };
            return Ok(FrameOutcome { to_app: vec![], ended: Some(ended) });
        }
    };
    let Some(lost) = violation else { return Ok(FrameOutcome::default()) };
    state.links.remove(&frame.channel);
    let end = End::Lost(lost);
    Ok(FrameOutcome {
        to_app: vec![Frame { channel: frame.channel.clone(), body: FrameBody::End(end.clone()) }],
        ended: Some(LinkEvent { app: app.to_owned(), channel: frame.channel, end }),
    })
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
