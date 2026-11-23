//! Moving connections between smoltcp and their owners: accepting from
//! listeners, copying bytes both ways, and ending connections (an `impl`
//! block of [`super::TcpStack`]).

use std::sync::atomic::Ordering;

use bytes::{Buf, Bytes};
use smoltcp::socket::tcp;
use tokio::sync::mpsc::error::{TryRecvError, TrySendError};

use super::{Conn, Handoff, INBOUND_CHUNK_BYTES, LISTEN_SPARES, PeerKey, TcpStack, socket_flow};
use crate::error::WgError;
use crate::stream::Outbound;

impl TcpStack {
    /// Reset every connection and listener and poll once so the resets are
    /// emitted. The caller drains them, then calls [`TcpStack::clear`].
    pub(crate) fn abort_all(&mut self) {
        for conn in &self.conns {
            self.sockets.get_mut::<tcp::Socket>(conn.handle).abort();
        }
        for listener in &self.listeners {
            for handle in &listener.handles {
                self.sockets.get_mut::<tcp::Socket>(*handle).abort();
            }
        }
        self.poll();
    }

    /// Take no new connection, and close every open one after what its owner had queued
    /// (`WgMesh::close`). Listeners and connections still in their handshake are reset.
    pub(crate) fn close_all(&mut self) {
        for listener in std::mem::take(&mut self.listeners) {
            for handle in listener.handles {
                self.sockets.get_mut::<tcp::Socket>(handle).abort();
                self.sockets.remove(handle);
            }
        }
        self.abort_conns(|conn| conn.pending_stream.is_some());
        self.closing = true;
    }

    /// Whether every connection's peer acknowledged all it was sent and its FIN, or the
    /// connection ended: nothing a reset could still take from a peer.
    pub(crate) fn delivered(&self) -> bool {
        self.conns.iter().all(|conn| {
            matches!(
                self.sockets.get::<tcp::Socket>(conn.handle).state(),
                tcp::State::FinWait2 | tcp::State::TimeWait | tcp::State::Closed
            )
        })
    }

    pub(crate) fn clear(&mut self) {
        self.conns.clear();
        self.listeners.clear();
    }

    /// Drop every connection of `peer` (tagged mode): its streams fail with
    /// an error, a pending connect fails, and half-open accepts it delivered
    /// are reset.
    pub(crate) fn abort_peer(&mut self, peer: PeerKey) {
        self.abort_conns(|conn| conn.peer == Some(peer));
        let Some(origins) = self.syn_origins.as_mut() else { return };
        for listener in &self.listeners {
            for handle in &listener.handles {
                let socket = self.sockets.get_mut::<tcp::Socket>(*handle);
                if let Some(flow) = socket_flow(socket)
                    && origins.get(&flow) == Some(&peer)
                {
                    socket.abort();
                }
            }
        }
        origins.retain(|_, origin| *origin != peer);
    }

    /// Drop the connections `doomed` selects; their owners see an error.
    pub(crate) fn abort_conns(&mut self, mut doomed: impl FnMut(&Conn) -> bool) {
        let mut index = 0;
        while index < self.conns.len() {
            let Some(conn) = self.conns.get(index) else { break };
            if !doomed(conn) {
                index += 1;
                continue;
            }
            let conn = self.conns.swap_remove(index);
            conn.reset.store(true, Ordering::Release);
            if let Some((Handoff::Connect(reply), _)) = conn.pending_stream {
                let _ = reply.send(Err(WgError::ConnectionRefused(conn.remote)));
            }
            self.sockets.get_mut::<tcp::Socket>(conn.handle).abort();
            self.sockets.remove(conn.handle);
        }
    }

