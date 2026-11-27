//! `_acpmux/media_open` and `_acpmux/media_range` for a peer's chat (`hub/media_read.rs`).
//!
//! All of this daemon's clients reach a peer over one link, so the peer's handle table is the
//! link's, not a client's. Each client connection keeps its own table here instead:
//!
//! - an open answers a handle of this connection that stands for the peer's, so another
//!   connection, even for the same chat, cannot read through it (`media.handle`);
//! - a connection holds at most [`MAX_HANDLES`] of them, counting the opens still waiting on the
//!   peer and only the handles used within [`IDLE`] (the peer closes the others), so one client
//!   cannot fill the link's table, even with many opens at once;
//! - a handle's entry goes with its final range, or with a refused one once it is closed on the
//!   peer too (a refusal may come from the peer's guard, before its reader closed it), and
//!   when the connection ends every handle still held is closed on the peer: a range of length
//!   0, which the peer refuses and so closes.

use crate::hub::media_handles::{IDLE, MAX_HANDLES};
use crate::peer::Peer;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use tokio::time::Instant;

struct Remote {
    peer: Arc<Peer>,
    session: String,
    handle: String,
    used: Instant,
    /// The peer's link epoch when it opened the handle; a later one means the link that held it
    /// ended, and the peer closed it then.
    epoch: u64,
}

impl Remote {
    /// The peer closed this handle when the link it was opened on ended.
    fn link_gone(&self) -> bool {
        self.peer.link_epoch() != self.epoch
    }
}

#[derive(Default)]
struct Table {
    held: HashMap<String, Remote>,
    /// Opens sent to a peer and not answered yet: each holds a place under the cap.
    opening: usize,
}

/// One connection's handles of peers' media (module docs); None once the connection ended.
pub(crate) struct RemoteMedia(Mutex<Option<Table>>);

impl Default for RemoteMedia {
    fn default() -> Self {
        RemoteMedia(Mutex::new(Some(Table::default())))
    }
}

/// An open's place under the cap, given back when the open is answered or dropped.
struct Opening<'a>(&'a RemoteMedia);

impl Drop for Opening<'_> {
    fn drop(&mut self) {
        self.0.with(|table| table.opening -= 1);
    }
}

