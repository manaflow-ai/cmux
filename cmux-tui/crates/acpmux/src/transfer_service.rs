//! A hub move's pages over the hub carrier (`hub/transfer_pull.rs`): the target dials the
//! source naming [`CircuitService::TransferSource`] and asks for each page; the source answers
//! only for a move whose `to-hub` is the dialer's Noise-proven key, and only while its own hub
//! book lists that machine as one of the person's (as `session_service.rs` checks).
//!
//! Each record either way is a big-endian `u32` length and that many bytes of JSON: a request
//! `{id, method: "read" | "renew", params}`, an answer `{id, result}` or `{id, error: {code,
//! message}}`. Nothing else runs on the circuit: it never reaches the WebSocket listener, so it
//! carries no connection origin and no other method.

use std::sync::{Arc, Weak};
use std::time::Duration;

use async_trait::async_trait;
use futures::future::BoxFuture;
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::hub::Hub;
use crate::hub::transfer_pull::{MAX_FRAME, PageSource, TransferDial};
use crate::hub_carrier::{CircuitService, HubStream, ServiceRefusal, TransferGate};
use crate::rpc::RpcError;

/// How long one page request waits for its answer.
const CALL_WAIT: Duration = Duration::from_secs(60);

/// One record: its length, then its JSON.
pub async fn write_frame<W: AsyncWrite + Unpin>(io: &mut W, value: &Value) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    let len = u32::try_from(bytes.len())
        .ok()
        .filter(|n| (*n as usize) <= MAX_FRAME)
        .ok_or_else(|| std::io::Error::other("a transfer record over its size bound"))?;
    io.write_u32(len).await?;
    io.write_all(&bytes).await?;
    io.flush().await
}

/// The next record, or None when the circuit closed (or sent one past its bound).
pub async fn read_frame<R: AsyncRead + Unpin>(io: &mut R) -> Option<Value> {
    let len = io.read_u32().await.ok()? as usize;
    if len > MAX_FRAME {
        return None;
    }
    let mut bytes = vec![0u8; len];
    io.read_exact(&mut bytes).await.ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Serves the requests of one circuit from `from` on `io`, by `hub`, until it closes.
pub async fn serve_pages<S: AsyncRead + AsyncWrite + Unpin>(hub: &Arc<Hub>, from: &str, mut io: S) {
    while let Some(request) = read_frame(&mut io).await {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request.get("method").and_then(Value::as_str).unwrap_or("");
        let params = request.get("params").cloned().unwrap_or(Value::Null);
        let answer = match hub.transfer_source_page(from, method, &params).await {
            Ok(result) => json!({"id": id, "result": result}),
            Err(error) => {
                json!({"id": id, "error": {"code": error.code, "message": error.message}})
            }
        };
        if write_frame(&mut io, &answer).await.is_err() {
            return;
        }
    }
}

/// The daemon's gate: its hub book must list the dialer as one of the person's machines.
pub struct ConfiguredTransferGate {
    hub: Weak<Hub>,
}

impl ConfiguredTransferGate {
    pub fn new(hub: &Arc<Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

#[async_trait]
impl TransferGate for ConfiguredTransferGate {
    async fn admit(&self, from: &str) -> Result<(), ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        // Beside the carrier's handshake (the platform's list of this person's machines): this
        // machine's own read of the hub's book must list the dialer too.
        if hub.mesh_book_machine(from).is_none() {
            return Err(ServiceRefusal::new(
                "machine.unlisted",
                "this machine's hub book does not list the asking machine for its account",
            ));
        }
        Ok(())
    }

    async fn serve(&self, from: String, io: tokio::io::DuplexStream) {
        if let Some(hub) = self.hub.upgrade() {
            serve_pages(&hub, &from, io).await;
        }
    }
}

/// The page requests of one circuit, from the target's side.
pub struct CircuitPages<S> {
    io: S,
    next: u64,
}

impl<S> CircuitPages<S> {
    pub fn new(io: S) -> Self {
        Self { io, next: 0 }
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin + Send> PageSource for CircuitPages<S> {
    fn call<'a>(
        &'a mut self,
        method: &'a str,
        params: Value,
    ) -> BoxFuture<'a, Result<Value, RpcError>> {
        Box::pin(async move {
            self.next += 1;
            let id = self.next;
            let lost =
                || RpcError::new(-32000, "transfer.unreachable: the source's circuit closed");
            let request = json!({"id": id, "method": method, "params": params});
            write_frame(&mut self.io, &request).await.map_err(|_| lost())?;
            let answer = tokio::time::timeout(CALL_WAIT, read_frame(&mut self.io))
                .await
                .map_err(|_| {
                    RpcError::new(-32000, "transfer.unreachable: the source did not answer in time")
                })?
                .ok_or_else(lost)?;
            if answer.get("id") != Some(&json!(id)) {
                return Err(RpcError::new(
                    -32000,
                    "transfer.read: the source answered out of order",
                ));
            }
            if let Some(error) = answer.get("error") {
                let code = error.get("code").and_then(Value::as_i64).unwrap_or(-32000);
                let message = error.get("message").and_then(Value::as_str).unwrap_or("refused");
                return Err(RpcError::new(code, message));
            }
            Ok(answer.get("result").cloned().unwrap_or(Value::Null))
        })
    }
}

/// The daemon's way to a hub move's source: its hub carrier, naming the transfer service.
pub struct CarrierDial {
    hub: Weak<Hub>,
}

impl CarrierDial {
    pub fn new(hub: &Arc<Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

impl TransferDial for CarrierDial {
    fn open<'a>(&'a self, daemon: &'a str) -> BoxFuture<'a, Result<Box<dyn PageSource>, String>> {
        Box::pin(async move {
            let hub = self.hub.upgrade().ok_or("stopping")?;
            let carrier =
                hub.hub_carrier.get().ok_or("this daemon's hub carrier is not running")?;
            let stream: HubStream =
                carrier.dial_service(daemon, CircuitService::TransferSource).await?;
            Ok(Box::new(CircuitPages::new(stream)) as Box<dyn PageSource>)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_record_round_trips_and_an_oversized_one_closes_the_reader() {
        let (mut a, mut b) = tokio::io::duplex(1 << 16);
        write_frame(&mut a, &json!({"id": 1, "method": "read"})).await.unwrap();
        assert_eq!(read_frame(&mut b).await, Some(json!({"id": 1, "method": "read"})));
        a.write_u32((MAX_FRAME + 1) as u32).await.unwrap();
        assert_eq!(read_frame(&mut b).await, None);
    }
}