    pub(crate) fn process_listeners(&mut self) {
        let mut index = 0;
        while index < self.listeners.len() {
            let Some(listener) = self.listeners.get_mut(index) else { break };
            if listener.accept.is_closed() {
                for handle in std::mem::take(&mut listener.handles) {
                    self.sockets.get_mut::<tcp::Socket>(handle).abort();
                    self.sockets.remove(handle);
                }
                self.listeners.swap_remove(index);
                continue;
            }
            let port = listener.port;
            let accept = listener.accept.clone();
            let handles = std::mem::take(&mut listener.handles);
            let mut still_listening = Vec::with_capacity(handles.len());
            let mut listen_count = 0;
            let mut half_open = 0;
            for handle in handles {
                let (state, flow) = {
                    let socket = self.sockets.get::<tcp::Socket>(handle);
                    (socket.state(), socket_flow(socket))
                };
                match state {
                    // The peer's FIN can arrive in the same poll as the ACK
                    // that completes the handshake (a request sent and
                    // half-closed at once, or the two reordered): the socket
                    // goes from SYN-RECEIVED straight to CLOSE-WAIT, and is a
                    // connection all the same.
                    tcp::State::Established | tcp::State::CloseWait => {
                        let Some((local, remote)) = flow else {
                            self.sockets.remove(handle);
                            continue;
                        };
                        // Tagged mode: the key comes from the session that
                        // delivered the SYN. Without one the connection is
                        // reset, never matched to a peer by its address.
                        let peer = match self.syn_origins.as_mut() {
                            None => None,
                            Some(origins) => match origins.remove(&(local, remote)) {
                                Some(origin) => Some(origin),
                                None => {
                                    self.sockets.get_mut::<tcp::Socket>(handle).abort();
                                    self.sockets.remove(handle);
                                    continue;
                                }
                            },
                        };
                        let accept = accept.clone();
                        let (conn, stream) = self.bridge(handle, local, remote, peer);
                        self.admit(Conn {
                            pending_stream: Some((Handoff::Accept(accept), stream)),
                            ..conn
                        });
                    }
                    tcp::State::Listen => {
                        listen_count += 1;
                        still_listening.push(handle);
                    }
                    tcp::State::SynReceived => {
                        half_open += 1;
                        still_listening.push(handle);
                    }
                    // The handshake fell apart (peer reset, timeout): drop it.
                    _ => {
                        if let (Some(origins), Some(flow)) = (self.syn_origins.as_mut(), flow) {
                            origins.remove(&flow);
                        }
                        self.sockets.remove(handle);
                    }
                }
            }
            // Refill only while no handshake is in flight. A new Listen socket
            // added beside a live half-open can be assigned a lower socket slot
            // (freed by a closed connection), and smoltcp would then route a
            // retransmitted SYN to that Listen socket instead of the existing
            // half-open, spawning a duplicate that never completes.
            if half_open == 0 {
                while listen_count < LISTEN_SPARES {
                    match self.listening_socket(port) {
                        Ok(handle) => {
                            still_listening.push(handle);
                            listen_count += 1;
                        }
                        Err(_) => break,
                    }
                }
            }
            if let Some(listener) = self.listeners.get_mut(index) {
                listener.handles = still_listening;
            }
            index += 1;
        }
    }

