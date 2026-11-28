//! Request/response access to the daemon's mux control service without a
//! local socket.
//!
//! The Mac sidecar bridges `Service::MuxControl` to a Unix socket and lets the
//! `cmux-tui` CLI speak `cmux.protocol/2` through it. A process that embeds the
//! remote client directly (the iOS terminal client) has no socket and no CLI,
//! so it needs the same lines sent and matched in process. This client owns one
//! mux control stream and answers one JSON request at a time: the request line
//! goes out on the lane the bridge would have chosen, and the reply is the
//! first assembled line whose `id` matches. Unsolicited lines (events nobody
//! subscribed to) are dropped.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use bytes::Bytes;
use cmux_remote_protocol::Service;
use serde_json::Value;
use tokio::sync::Mutex;

use crate::bridge::{BridgeError, await_opened};
use crate::mux_codec::{
    MAX_MUX_DOWNLOAD_LINE_BYTES, MAX_MUX_LINE_BYTES, MuxLineAssembler, encode_line,
    mux_line_payload_len,
};
use crate::mux_lanes::classify_client_line;
use crate::service::{ServiceMultiplexer, ServiceStream, StreamBudget, StreamChunk};

pub struct MuxLineClient {
    stream: Arc<ServiceStream>,
    next_message: AtomicU64,
    receiver: Mutex<Receiver>,
}

struct Receiver {
    initial: VecDeque<StreamChunk>,
    assembler: MuxLineAssembler<Option<StreamBudget>>,
    closed: bool,
}

impl std::fmt::Debug for MuxLineClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("MuxLineClient").field("stream", &self.stream.id()).finish()
    }
}

impl MuxLineClient {
    /// Open the mux control service and wait until every lane is ready.
    pub async fn open(multiplexer: &Arc<ServiceMultiplexer>) -> Result<Self, BridgeError> {
        let stream = multiplexer.open(Service::MuxControl, Default::default()).await?;
        let opened = match await_opened(&stream).await {
            Ok(opened) => opened,
            Err(error) => {
                let _ = stream.close().await;
                return Err(error);
            }
        };
        Ok(Self {
            stream: Arc::new(stream),
            next_message: AtomicU64::new(1),
            receiver: Mutex::new(Receiver {
                initial: opened.buffered,
                assembler: MuxLineAssembler::with_maximum(MAX_MUX_DOWNLOAD_LINE_BYTES),
                closed: false,
            }),
        })
    }

    /// Send one JSON request line and return the reply whose `id` matches.
    ///
    /// Requests are answered one at a time; a caller that needs a deadline
    /// wraps this in its own timeout and drops the future, which leaves the
    /// stream usable for the next request only if the reply never arrives
    /// out of band, so callers should close the client after a timeout.
    pub async fn request(&self, request: &Value) -> Result<Value, BridgeError> {
        let id = request
            .get("id")
            .cloned()
            .ok_or_else(|| BridgeError::Rejected("mux request has no id".into()))?;
        let mut line = serde_json::to_vec(request)?;
        line.push(b'\n');
        if mux_line_payload_len(&line) > MAX_MUX_LINE_BYTES.saturating_sub(1) {
            return Err(BridgeError::MuxLineTooLarge(line.len()));
        }
        let mut receiver = self.receiver.lock().await;
        if receiver.closed {
            return Err(BridgeError::Rejected("mux control stream is closed".into()));
        }
        let message = self.next_message.fetch_add(1, Ordering::Relaxed);
        if message == u64::MAX {
            return Err(BridgeError::MuxMessageIdsExhausted);
        }
        let lane = classify_client_line(&line);
        for packet in encode_line(message, &line)? {
            self.stream.send_on(lane, packet).await?;
        }
        loop {
            let chunk = match receiver.initial.pop_front() {
                Some(chunk) => Some(chunk),
                None => self.stream.receive().await?,
            };
            let Some(mut chunk) = chunk else {
                receiver.closed = true;
                return Err(BridgeError::Rejected("mux control stream closed".into()));
            };
            if !chunk.payload.is_empty() {
                let budget = chunk.take_budget();
                if let Some(assembled) =
                    receiver.assembler.push_retaining(chunk.lane, chunk.payload, budget)?
                    && let Some(reply) = reply_matching(assembled.payload(), &id)
                {
                    return Ok(reply);
                }
            }
            if chunk.finished || chunk.reset {
                receiver.closed = true;
                return Err(BridgeError::Rejected("mux control stream closed".into()));
            }
        }
    }

    pub async fn close(&self) -> Result<(), BridgeError> {
        self.receiver.lock().await.closed = true;
        self.stream.close().await?;
        Ok(())
    }
}

fn reply_matching(line: &Bytes, id: &Value) -> Option<Value> {
    let value = serde_json::from_slice::<Value>(line).ok()?;
    (value.get("id") == Some(id)).then_some(value)
}
