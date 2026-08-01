//! Framed service messages and the error type they share.
//!
//! These sit below the daemon's service handlers and above the raw carrier, so
//! both endpoints need them: `WorkspaceClient` reads process events through a
//! `MessageStream`, and every service path reports `ServicesError`. They lived
//! in `services`, which forced a client to compile the daemon's workspace
//! service -- and with it a Zig build of libghostty-vt -- to reach them. A
//! mobile client has no use for a server-side terminal model, so they live here
//! instead and `services` re-exports them.

use std::fmt;
use std::sync::Arc;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use cmux_remote_protocol::{Lane, Service};
use tokio::sync::Mutex;

use crate::service::{ServiceError, ServiceStream, StreamBudget};

/// Ceiling on one framed service message, matching the protocol's 16 MiB cap.
pub(crate) const MAX_RPC_MESSAGE: usize = 16 * 1024 * 1024;

pub struct MessageStream {
    stream: Arc<ServiceStream>,
    lane: Lane,
    read: Mutex<MessageReadState>,
    write: Mutex<()>,
}

struct MessageReadState {
    buffer: BytesMut,
    budgets: Vec<StreamBudget>,
    finished: bool,
}

impl MessageStream {
    pub fn new(stream: Arc<ServiceStream>) -> Self {
        let lane = match stream.service() {
            Service::MuxControl | Service::ComputerUse => Lane::Interactive,
            Service::ProcessStream => Lane::Bulk,
            Service::WorkspaceRpc => Lane::Control,
            Service::TcpTunnel => Lane::Tunnel,
        };
        Self::with_lane(stream, lane)
    }

    pub fn with_lane(stream: Arc<ServiceStream>, lane: Lane) -> Self {
        Self {
            stream,
            lane,
            read: Mutex::new(MessageReadState {
                buffer: BytesMut::new(),
                budgets: Vec::new(),
                finished: false,
            }),
            write: Mutex::new(()),
        }
    }

    pub async fn send(&self, message: &[u8]) -> Result<(), ServicesError> {
        let _guard = self.write.lock().await;
        if message.len() > MAX_RPC_MESSAGE {
            return Err(ServicesError::MessageTooLarge(message.len()));
        }
        let mut encoded = BytesMut::with_capacity(4 + message.len());
        encoded.put_u32(message.len() as u32);
        encoded.extend_from_slice(message);
        self.stream.send_on(self.lane, encoded.freeze()).await?;
        Ok(())
    }

    pub async fn receive(&self) -> Result<Option<Bytes>, ServicesError> {
        let mut state = self.read.lock().await;
        loop {
            if state.buffer.len() >= 4 {
                let size = u32::from_be_bytes(state.buffer[..4].try_into().unwrap()) as usize;
                if size > MAX_RPC_MESSAGE {
                    state.buffer.clear();
                    state.budgets.clear();
                    state.finished = true;
                    return Err(ServicesError::MessageTooLarge(size));
                }
                if state.buffer.len() >= 4 + size {
                    state.buffer.advance(4);
                    let message = state.buffer.split_to(size).freeze();
                    if state.buffer.is_empty() {
                        state.budgets.clear();
                    }
                    return Ok(Some(message));
                }
            }
            if state.finished {
                if state.buffer.is_empty() {
                    return Ok(None);
                }
                state.buffer.clear();
                state.budgets.clear();
                return Err(ServicesError::TruncatedMessage);
            }
            let received = self.stream.receive().await;
            let Some(mut chunk) = (match received {
                Ok(chunk) => chunk,
                Err(error) => {
                    state.buffer.clear();
                    state.budgets.clear();
                    state.finished = true;
                    return Err(error.into());
                }
            }) else {
                state.finished = true;
                continue;
            };
            if chunk.lane != self.lane {
                state.buffer.clear();
                state.budgets.clear();
                state.finished = true;
                return Err(ServicesError::UnexpectedLane {
                    expected: self.lane,
                    actual: chunk.lane,
                });
            }
            if chunk.reset {
                state.buffer.clear();
                state.budgets.clear();
                state.finished = true;
                return Err(ServicesError::Remote("stream was reset".into()));
            }
            state.buffer.extend_from_slice(&chunk.payload);
            if let Some(budget) = chunk.take_budget() {
                state.budgets.push(budget);
            }
            state.finished = chunk.finished;
        }
    }

    pub async fn close(&self) -> Result<(), ServicesError> {
        self.stream.close_on(self.lane).await?;
        Ok(())
    }
}


#[derive(Debug)]
pub enum ServicesError {
    Service(ServiceError),
    Json(serde_json::Error),
    Io(std::io::Error),
    Metadata(String),
    Remote(String),
    Unavailable(String),
    MessageTooLarge(usize),
    TruncatedMessage,
    MuxCodec(crate::mux_codec::MuxCodecError),
    MuxInput(crate::mux_input::MuxInputError),
    MessageIdsExhausted,
    RequestTask(tokio::task::JoinError),
    UnexpectedLane { expected: Lane, actual: Lane },
}

impl fmt::Display for ServicesError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Service(error) => error.fmt(formatter),
            Self::Json(error) => write!(formatter, "service JSON failed: {error}"),
            Self::Io(error) => write!(formatter, "service I/O failed: {error}"),
            Self::Metadata(message) => write!(formatter, "invalid service metadata: {message}"),
            Self::Remote(message) => write!(formatter, "remote service failed: {message}"),
            Self::Unavailable(message) => write!(formatter, "service unavailable: {message}"),
            Self::MessageTooLarge(size) => {
                write!(formatter, "service message is too large: {size}")
            }
            Self::TruncatedMessage => {
                formatter.write_str("service message ended before its declared length")
            }
            Self::MuxCodec(error) => error.fmt(formatter),
            Self::MuxInput(error) => error.fmt(formatter),
            Self::MessageIdsExhausted => {
                formatter.write_str("service message identifiers exhausted")
            }
            Self::RequestTask(error) => write!(formatter, "workspace request task failed: {error}"),
            Self::UnexpectedLane { expected, actual } => {
                write!(formatter, "service message used {actual:?} instead of {expected:?}")
            }
        }
    }
}

impl std::error::Error for ServicesError {}

impl From<ServiceError> for ServicesError {
    fn from(error: ServiceError) -> Self {
        Self::Service(error)
    }
}

impl From<serde_json::Error> for ServicesError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<std::io::Error> for ServicesError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<crate::mux_codec::MuxCodecError> for ServicesError {
    fn from(error: crate::mux_codec::MuxCodecError) -> Self {
        Self::MuxCodec(error)
    }
}

impl From<crate::mux_input::MuxInputError> for ServicesError {
    fn from(error: crate::mux_input::MuxInputError) -> Self {
        Self::MuxInput(error)
    }
}

