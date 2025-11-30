use std::io;
use std::sync::Arc;

use agent_client_protocol::{
    Agent, ClientCapabilities, ClientSideConnection, FileSystemCapability, InitializeRequest,
    NewSessionRequest, SessionId, SessionModelState, V1,
};
use anyhow::Result;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;

use crate::acp_client::client::AppClient;
use crate::acp_client::events::AppEvent;
use crate::acp_client::logging::log_debug;
use crate::acp_client::provider::AcpProvider;

/// WebSocket reader wrapper for ACP protocol
struct WsRead {
    stream: futures::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
    tx: mpsc::UnboundedSender<AppEvent>,
}

/// WebSocket writer wrapper for ACP protocol
struct WsWrite {
    sink: futures::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        tokio_tungstenite::tungstenite::Message,
    >,
    tx: mpsc::UnboundedSender<AppEvent>,
}

// Wrappers for AsyncRead/AsyncWrite
pub(crate) struct TokioCompatRead<T>(pub(crate) T);

impl<T: tokio::io::AsyncRead + Unpin> futures::io::AsyncRead for TokioCompatRead<T> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut [u8],
    ) -> std::task::Poll<io::Result<usize>> {
        let mut read_buf = tokio::io::ReadBuf::new(buf);
        futures::ready!(std::pin::Pin::new(&mut self.0).poll_read(cx, &mut read_buf))?;
        std::task::Poll::Ready(Ok(read_buf.filled().len()))
    }
}

pub(crate) struct TokioCompatWrite<T>(pub(crate) T);

impl<T: tokio::io::AsyncWrite + Unpin> futures::io::AsyncWrite for TokioCompatWrite<T> {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        std::pin::Pin::new(&mut self.0).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::pin::Pin::new(&mut self.0).poll_flush(cx)
    }

    fn poll_close(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        std::pin::Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

impl tokio::io::AsyncRead for WsRead {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        loop {
            match futures::ready!(self.stream.poll_next_unpin(cx)) {
                Some(Ok(tokio_tungstenite::tungstenite::Message::Binary(data))) => {
                    let msg = String::from_utf8_lossy(&data).to_string();
                    let _ = self.tx.send(AppEvent::DebugMessage {
                        direction: "←".to_string(),
                        message: msg,
                    });
                    buf.put_slice(&data);
                    return std::task::Poll::Ready(Ok(()));
                }
                Some(Ok(tokio_tungstenite::tungstenite::Message::Text(data))) => {
                    log_debug(&format!("RECV TEXT: {}", data));
                    let _ = self.tx.send(AppEvent::DebugMessage {
                        direction: "←".to_string(),
                        message: data.clone(),
                    });
                    buf.put_slice(data.as_bytes());
                    return std::task::Poll::Ready(Ok(()));
                }
                Some(Ok(tokio_tungstenite::tungstenite::Message::Close(_))) | None => {
                    log_debug("RECV EOF");
                    return std::task::Poll::Ready(Ok(()));
                }
                Some(Err(e)) => {
                    log_debug(&format!("RECV Error: {}", e));
                    return std::task::Poll::Ready(Err(io::Error::other(e)));
                }
                _ => continue,
            }
        }
    }
}

impl tokio::io::AsyncWrite for WsWrite {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        let msg = String::from_utf8_lossy(buf).to_string();
        log_debug(&format!("SEND: {:?}", msg));
        let _ = self.tx.send(AppEvent::DebugMessage {
            direction: "→".to_string(),
            message: msg,
        });
        match self
            .sink
            .start_send_unpin(tokio_tungstenite::tungstenite::Message::Binary(
                buf.to_vec(),
            )) {
            Ok(_) => {
                match self.sink.poll_flush_unpin(cx) {
                    std::task::Poll::Ready(Ok(_)) => log_debug("Auto-flush success"),
                    std::task::Poll::Ready(Err(e)) => {
                        log_debug(&format!("Auto-flush error: {}", e))
                    }
                    std::task::Poll::Pending => log_debug("Auto-flush pending"),
                }
                std::task::Poll::Ready(Ok(buf.len()))
            }
            Err(e) => std::task::Poll::Ready(Err(io::Error::other(e))),
        }
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        log_debug("FLUSH");
        self.sink.poll_flush_unpin(cx).map_err(io::Error::other)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        self.sink.poll_close_unpin(cx).map_err(io::Error::other)
    }
}

