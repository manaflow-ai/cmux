//! Private desktop-app protocol adapter. These method names are not part of
//! the public cmux.protocol/2 resource vocabulary.

#[cfg(unix)]
use crate::localization::catalog;
#[cfg(unix)]
use serde_json::{Value, json};

pub(in crate::cli) enum Operation {
    List,
    Catalog,
    TerminalNew,
    TerminalRead,
    TerminalClose,
    TerminalWrite,
    RemoteInfo,
}

impl Operation {
    #[cfg(unix)]
    fn name(self) -> &'static str {
        match self {
            Self::List => "vm.list",
            Self::Catalog => "surface.catalog",
            Self::TerminalNew => "vm.terminal_new",
            Self::TerminalRead => "vm.terminal_read",
            Self::TerminalClose => "vm.terminal_close",
            Self::TerminalWrite => "vm.terminal_write",
            Self::RemoteInfo => "vm.cmux_remote_info",
        }
    }
}

#[derive(Debug)]
pub(super) struct AppFailure {
    pub(super) code: String,
    pub(super) message: String,
}

impl std::fmt::Display for AppFailure {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(out, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for AppFailure {}

#[cfg(unix)]
pub(super) fn request(
    socket: &std::path::Path,
    method: Operation,
    params: Value,
    timeout: std::time::Duration,
) -> anyhow::Result<Value> {
    use anyhow::Context;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(async {
        tokio::select! {
            result = tokio::time::timeout(timeout, app_exchange(socket, method.name(), params)) => {
                result.context(catalog().cloud_vm.read_failed)?
            }
            result = crate::wait_for_shutdown_signal_async() => {
                result?;
                Err(anyhow::anyhow!(catalog().cloud_vm.read_failed))
            }
        }
    })
}

#[cfg(unix)]
async fn app_exchange(
    socket: &std::path::Path,
    method: &str,
    params: Value,
) -> anyhow::Result<Value> {
    use anyhow::{Context, ensure};
    use tokio::io::BufReader;
    use tokio::net::UnixStream;

    let messages = &catalog().cloud_vm;
    let stream = UnixStream::connect(socket).await.context(messages.app_required)?;
    cmux_remote::admin::verify_unix_peer_owner(&stream).context(messages.invalid_owner)?;
    let mut reader = BufReader::new(stream);
    let capability = std::env::var("CMUX_SOCKET_CAPABILITY").ok().filter(|v| !v.is_empty());
    if let Some(capability) = &capability {
        ensure!(!capability.chars().any(char::is_whitespace), messages.invalid_auth);
    }
    if let Some(password) = std::env::var("CMUX_SOCKET_PASSWORD").ok().filter(|v| !v.is_empty()) {
        ensure!(!password.contains(['\n', '\r']), messages.invalid_auth);
        app_send(&mut reader, &format!("auth {password}"), capability.as_deref()).await?;
        let auth = app_receive(&mut reader).await?;
        ensure!(auth.starts_with(b"OK"), messages.auth_failed);
    }
    let id = uuid::Uuid::new_v4().to_string();
    let line = serde_json::to_string(&json!({"id":id,"method":method,"params":params}))?;
    ensure!(line.len() <= 4 * 1024 * 1024, messages.request_too_large);
    app_send(&mut reader, &line, capability.as_deref()).await?;
    let bytes = app_receive(&mut reader).await?;
    ensure!(!bytes.starts_with(b"ERROR:"), messages.auth_failed);
    let response: Value = serde_json::from_slice(&bytes).context(messages.invalid_response)?;
    ensure!(response["id"].as_str() == Some(&id), messages.invalid_response);
    if response["ok"].as_bool() != Some(true) {
        let error = &response["error"];
        return Err(AppFailure {
            code: error["code"].as_str().unwrap_or("cloud.failed").to_owned(),
            message: error["message"].as_str().unwrap_or(messages.invalid_response).to_owned(),
        }
        .into());
    }
    ensure!(response["result"].is_object(), messages.invalid_response);
    Ok(response["result"].clone())
}

#[cfg(unix)]
async fn app_send(
    reader: &mut tokio::io::BufReader<tokio::net::UnixStream>,
    line: &str,
    capability: Option<&str>,
) -> anyhow::Result<()> {
    use tokio::io::AsyncWriteExt;
    if let Some(capability) = capability {
        reader.get_mut().write_all(format!("_cmux_capability_v1 {capability} ").as_bytes()).await?;
    }
    reader.get_mut().write_all(line.as_bytes()).await?;
    reader.get_mut().write_all(b"\n").await?;
    reader.get_mut().flush().await?;
    Ok(())
}

#[cfg(unix)]
async fn app_receive(
    reader: &mut tokio::io::BufReader<tokio::net::UnixStream>,
) -> anyhow::Result<Vec<u8>> {
    use anyhow::{Context, ensure};
    use tokio::io::{AsyncBufReadExt, AsyncReadExt};
    const MAX_RESPONSE: u64 = 16 * 1024 * 1024;
    let messages = &catalog().cloud_vm;
    let mut bytes = Vec::new();
    reader
        .take(MAX_RESPONSE + 1)
        .read_until(b'\n', &mut bytes)
        .await
        .context(messages.read_failed)?;
    ensure!(
        bytes.len() as u64 <= MAX_RESPONSE && bytes.last() == Some(&b'\n'),
        messages.invalid_response
    );
    Ok(bytes)
}