fn refused(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

fn no_handle() -> RpcError {
    refused("media.handle", "no such media handle on this connection; open the file again")
}

/// Closes `handle` on `peer`: the peer closes a handle whose range it refuses. A handle the peer
/// already closed is refused the same way, so this is safe to send twice.
async fn close_on(peer: &Peer, session: &str, handle: &str) {
    let close = json!({"sessionId": session, "handle": handle, "offset": 0, "length": 0});
    let _ = peer.request(method::MUX_MEDIA_RANGE, close).await;
}

/// [`close_on`] in the background, for a table that is going away.
fn release(peer: Arc<Peer>, session: String, handle: String) {
    tokio::spawn(async move { close_on(&peer, &session, &handle).await });
}

/// The bytes the base64 `data` decodes to.
fn decoded_len(data: &str) -> u64 {
    let pad = data.bytes().rev().take_while(|&b| b == b'=').count();
    u64::try_from((data.len() / 4 * 3).saturating_sub(pad)).unwrap_or(u64::MAX)
}

impl RemoteMedia {
    fn with<T>(&self, f: impl FnOnce(&mut Table) -> T) -> Option<T> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).as_mut().map(f)
    }

    /// The connection ended: every handle still held closes on its peer.
    pub(crate) fn close_all(&self) {
        let held = self.0.lock().unwrap_or_else(PoisonError::into_inner).take();
        for remote in held.into_iter().flat_map(|table| table.held.into_values()) {
            release(remote.peer, remote.session, remote.handle);
        }
    }

    /// Takes a place for an open, if there is one: None once the connection ended. A handle
    /// whose peer link ended is dropped first (the peer closed it with the link), and an idle one
    /// is dropped and closed on the peer too, so neither keeps a place here.
    fn reserve(&self) -> Option<bool> {
        self.with(|table| {
            table.held.retain(|_, remote| !remote.link_gone());
            let idle: Vec<String> = table
                .held
                .iter()
                .filter(|(_, remote)| remote.used.elapsed() >= IDLE)
                .map(|(mine, _)| mine.clone())
                .collect();
            for remote in idle.iter().filter_map(|mine| table.held.remove(mine)) {
                release(remote.peer, remote.session, remote.handle);
            }
            let room = table.held.len() + table.opening < MAX_HANDLES;
            table.opening += usize::from(room);
            room
        })
    }

    async fn open(&self, peer: &Arc<Peer>, session: &str, p: Value) -> Result<Value, RpcError> {
        match self.reserve() {
            None => return Err(refused("media.closed", "the connection has ended")),
            Some(false) => {
                let message = "too many media files are open; read one to its end";
                return Err(refused("media.handles", message));
            }
            Some(true) => {}
        }
        let opening = Opening(self);
        let epoch = peer.link_epoch();
        let mut result = peer.request(method::MUX_MEDIA_OPEN, p).await?;
        let theirs = result.get("handle").and_then(Value::as_str).map(str::to_owned);
        let theirs = theirs.ok_or_else(|| RpcError::internal("the peer answered no handle"))?;
        // The link changed while the open was out: which link holds the handle is unknown, so it
        // is closed on the peer's current one (refused harmlessly if it went with the old one).
        if peer.link_epoch() != epoch {
            release(peer.clone(), session.to_owned(), theirs);
            let message = "the link to the peer changed; open the file again";
            return Err(refused("media.closed", message));
        }
        let mut raw = [0u8; 16];
        getrandom::fill(&mut raw).map_err(|e| RpcError::internal(format!("no handle: {e}")))?;
        let mine: String = raw.iter().map(|b| format!("{b:02x}")).collect();
        let remote = Remote {
            peer: peer.clone(),
            session: session.to_owned(),
            handle: theirs.clone(),
            used: Instant::now(),
            epoch,
        };
        let kept = self.with(|table| table.held.insert(mine.clone(), remote));
        drop(opening);
        if kept.is_none() {
            release(peer.clone(), session.to_owned(), theirs);
            return Err(refused("media.closed", "the connection that opened the file has ended"));
        }
        if let Some(object) = result.as_object_mut() {
            object.insert("handle".into(), Value::String(mine));
            object.insert("peer".into(), Value::String(peer.name.clone()));
        }
        Ok(result)
    }

    async fn range(&self, session: &str, mut p: Value) -> Result<Value, RpcError> {
        let mine = p.get("handle").and_then(Value::as_str).unwrap_or_default().to_owned();
        let found = self.with(|table| {
            let remote = table.held.get(&mine).filter(|remote| remote.session == session)?;
            // The peer closed it with the link it was opened on.
            if remote.link_gone() {
                table.held.remove(&mine);
                return None;
            }
            let remote = table.held.get_mut(&mine)?;
            remote.used = Instant::now();
            Some((remote.peer.clone(), remote.handle.clone()))
        });
        let (peer, theirs) = found.flatten().ok_or_else(no_handle)?;
        if let Some(object) = p.as_object_mut() {
            object.insert("handle".into(), Value::String(theirs.clone()));
        }
        let result = peer.request(method::MUX_MEDIA_RANGE, p).await;
        // A refused range may never have reached the peer's reader (its guard refused it first),
        // so the handle is closed there before its place here is given back.
        if result.is_err() {
            close_on(&peer, session, &theirs).await;
        }
        let done = result.as_ref().map_or(true, |reply| {
            let at = |key: &str| reply.get(key).and_then(Value::as_u64).unwrap_or(0);
            let data = reply.get("data").and_then(Value::as_str).unwrap_or_default();
            at("offset").saturating_add(decoded_len(data)) >= at("size")
        });
        if done {
            self.with(|table| table.held.remove(&mine));
        }
        let mut result = result?;
        if let Some(object) = result.as_object_mut() {
            object.insert("handle".into(), Value::String(mine));
            object.insert("peer".into(), Value::String(peer.name.clone()));
        }
        Ok(result)
    }
}

/// `m` (a media open or range) for the peer's chat `session`, with `p` the request as it goes to
/// the peer.
pub(super) async fn forward(
    media: &RemoteMedia,
    peer: &Arc<Peer>,
    session: &str,
    m: &str,
    p: Value,
) -> Result<Value, RpcError> {
    if m == method::MUX_MEDIA_OPEN {
        media.open(peer, session, p).await
    } else {
        media.range(session, p).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    /// A peer link that ends (the peer closes every handle it held for it) gives this
    /// connection's places back at once, not after IDLE.
    #[tokio::test]
    async fn a_handle_of_an_ended_peer_link_holds_no_place() {
        let (notices, _rx) = tokio::sync::mpsc::channel(8);
        let peer = Peer::new("b", "ws://127.0.0.1:9", None, None, notices);
        let media = RemoteMedia::default();
        let epoch = peer.link_epoch();
        media.with(|table| {
            for n in 0..MAX_HANDLES {
                let remote = Remote {
                    peer: peer.clone(),
                    session: "s".into(),
                    handle: format!("theirs-{n}"),
                    used: Instant::now(),
                    epoch,
                };
                table.held.insert(format!("mine-{n}"), remote);
            }
        });
        assert_eq!(media.reserve(), Some(false), "a full table has no room");
        peer.link_ended();
        assert_eq!(media.reserve(), Some(true), "the ended link's handles kept their places");
        assert_eq!(media.with(|table| table.held.len()), Some(0));
    }

    #[test]
    fn the_decoded_length_matches_the_bytes() {
        for n in 0..10 {
            let data = base64::engine::general_purpose::STANDARD.encode(vec![7u8; n]);
            assert_eq!(decoded_len(&data), n as u64, "{data}");
        }
    }
}