/// Connect to an ACP provider and return the connection, session ID, and model state.
/// This function can be called from background tasks for provider switching.
pub(crate) async fn connect_to_provider(
    base_url: &str,
    sandbox_id: &str,
    provider: AcpProvider,
    tx: mpsc::UnboundedSender<AppEvent>,
) -> Result<(
    Arc<ClientSideConnection>,
    SessionId,
    Option<SessionModelState>,
)> {
    log_debug(&format!(
        "Connecting to provider: {}",
        provider.display_name()
    ));

    let ws_url = base_url
        .replace("http://", "ws://")
        .replace("https://", "wss://")
        .trim_end_matches('/')
        .to_string();

    let command = provider.command();
    let encoded_command =
        url::form_urlencoded::byte_serialize(command.as_bytes()).collect::<String>();

    let url = format!(
        "{}/sandboxes/{}/attach?cols=80&rows=24&tty=false&command={}",
        ws_url, sandbox_id, encoded_command
    );
    log_debug(&format!("Connecting to: {}", url));

    let (ws_stream, _) = tokio_tungstenite::connect_async(url).await?;
    log_debug("WebSocket connected");

    let (write, read) = ws_stream.split();

    let (client_conn, io_task) = ClientSideConnection::new(
        Arc::new(AppClient { tx: tx.clone() }),
        TokioCompatWrite(WsWrite {
            sink: write,
            tx: tx.clone(),
        }),
        TokioCompatRead(WsRead {
            stream: read,
            tx: tx.clone(),
        }),
        Box::new(|fut| {
            tokio::task::spawn_local(fut);
        }),
    );
    let client_conn = Arc::new(client_conn);

    tokio::task::spawn_local(async move {
        if let Err(e) = io_task.await {
            log_debug(&format!("IO Task Error: {}", e));
        } else {
            log_debug("IO Task Finished");
        }
    });

    log_debug("Sending Initialize...");
    client_conn
        .initialize(InitializeRequest {
            protocol_version: V1,
            client_capabilities: ClientCapabilities {
                fs: FileSystemCapability {
                    read_text_file: true,
                    write_text_file: true,
                    meta: None,
                },
                terminal: false,
                meta: None,
            },
            client_info: None,
            meta: None,
        })
        .await?;
    log_debug("Initialize complete");

    log_debug("Starting New Session...");
    let new_session_res = client_conn
        .new_session(NewSessionRequest {
            cwd: std::path::PathBuf::from("/workspace"),
            mcp_servers: vec![],
            meta: None,
        })
        .await?;
    log_debug(&format!(
        "New Session started, models: {:?}",
        new_session_res.models
    ));

    Ok((
        client_conn,
        new_session_res.session_id,
        new_session_res.models,
    ))
}

/// Fetch models from a provider without keeping the connection.
/// Used for background model discovery.
pub(crate) async fn fetch_provider_models(
    base_url: &str,
    sandbox_id: &str,
    provider: AcpProvider,
    tx: mpsc::UnboundedSender<AppEvent>,
) {
    log_debug(&format!(
        "Fetching models for provider: {}",
        provider.display_name()
    ));

    // Create a dummy tx for the connection (we don't care about debug messages)
    let dummy_tx = tx.clone();

    match connect_to_provider(base_url, sandbox_id, provider, dummy_tx).await {
        Ok((_connection, _session_id, model_state)) => {
            let models: Vec<(String, String)> = model_state
                .map(|state| {
                    state
                        .available_models
                        .into_iter()
                        .map(|m| (m.model_id.0.to_string(), m.name))
                        .collect()
                })
                .unwrap_or_default();

            log_debug(&format!(
                "Loaded {} models for {}",
                models.len(),
                provider.display_name()
            ));

            let _ = tx.send(AppEvent::ProviderModelsLoaded { provider, models });
            // Connection will be dropped here, closing the websocket
        }
        Err(e) => {
            log_debug(&format!(
                "Failed to fetch models for {}: {}",
                provider.display_name(),
                e
            ));
            let _ = tx.send(AppEvent::ProviderModelsLoadFailed { provider });
        }
    }
}
