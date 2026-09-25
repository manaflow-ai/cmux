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
use crate::mux_codec::{MAX_MUX_DOWNLOAD_LINE_BYTES, MAX_MUX_LINE_BYTES, MuxLineAssembler, encode_line, mux_line_payload_len};
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
        let id = request.get("id").cloned().ok_or_else(|| {
            BridgeError::Rejected("mux request has no id".into())
        })?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::service::{EndpointRole, SessionEndpoint};
    use crate::session::ReceivedFrame;
    use cmux_remote_protocol::{FrameFlags, Lane, ServiceControl};
    use std::sync::atomic::AtomicU64;
    use tokio::sync::{Mutex as AsyncMutex, mpsc, watch};

    struct TestEndpoint {
        outgoing: mpsc::Sender<ReceivedFrame>,
        incoming: AsyncMutex<mpsc::Receiver<ReceivedFrame>>,
        sequence: AtomicU64,
        generation: watch::Sender<u64>,
    }

    #[async_trait::async_trait]
    impl SessionEndpoint for TestEndpoint {
        async fn send_frame(
            &self,
            _generation: Option<u64>,
            lane: Lane,
            stream: u64,
            payload: Bytes,
            flags: FrameFlags,
        ) -> Result<u64, crate::service::ServiceError> {
            let sequence = self.sequence.fetch_add(1, Ordering::Relaxed) + 1;
            self.outgoing
                .send(ReceivedFrame { generation: 0, lane, stream, sequence, flags, payload })
                .await
                .map_err(|_| crate::service::ServiceError::Closed)?;
            Ok(sequence)
        }

        async fn receive_frame(
            &self,
        ) -> Result<Option<ReceivedFrame>, crate::service::ServiceError> {
            Ok(self.incoming.lock().await.recv().await)
        }

        fn subscribe_generation(&self) -> watch::Receiver<u64> {
            self.generation.subscribe()
        }

        async fn close_session(&self) -> Result<(), crate::service::ServiceError> {
            Ok(())
        }
    }

    fn endpoint_pair() -> (Arc<TestEndpoint>, Arc<TestEndpoint>) {
        let (left_tx, left_rx) = mpsc::channel(64);
        let (right_tx, right_rx) = mpsc::channel(64);
        let (left_generation, _) = watch::channel(0);
        let (right_generation, _) = watch::channel(0);
        (
            Arc::new(TestEndpoint {
                outgoing: left_tx,
                incoming: AsyncMutex::new(right_rx),
                sequence: AtomicU64::new(0),
                generation: left_generation,
            }),
            Arc::new(TestEndpoint {
                outgoing: right_tx,
                incoming: AsyncMutex::new(left_rx),
                sequence: AtomicU64::new(0),
                generation: right_generation,
            }),
        )
    }

    #[tokio::test]
    async fn request_reply_matches_on_id_and_skips_unsolicited_lines() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let daemon_task = tokio::spawn({
            let daemon = daemon.clone();
            async move {
                let incoming = daemon.accept().await.unwrap().unwrap();
                let opened =
                    serde_json::to_vec(&ServiceControl::Opened { service: Service::MuxControl })
                        .unwrap();
                for lane in [Lane::Interactive, Lane::Control, Lane::Bulk] {
                    incoming.stream.send_on(lane, Bytes::from(opened.clone())).await.unwrap();
                }
                // The request arrives as codec packets on the control lane.
                let chunk = incoming.stream.receive().await.unwrap().unwrap();
                let mut assembler = MuxLineAssembler::<()>::default();
                let (lane, line) = assembler.push(chunk.lane, chunk.payload).unwrap().unwrap();
                assert_eq!(lane, Lane::Control);
                let request: Value = serde_json::from_slice(&line).unwrap();
                assert_eq!(request["operation"], "terminal.list");
                let noise = b"{\"type\":\"event\",\"id\":\"other\"}\n";
                for packet in encode_line(7, noise).unwrap() {
                    incoming.stream.send_on(Lane::Control, packet).await.unwrap();
                }
                let reply = serde_json::json!({
                    "protocol": "cmux.protocol/2", "type": "response",
                    "id": request["id"], "ok": true, "result": []
                });
                let mut reply_line = serde_json::to_vec(&reply).unwrap();
                reply_line.push(b'\n');
                for packet in encode_line(8, &reply_line).unwrap() {
                    incoming.stream.send_on(Lane::Control, packet).await.unwrap();
                }
                // Keep the daemon side open until the client has closed, so
                // the close below is a clean close rather than a peer reset.
                incoming.stream
            }
        });
        let mux = MuxLineClient::open(&client).await.unwrap();
        let reply = mux
            .request(&serde_json::json!({
                "protocol": "cmux.protocol/2", "type": "request", "id": "req-1",
                "operation": "terminal.list",
                "params": {"machine": "current", "session": "current"}
            }))
            .await
            .unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["result"], serde_json::json!([]));
        let daemon_stream = daemon_task.await.unwrap();
        mux.close().await.unwrap();
        drop(daemon_stream);
        client.shutdown().await;
        daemon.shutdown().await;
    }

    #[tokio::test]
    async fn request_without_id_is_rejected_before_sending() {
        let (client_endpoint, daemon_endpoint) = endpoint_pair();
        let client = ServiceMultiplexer::new(client_endpoint, EndpointRole::Client);
        let daemon = ServiceMultiplexer::new(daemon_endpoint, EndpointRole::Daemon);
        let daemon_task = tokio::spawn({
            let daemon = daemon.clone();
            async move {
                let incoming = daemon.accept().await.unwrap().unwrap();
                let opened =
                    serde_json::to_vec(&ServiceControl::Opened { service: Service::MuxControl })
                        .unwrap();
                for lane in [Lane::Interactive, Lane::Control, Lane::Bulk] {
                    incoming.stream.send_on(lane, Bytes::from(opened.clone())).await.unwrap();
                }
                incoming.stream
            }
        });
        let mux = MuxLineClient::open(&client).await.unwrap();
        let _daemon_stream = daemon_task.await.unwrap();
        let error = mux.request(&serde_json::json!({"operation": "x"})).await.unwrap_err();
        assert!(error.to_string().contains("no id"), "{error}");
        mux.close().await.unwrap();
        client.shutdown().await;
        daemon.shutdown().await;
    }
}