    /// Returns whether any byte moved, so the caller can poll again.
    pub(crate) fn process_conns(&mut self) -> bool {
        let closing = self.closing;
        let mut progressed = false;
        let mut index = 0;
        while index < self.conns.len() {
            let Some(conn) = self.conns.get_mut(index) else { break };
            let socket = self.sockets.get_mut::<tcp::Socket>(conn.handle);

            if let Some((handoff, stream)) = conn.pending_stream.take() {
                if matches!(&handoff, Handoff::Connect(reply) if reply.is_closed()) {
                    // The connect future was cancelled before the handshake
                    // completed. No stream owner remains to close this socket.
                    socket.abort();
                    let handle = conn.handle;
                    self.sockets.remove(handle);
                    self.conns.swap_remove(index);
                    continue;
                }
                if matches!(socket.state(), tcp::State::Established | tcp::State::CloseWait) {
                    match handoff {
                        Handoff::Connect(reply) => {
                            let _ = reply.send(Ok(stream));
                        }
                        Handoff::Accept(accept) => {
                            if accept.try_send((stream, conn.peer)).is_err() {
                                socket.abort();
                            }
                        }
                    }
                } else if !socket.is_open() {
                    if let Handoff::Connect(reply) = handoff {
                        let _ = reply.send(Err(WgError::ConnectionRefused(conn.remote)));
                    }
                    let handle = conn.handle;
                    self.sockets.remove(handle);
                    self.conns.swap_remove(index);
                    continue;
                } else {
                    // Still in the handshake: no owner yet, so nothing to move
                    // and no EOF to detect (`may_recv` is false before
                    // Established).
                    conn.pending_stream = Some((handoff, stream));
                    index += 1;
                    continue;
                }
            }

            if matches!(
                socket.state(),
                tcp::State::CloseWait
                    | tcp::State::LastAck
                    | tcp::State::Closing
                    | tcp::State::TimeWait
            ) {
                conn.remote_fin = true;
            }

            // Owner -> socket.
            if !conn.outbound_closed {
                loop {
                    if conn.pending_write.is_none() {
                        match conn.outbound.try_recv() {
                            Ok(Outbound::Data(bytes)) => conn.pending_write = Some(bytes),
                            Ok(Outbound::Shutdown) | Err(TryRecvError::Disconnected) => {
                                conn.outbound_closed = true;
                                socket.close();
                                break;
                            }
                            // Closing: what the owner queued went in; nothing later does.
                            Err(TryRecvError::Empty) if closing => {
                                conn.outbound_closed = true;
                                socket.close();
                                break;
                            }
                            Err(TryRecvError::Empty) => break,
                        }
                    }
                    let Some(pending) = conn.pending_write.as_mut() else { break };
                    if !socket.can_send() {
                        break;
                    }
                    match socket.send_slice(pending) {
                        Ok(written) => {
                            conn.send.moved(written);
                            pending.advance(written);
                            progressed |= written > 0;
                            if pending.is_empty() {
                                conn.pending_write = None;
                            } else {
                                break;
                            }
                        }
                        Err(_) => {
                            conn.outbound_closed = true;
                            break;
                        }
                    }
                }
            }

            // Socket -> owner.
            if let Some(sender) = conn.inbound.as_ref() {
                let mut reader_gone = false;
                // Bytes kept from a closed socket go first.
                while !conn.drained.is_empty() {
                    match sender.try_reserve() {
                        Ok(permit) => {
                            if let Some(chunk) = conn.drained.pop_front() {
                                progressed = true;
                                permit.send(chunk);
                            }
                        }
                        Err(TrySendError::Full(())) => break,
                        Err(TrySendError::Closed(())) => {
                            reader_gone = true;
                            break;
                        }
                    }
                }
                while !reader_gone && conn.drained.is_empty() && socket.can_recv() {
                    match sender.try_reserve() {
                        Ok(permit) => {
                            let mut chunk = vec![0u8; socket.recv_queue().min(INBOUND_CHUNK_BYTES)];
                            match socket.recv_slice(&mut chunk) {
                                Ok(count) => {
                                    chunk.truncate(count);
                                    progressed |= count > 0;
                                    permit.send(Bytes::from(chunk));
                                }
                                Err(_) => break,
                            }
                        }
                        Err(TrySendError::Full(())) => break,
                        Err(TrySendError::Closed(())) => {
                            reader_gone = true;
                            break;
                        }
                    }
                }
                // A closed socket (TIME-WAIT, CLOSED) keeps its buffer only
                // until TIME-WAIT's timer resets it: take what the owner has
                // not read yet, or a slow reader loses the stream's tail.
                while !reader_gone && !socket.is_open() && socket.can_recv() {
                    let mut chunk = vec![0u8; socket.recv_queue().min(INBOUND_CHUNK_BYTES)];
                    match socket.recv_slice(&mut chunk) {
                        Ok(count) if count > 0 => {
                            chunk.truncate(count);
                            conn.drained.push_back(Bytes::from(chunk));
                        }
                        _ => break,
                    }
                }
                if reader_gone {
                    conn.inbound = None;
                    conn.drained.clear();
                } else if !socket.may_recv() && !socket.can_recv() && conn.drained.is_empty() {
                    // Remote FIN and every byte delivered: EOF to the owner.
                    // A socket that ended without the FIN (an RST, the user
                    // timeout) ends its owner's reads with an error, as a
                    // kernel socket does, never with an EOF that would pass
                    // a cut-off stream for a whole one.
                    if !conn.remote_fin {
                        conn.reset.store(true, Ordering::Release);
                    }
                    conn.inbound = None;
                }
            } else if socket.can_recv() {
                // Nobody will read it; keep the window moving so the peer can
                // finish closing.
                let _ = socket.recv(|buffer| (buffer.len(), ()));
            }

            // A closed connection stays until its owner has taken every
            // byte it received (a slow reader and a full stream channel).
            if conn.inbound.is_some() && !conn.drained.is_empty() {
                index += 1;
                continue;
            }
            if !socket.is_open() && conn.pending_stream.is_none() {
                let handle = conn.handle;
                self.sockets.remove(handle);
                self.conns.swap_remove(index);
                continue;
            }
            index += 1;
        }
        progressed
    }
}
