//! The byte channels the host holds for apps: connector links and backend
//! terminals share this table (single writer of channel state). It assigns
//! channel ids, checks every frame an app sends against the channel's owner,
//! credit and offsets, and wakes waiters on a condition variable.
//!
//! Received bytes wait in the channel, at most one window, because credit is
//! granted only as the consumer takes them. A `drain` channel (a terminal)
//! keeps its last bytes after the app's `end` until the consumer has read
//! them, so final output shows before the exit; a link ends at once.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Condvar, Mutex};

use super::{BackendError, Direction, End, Frame, FrameBody, Lost, ReceiveWindow, SendWindow};

/// Largest data frame the host sends to an app.
const MAX_FRAME_BYTES: usize = 64 * 1024;

/// A channel that ended, exactly once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ChannelEnd {
    pub app: String,
    pub channel: String,
    pub end: End,
}

/// What one frame from an app caused.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct FrameOutcome {
    /// Frames to send back to the app (the `end` after a violation).
    pub to_app: Vec<Frame>,
    /// The channel ended.
    pub ended: Option<ChannelEnd>,
}

struct Channel<M> {
    app: String,
    meta: M,
    /// Host to app.
    to_app: SendWindow,
    /// App to host.
    from_app: ReceiveWindow,
    /// Bytes from the app the consumer has not taken yet.
    received: Vec<u8>,
    drain: bool,
    /// A drain channel's end, kept until its last bytes are read.
    end: Option<End>,
}

struct Table<M> {
    channels: BTreeMap<String, Channel<M>>,
    next: u64,
    /// Ends of drain channels for [`ChannelTable::wait_end`].
    ends: HashMap<String, End>,
}

pub(crate) struct ChannelTable<M> {
    prefix: &'static str,
    state: Mutex<Table<M>>,
    /// Signalled on data or credit from an app and on every end.
    changed: Condvar,
}

impl<M: Clone> ChannelTable<M> {
    /// Channel ids are `<prefix>-<n>`.
    pub(crate) fn new(prefix: &'static str) -> Self {
        Self {
            prefix,
            state: Mutex::new(Table { channels: BTreeMap::new(), next: 0, ends: HashMap::new() }),
            changed: Condvar::new(),
        }
    }

    /// Adds a channel of `app`; answers its id.
    pub(crate) fn insert(&self, app: &str, meta: M, window_bytes: u32, drain: bool) -> String {
        self.insert_at(app, meta, window_bytes, drain, 0)
    }

    /// Adds a channel whose app-to-host offsets continue from `offset`
    /// (a resumed terminal).
    pub(crate) fn insert_at(
        &self,
        app: &str,
        meta: M,
        window_bytes: u32,
        drain: bool,
        offset: u64,
    ) -> String {
        let mut state = self.state.lock().unwrap();
        state.next += 1;
        let channel = format!("{}-{}", self.prefix, state.next);
        state.channels.insert(
            channel.clone(),
            Channel {
                app: app.to_owned(),
                meta,
                to_app: SendWindow::new(window_bytes),
                from_app: ReceiveWindow::resume_at(offset, window_bytes),
                received: Vec::new(),
                drain,
                end: None,
            },
        );
        channel
    }

    /// The first open channel whose app and metadata match.
    pub(crate) fn find(&self, pred: impl Fn(&str, &M) -> bool) -> Option<String> {
        let state = self.state.lock().unwrap();
        state
            .channels
            .iter()
            .find(|(_, c)| c.end.is_none() && pred(&c.app, &c.meta))
            .map(|(id, _)| id.clone())
    }

    /// Open channels of `app`.
    pub(crate) fn count(&self, app: &str) -> usize {
        let state = self.state.lock().unwrap();
        state.channels.values().filter(|c| c.end.is_none() && c.app == app).count()
    }

