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
//! - a handle's entry goes with its final range or a refused one (the peer closed it too), and
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

/// Closes `handle` on `peer`: the peer closes a handle whose range it refuses.
fn release(peer: Arc<Peer>, session: String, handle: String) {
    tokio::spawn(async move {
        let close = json!({"sessionId": session, "handle": handle, "offset": 0, "length": 0});
        let _ = peer.request(method::MUX_MEDIA_RANGE, close).await;
    });
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

    async fn open(&self, peer: &Arc<Peer>, session: &str, p: Value) -> Result<Value, RpcError> {
        let room = self.with(|table| {
            table.held.retain(|_, remote| remote.used.elapsed() < IDLE);
            let room = table.held.len() + table.opening < MAX_HANDLES;
            table.opening += usize::from(room);
            room
        });
        match room {
            None => return Err(refused("media.closed", "the connection has ended")),
            Some(false) => {
                let message = "too many media files are open; read one to its end";
                return Err(refused("media.handles", message));
            }
            Some(true) => {}
        }
        let opening = Opening(self);
        let mut result = peer.request(method::MUX_MEDIA_OPEN, p).await?;
        let theirs = result.get("handle").and_then(Value::as_str).map(str::to_owned);
        let theirs = theirs.ok_or_else(|| RpcError::internal("the peer answered no handle"))?;
        let mut raw = [0u8; 16];
        getrandom::fill(&mut raw).map_err(|e| RpcError::internal(format!("no handle: {e}")))?;
        let mine: String = raw.iter().map(|b| format!("{b:02x}")).collect();
        let remote = Remote {
            peer: peer.clone(),
            session: session.to_owned(),
            handle: theirs.clone(),
            used: Instant::now(),
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
            let remote = table.held.get_mut(&mine).filter(|remote| remote.session == session)?;
            remote.used = Instant::now();
            Some((remote.peer.clone(), remote.handle.clone()))
        });
        let (peer, theirs) = found.flatten().ok_or_else(no_handle)?;
        if let Some(object) = p.as_object_mut() {
            object.insert("handle".into(), Value::String(theirs));
        }
        let result = peer.request(method::MUX_MEDIA_RANGE, p).await;
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
    use super::decoded_len;
    use base64::Engine;

    #[test]
    fn the_decoded_length_matches_the_bytes() {
        for n in 0..10 {
            let data = base64::engine::general_purpose::STANDARD.encode(vec![7u8; n]);
            assert_eq!(decoded_len(&data), n as u64, "{data}");
        }
    }
}