    /// The app and metadata of an open channel.
    pub(crate) fn get(&self, channel: &str) -> Option<(String, M)> {
        let state = self.state.lock().unwrap();
        state
            .channels
            .get(channel)
            .filter(|c| c.end.is_none())
            .map(|c| (c.app.clone(), c.meta.clone()))
    }

    /// Every open channel: id, app, metadata.
    pub(crate) fn list(&self) -> Vec<(String, String, M)> {
        let state = self.state.lock().unwrap();
        state
            .channels
            .iter()
            .filter(|(_, c)| c.end.is_none())
            .map(|(id, c)| (id.clone(), c.app.clone(), c.meta.clone()))
            .collect()
    }

    /// One frame `app` sent. A frame for a channel the app does not hold
    /// is `invalid` and changes nothing. A gap, an overlap, data past the
    /// credit or a credit for the wrong direction ends the channel with
    /// `lost` (sent back to the app).
    pub(crate) fn receive_from_app(
        &self,
        app: &str,
        frame: Frame,
    ) -> Result<FrameOutcome, BackendError> {
        let outcome = receive_locked(&mut self.state.lock().unwrap(), app, frame);
        self.changed.notify_all();
        outcome
    }

    /// Takes up to `max` received bytes without waiting and credits them at
    /// once; answers the bytes and the credit frame for the app.
    pub(crate) fn take_received(
        &self,
        channel: &str,
        max: usize,
    ) -> Result<(Vec<u8>, Option<Frame>), BackendError> {
        let bytes = {
            let mut state = self.state.lock().unwrap();
            let c = state.channels.get_mut(channel).ok_or_else(BackendError::not_open)?;
            let take = max.min(c.received.len());
            c.received.drain(..take).collect::<Vec<u8>>()
        };
        let credit = self.consumed(channel, bytes.len() as u64)?;
        Ok((bytes, credit))
    }

    /// Waits until the channel holds received bytes, then takes up to `max`.
    /// They stay uncredited until [`Self::consumed`]. `invalid` once the
    /// channel ended and holds nothing more.
    pub(crate) fn wait_received(&self, channel: &str, max: usize) -> Result<Vec<u8>, BackendError> {
        let mut state = self.state.lock().unwrap();
        loop {
            let c = state.channels.get_mut(channel).ok_or_else(BackendError::not_open)?;
            if !c.received.is_empty() {
                let take = max.min(c.received.len());
                return Ok(c.received.drain(..take).collect());
            }
            if let Some(end) = c.end.clone() {
                state.channels.remove(channel);
                state.ends.insert(channel.to_owned(), end);
                self.changed.notify_all();
                return Err(BackendError::not_open());
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    /// The consumer took `bytes`; answers the credit frame for the app
    /// (none once the channel ended).
    pub(crate) fn consumed(
        &self,
        channel: &str,
        bytes: u64,
    ) -> Result<Option<Frame>, BackendError> {
        let mut state = self.state.lock().unwrap();
        let c = state.channels.get_mut(channel).ok_or_else(BackendError::not_open)?;
        let credit = c.from_app.consume(Direction::Out, bytes)?;
        Ok(credit
            .filter(|_| c.end.is_none())
            .map(|body| Frame { channel: channel.to_owned(), body }))
    }

    /// One data frame within the channel's credit (no waiting).
    pub(crate) fn send(&self, channel: &str, bytes: Vec<u8>) -> Result<Frame, BackendError> {
        let mut state = self.state.lock().unwrap();
        let c = state.channels.get_mut(channel).filter(|c| c.end.is_none());
        let body = c.ok_or_else(BackendError::not_open)?.to_app.send(bytes)?;
        Ok(Frame { channel: channel.to_owned(), body })
    }

    /// Sends all of `bytes` as data frames of at most 64 KiB, waiting for
    /// the app's credit between frames; each frame goes to `emit` outside
    /// the lock, in order. `invalid` once the channel ended.
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
                    let c = state.channels.get_mut(channel).filter(|c| c.end.is_none());
                    let c = c.ok_or_else(BackendError::not_open)?;
                    let room = usize::try_from(c.to_app.available()).unwrap_or(usize::MAX);
                    let n = room.min(bytes.len()).min(MAX_FRAME_BYTES);
                    if n > 0 {
                        let body = c.to_app.send(bytes[..n].to_vec())?;
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

    /// The host ends a channel with `end` (a close, or the app lost access).
    pub(crate) fn close(&self, channel: &str, end: End) -> Result<ChannelEnd, BackendError> {
        let mut state = self.state.lock().unwrap();
        let c = state.channels.remove(channel).filter(|c| c.end.is_none());
        let c = c.ok_or_else(BackendError::not_open)?;
        if c.drain {
            state.ends.insert(channel.to_owned(), end.clone());
        }
        self.changed.notify_all();
        Ok(ChannelEnd { app: c.app, channel: channel.to_owned(), end })
    }

    /// Ends every channel of `app`, in id order.
    pub(crate) fn end_app(&self, app: &str, lost: &Lost) -> Vec<ChannelEnd> {
        let channels: Vec<String> = {
            let state = self.state.lock().unwrap();
            let open = state.channels.iter().filter(|(_, c)| c.app == app && c.end.is_none());
            open.map(|(id, _)| id.clone()).collect()
        };
        channels.iter().filter_map(|id| self.close(id, End::Lost(lost.clone())).ok()).collect()
    }

    /// Waits for a drain channel's end (the app's `end`, a violation or a
    /// host close) and takes it. A channel this table does not know ends as
    /// lost.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn wait_end(&self, channel: &str) -> End {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(end) = state.ends.remove(channel) {
                return end;
            }
            if !state.channels.contains_key(channel) {
                return End::Lost(Lost::new("the terminal channel is gone", false));
            }
            state = self.changed.wait(state).unwrap();
        }
    }
}

/// Ends a channel under the lock: a link goes at once; a drain channel keeps
/// its bytes until read and records its end for [`ChannelTable::wait_end`].
fn end_locked<M>(state: &mut Table<M>, channel: &str, end: End) {
    let Some(c) = state.channels.get_mut(channel) else { return };
    if !c.drain {
        state.channels.remove(channel);
    } else if c.received.is_empty() {
        state.channels.remove(channel);
        state.ends.insert(channel.to_owned(), end);
    } else {
        c.end = Some(end);
    }
}

fn receive_locked<M>(
    state: &mut Table<M>,
    app: &str,
    frame: Frame,
) -> Result<FrameOutcome, BackendError> {
    let c = state
        .channels
        .get_mut(&frame.channel)
        .filter(|c| c.app == app && c.end.is_none())
        .ok_or_else(BackendError::not_open)?;
    let violation = match frame.body {
        FrameBody::Data { offset, bytes } => match c.from_app.receive(offset, bytes.len()) {
            Ok(()) => {
                c.received.extend_from_slice(&bytes);
                None
            }
            Err(lost) => Some(lost),
        },
        FrameBody::Credit { direction: Direction::In, bytes } => c.to_app.grant(bytes).err(),
        FrameBody::Credit { direction: Direction::Out, .. } => {
            Some(Lost::new("credit direction", false))
        }
        FrameBody::End(end) => {
            end_locked(state, &frame.channel, end.clone());
            let ended = ChannelEnd { app: app.to_owned(), channel: frame.channel, end };
            return Ok(FrameOutcome { to_app: vec![], ended: Some(ended) });
        }
    };
    let Some(lost) = violation else { return Ok(FrameOutcome::default()) };
    let end = End::Lost(lost);
    end_locked(state, &frame.channel, end.clone());
    Ok(FrameOutcome {
        to_app: vec![Frame { channel: frame.channel.clone(), body: FrameBody::End(end.clone()) }],
        ended: Some(ChannelEnd { app: app.to_owned(), channel: frame.channel, end }),
    })
}
