use std::collections::VecDeque;
use std::ffi::{CStr, c_char, c_void};
use std::path::PathBuf;
use std::sync::mpsc as std_mpsc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use iroh::{Endpoint, endpoint::presets};
use serde::Deserialize;
use tokio::io::AsyncWrite;
use tokio::sync::mpsc;
use tokio::task::JoinSet;

use crate::{
    BridgeNodeInfo, BridgeOptions, BridgePairingOptions, BridgeRelayMode, BridgeTicket,
    BridgeTicketAuth, CMUX_IROH_ALPN, connect_encoded_ticket, proxy_incoming,
    publishable_endpoint_addr, read_cmx_payload, write_cmx_payload,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
const HOST_START_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_PRECONNECT_SENDS: usize = 256;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmxIrohClientEventKind {
    Connected = 1,
    Message = 2,
    Closed = 3,
    Error = 4,
}

pub type CmxIrohClientCallback = unsafe extern "C" fn(
    user_data: *mut c_void,
    kind: CmxIrohClientEventKind,
    data: *const u8,
    len: usize,
);

pub struct CmxIrohClientHandle {
    commands: mpsc::UnboundedSender<CmxIrohClientCommand>,
    thread: Option<JoinHandle<()>>,
}

enum CmxIrohClientCommand {
    Send(Vec<u8>),
    Disconnect,
}

struct CmxIrohClientOptions {
    ticket: String,
    relay_mode: BridgeRelayMode,
    pairing_secret: Option<String>,
    callback: CmxIrohClientCallback,
    user_data: usize,
}

pub struct CmxIrohHostHandle {
    commands: mpsc::UnboundedSender<CmxIrohHostCommand>,
    thread: Option<JoinHandle<()>>,
}

enum CmxIrohHostCommand {
    Stop,
    Retire,
}

#[derive(Debug, Deserialize)]
struct CmxIrohHostStartConfig {
    socket_path: String,
    relay_mode: Option<u32>,
    pairing: Option<CmxIrohHostPairingConfig>,
    node: Option<BridgeNodeInfo>,
}

#[derive(Debug, Deserialize)]
struct CmxIrohHostPairingConfig {
    pairing_id: String,
    secret: String,
    rivet_endpoint: String,
    stack_project_id: String,
    expires_at_unix: u64,
}

impl CmxIrohHostStartConfig {
    fn into_bridge_options(self) -> Result<BridgeOptions> {
        let socket_path = self.socket_path.trim();
        if socket_path.is_empty() {
            bail!("missing cmx socket path");
        }
        Ok(BridgeOptions {
            cmx_socket_path: PathBuf::from(socket_path),
            relay_mode: ffi_relay_mode(self.relay_mode.unwrap_or(0)),
            pairing: self.pairing.map(Into::into),
            node: self.node,
        })
    }
}

impl From<CmxIrohHostPairingConfig> for BridgePairingOptions {
    fn from(value: CmxIrohHostPairingConfig) -> Self {
        BridgePairingOptions {
            pairing_id: value.pairing_id,
            secret: value.secret,
            rivet_endpoint: value.rivet_endpoint,
            stack_project_id: value.stack_project_id,
            expires_at_unix: value.expires_at_unix,
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_client_connect(
    ticket: *const c_char,
    pairing_secret: *const c_char,
    relay_mode: u32,
    callback: Option<CmxIrohClientCallback>,
    user_data: *mut c_void,
) -> *mut CmxIrohClientHandle {
    let Some(callback) = callback else {
        return std::ptr::null_mut();
    };
    let ticket = match read_required_c_string(ticket) {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };
    let pairing_secret = match read_optional_c_string(pairing_secret) {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };
    let (tx, rx) = mpsc::unbounded_channel();
    let options = CmxIrohClientOptions {
        ticket,
        relay_mode: ffi_relay_mode(relay_mode),
        pairing_secret,
        callback,
        user_data: user_data as usize,
    };
    let thread = match thread::Builder::new()
        .name("cmux-iroh-client".into())
        .spawn(move || run_client_thread(options, rx))
    {
        Ok(thread) => thread,
        Err(_) => return std::ptr::null_mut(),
    };

    Box::into_raw(Box::new(CmxIrohClientHandle {
        commands: tx,
        thread: Some(thread),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_client_send(
    handle: *mut CmxIrohClientHandle,
    data: *const u8,
    len: usize,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    if data.is_null() && len > 0 {
        return false;
    }
    let payload = if len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(data, len) }.to_vec()
    };
    handle
        .commands
        .send(CmxIrohClientCommand::Send(payload))
        .is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_client_disconnect(handle: *mut CmxIrohClientHandle) {
    if handle.is_null() {
        return;
    }
    let mut handle = unsafe { Box::from_raw(handle) };
    let _ = handle.commands.send(CmxIrohClientCommand::Disconnect);
    if let Some(thread) = handle.thread.take() {
        let _ = thread.join();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_host_start(
    config_json: *const c_char,
    ticket_out: *mut c_char,
    ticket_out_len: usize,
    error_out: *mut c_char,
    error_out_len: usize,
) -> *mut CmxIrohHostHandle {
    clear_c_string(ticket_out, ticket_out_len);
    clear_c_string(error_out, error_out_len);
    if ticket_out.is_null() || ticket_out_len == 0 {
        write_c_string(error_out, error_out_len, "missing ticket output buffer");
        return std::ptr::null_mut();
    }

    let options = match read_required_c_string(config_json)
        .and_then(|json| {
            serde_json::from_str::<CmxIrohHostStartConfig>(&json).context("decode host config")
        })
        .and_then(CmxIrohHostStartConfig::into_bridge_options)
    {
        Ok(options) => options,
        Err(error) => {
            write_c_string(error_out, error_out_len, &error.to_string());
            return std::ptr::null_mut();
        }
    };

    let (command_tx, command_rx) = mpsc::unbounded_channel();
    let (ready_tx, ready_rx) = std_mpsc::channel();
    let thread = match thread::Builder::new()
        .name("cmux-iroh-host".into())
        .spawn(move || run_host_thread(options, command_rx, ready_tx))
    {
        Ok(thread) => thread,
        Err(error) => {
            write_c_string(
                error_out,
                error_out_len,
                &format!("start iroh host thread: {error}"),
            );
            return std::ptr::null_mut();
        }
    };

    match ready_rx.recv_timeout(HOST_START_TIMEOUT) {
        Ok(Ok(ticket)) => {
            if !write_c_string(ticket_out, ticket_out_len, &ticket) {
                let _ = command_tx.send(CmxIrohHostCommand::Stop);
                write_c_string(error_out, error_out_len, "iroh host ticket is too large");
                return std::ptr::null_mut();
            }
            Box::into_raw(Box::new(CmxIrohHostHandle {
                commands: command_tx,
                thread: Some(thread),
            }))
        }
        Ok(Err(error)) => {
            write_c_string(error_out, error_out_len, &error);
            std::ptr::null_mut()
        }
        Err(std_mpsc::RecvTimeoutError::Timeout) => {
            let _ = command_tx.send(CmxIrohHostCommand::Stop);
            write_c_string(error_out, error_out_len, "starting iroh host timed out");
            std::ptr::null_mut()
        }
        Err(std_mpsc::RecvTimeoutError::Disconnected) => {
            write_c_string(
                error_out,
                error_out_len,
                "iroh host stopped before it was ready",
            );
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_host_stop(handle: *mut CmxIrohHostHandle) {
    if handle.is_null() {
        return;
    }
    let mut handle = unsafe { Box::from_raw(handle) };
    let _ = handle.commands.send(CmxIrohHostCommand::Stop);
    if let Some(thread) = handle.thread.take() {
        let _ = thread.join();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_iroh_host_retire(handle: *mut CmxIrohHostHandle) {
    if handle.is_null() {
        return;
    }
    let mut handle = unsafe { Box::from_raw(handle) };
    let _ = handle.commands.send(CmxIrohHostCommand::Retire);
    if let Some(host_thread) = handle.thread.take() {
        let _ = thread::Builder::new()
            .name("cmux-iroh-host-retire-join".into())
            .spawn(move || {
                let _ = host_thread.join();
            });
    }
}

fn ffi_relay_mode(value: u32) -> BridgeRelayMode {
    match value {
        1 => BridgeRelayMode::Disabled,
        _ => BridgeRelayMode::Default,
    }
}

fn run_host_thread(
    options: BridgeOptions,
    commands: mpsc::UnboundedReceiver<CmxIrohHostCommand>,
    ready: std_mpsc::Sender<Result<String, String>>,
) {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            let _ = ready.send(Err(format!("start iroh runtime: {error}")));
            return;
        }
    };

    if let Err(error) = runtime.block_on(run_host_async(options, commands, ready)) {
        tracing::warn!(?error, "embedded iroh host stopped with error");
    }
}

async fn run_host_async(
    options: BridgeOptions,
    mut commands: mpsc::UnboundedReceiver<CmxIrohHostCommand>,
    ready: std_mpsc::Sender<Result<String, String>>,
) -> Result<()> {
    if let Err(error) = validate_host_options(&options) {
        let _ = ready.send(Err(error.to_string()));
        return Err(error);
    }

    let endpoint = match Endpoint::builder(presets::N0)
        .alpns(vec![CMUX_IROH_ALPN.to_vec()])
        .relay_mode(options.relay_mode.as_iroh())
        .bind()
        .await
        .context("bind iroh endpoint")
    {
        Ok(endpoint) => endpoint,
        Err(error) => {
            let _ = ready.send(Err(error.to_string()));
            return Err(error);
        }
    };

    let ticket = match embedded_host_ticket(&endpoint, &options).await {
        Ok(ticket) => ticket,
        Err(error) => {
            endpoint.close().await;
            let _ = ready.send(Err(error.to_string()));
            return Err(error);
        }
    };
    let _ = ready.send(Ok(ticket));

    let mut connection_tasks = JoinSet::<Result<()>>::new();
    let mut retiring = false;
    let mut commands_closed = false;
    loop {
        if retiring && connection_tasks.is_empty() {
            break;
        }
        tokio::select! {
            command = commands.recv(), if !commands_closed => {
                match command {
                    Some(CmxIrohHostCommand::Stop) => {
                        endpoint.close().await;
                        connection_tasks.abort_all();
                        while connection_tasks.join_next().await.is_some() {}
                        return Ok(());
                    }
                    Some(CmxIrohHostCommand::Retire) => {
                        retiring = true;
                    }
                    None => {
                        commands_closed = true;
                        if !retiring {
                            break;
                        }
                    }
                }
            }
            incoming = endpoint.accept(), if !retiring => {
                let Some(incoming) = incoming else {
                    retiring = true;
                    continue;
                };
                let socket_path = options.cmx_socket_path.clone();
                let pairing = options.pairing.clone();
                connection_tasks.spawn(async move {
                    proxy_incoming(incoming, socket_path, pairing).await
                });
            }
            completed = connection_tasks.join_next(), if !connection_tasks.is_empty() => {
                match completed {
                    Some(Ok(Ok(()))) => {}
                    Some(Ok(Err(error))) => {
                        tracing::warn!(?error, "embedded iroh host connection failed");
                    }
                    Some(Err(error)) => {
                        tracing::warn!(?error, "embedded iroh host connection task failed");
                    }
                    None => {}
                }
            }
        }
    }

    endpoint.close().await;
    Ok(())
}

fn validate_host_options(options: &BridgeOptions) -> Result<()> {
    if let Some(pairing) = &options.pairing {
        pairing.validate()?;
    }
    if let Some(node) = &options.node {
        node.validate()?;
    }
    Ok(())
}

async fn embedded_host_ticket(endpoint: &Endpoint, options: &BridgeOptions) -> Result<String> {
    let addr = publishable_endpoint_addr(endpoint, options.relay_mode).await;
    let ticket_auth = options
        .pairing
        .as_ref()
        .map(BridgePairingOptions::ticket_auth)
        .unwrap_or(BridgeTicketAuth::Direct);
    BridgeTicket::new_with_node(addr, ticket_auth, options.node.clone()).encode()
}

fn run_client_thread(
    options: CmxIrohClientOptions,
    commands: mpsc::UnboundedReceiver<CmxIrohClientCommand>,
) {
    let callback = options.callback;
    let user_data = options.user_data;
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            emit_error(callback, user_data, anyhow!("start iroh runtime: {error}"));
            return;
        }
    };

    if let Err(error) = runtime.block_on(run_client_async(options, commands)) {
        emit_error(callback, user_data, error);
    }
}

async fn run_client_async(
    options: CmxIrohClientOptions,
    mut commands: mpsc::UnboundedReceiver<CmxIrohClientCommand>,
) -> Result<()> {
    let callback = options.callback;
    let user_data = options.user_data;
    let mut pending_sends = VecDeque::new();
    let connect = tokio::time::timeout(
        CONNECT_TIMEOUT,
        connect_encoded_ticket(&options.ticket, options.relay_mode, options.pairing_secret),
    );
    tokio::pin!(connect);

    let client = loop {
        tokio::select! {
            connected = &mut connect => {
                break connected.context("iroh connect timed out")??;
            }
            command = commands.recv() => {
                match command {
                    Some(CmxIrohClientCommand::Send(payload)) => {
                        if pending_sends.len() >= MAX_PRECONNECT_SENDS {
                            bail!("too many cmx frames queued before iroh connected");
                        }
                        pending_sends.push_back(payload);
                    }
                    Some(CmxIrohClientCommand::Disconnect) | None => {
                        return Ok(());
                    }
                }
            }
        }
    };
    emit_event(callback, user_data, CmxIrohClientEventKind::Connected, &[]);
    let crate::BridgeClientConnection {
        endpoint,
        connection: _connection,
        send,
        mut recv,
    } = client;
    let (write_tx, mut write_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let mut writer = tokio::spawn(async move {
        let mut send = send;
        while let Some(payload) = write_rx.recv().await {
            write_client_payload(&mut send, &payload).await?;
        }
        Ok::<(), anyhow::Error>(())
    });
    while let Some(payload) = pending_sends.pop_front() {
        write_tx
            .send(payload)
            .map_err(|_| anyhow!("iroh writer stopped before pending send flushed"))?;
    }

    loop {
        tokio::select! {
            command = commands.recv() => {
                match command {
                    Some(CmxIrohClientCommand::Send(payload)) => {
                        write_tx
                            .send(payload)
                            .map_err(|_| anyhow!("iroh writer stopped"))?;
                    }
                    Some(CmxIrohClientCommand::Disconnect) | None => {
                        break;
                    }
                }
            }
            payload = read_cmx_payload(&mut recv) => {
                match payload.context("read cmx frame over iroh")? {
                    Some(payload) => emit_event(callback, user_data, CmxIrohClientEventKind::Message, &payload),
                    None => break,
                }
            }
            writer_result = &mut writer => {
                writer_result
                    .context("iroh writer task panicked")?
                    .context("write cmx frame over iroh")?;
                break;
            }
        }
    }

    drop(write_tx);
    if !writer.is_finished() {
        tokio::time::timeout(SEND_TIMEOUT, &mut writer)
            .await
            .context("wait for iroh writer to finish timed out")?
            .context("iroh writer task panicked")?
            .context("write cmx frame over iroh")?;
    }
    endpoint.close().await;
    emit_event(callback, user_data, CmxIrohClientEventKind::Closed, &[]);
    Ok(())
}

async fn write_client_payload<W>(writer: &mut W, payload: &[u8]) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    tokio::time::timeout(SEND_TIMEOUT, write_cmx_payload(writer, payload))
        .await
        .context("send cmx frame over iroh timed out")?
        .context("send cmx frame over iroh")
}

fn emit_error(callback: CmxIrohClientCallback, user_data: usize, error: anyhow::Error) {
    emit_event(
        callback,
        user_data,
        CmxIrohClientEventKind::Error,
        error.to_string().as_bytes(),
    );
}

fn emit_event(
    callback: CmxIrohClientCallback,
    user_data: usize,
    kind: CmxIrohClientEventKind,
    data: &[u8],
) {
    unsafe {
        callback(user_data as *mut c_void, kind, data.as_ptr(), data.len());
    }
}

fn read_required_c_string(value: *const c_char) -> Result<String> {
    if value.is_null() {
        bail!("missing C string");
    }
    let string = unsafe { CStr::from_ptr(value) }
        .to_str()
        .context("C string is not UTF-8")?;
    Ok(string.to_owned())
}

fn read_optional_c_string(value: *const c_char) -> Result<Option<String>> {
    if value.is_null() {
        return Ok(None);
    }
    let string = unsafe { CStr::from_ptr(value) }
        .to_str()
        .context("C string is not UTF-8")?;
    if string.trim().is_empty() {
        Ok(None)
    } else {
        Ok(Some(string.to_owned()))
    }
}

fn clear_c_string(buffer: *mut c_char, len: usize) {
    if buffer.is_null() || len == 0 {
        return;
    }
    unsafe {
        *buffer = 0;
    }
}

fn write_c_string(buffer: *mut c_char, len: usize, value: &str) -> bool {
    if buffer.is_null() || len == 0 {
        return false;
    }
    let bytes = value.as_bytes();
    let copy_len = bytes.len().min(len - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr().cast::<c_char>(), buffer, copy_len);
        *buffer.add(copy_len) = 0;
    }
    bytes.len() < len
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    use tokio::io::AsyncWriteExt;
    use tokio::net::UnixListener;

    #[tokio::test]
    async fn host_ffi_starts_ticket_and_proxies_to_unix_socket() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let socket_path = dir.path().join("cmx.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let unix_server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            let input = read_cmx_payload(&mut socket)
                .await?
                .context("expected framed input")?;
            assert_eq!(input, b"hello ffi");
            write_cmx_payload(&mut socket, b"hello host").await?;
            Result::<()>::Ok(())
        });

        let config = serde_json::json!({
            "socket_path": socket_path,
            "relay_mode": 1,
            "node": {
                "id": "node-ffi",
                "name": "Mac",
                "subtitle": "ffi test",
                "kind": "macos"
            }
        });
        let config = CString::new(config.to_string())?;
        let mut ticket = vec![0 as c_char; 64 * 1024];
        let mut error = vec![0 as c_char; 4096];
        let handle = unsafe {
            cmux_iroh_host_start(
                config.as_ptr(),
                ticket.as_mut_ptr(),
                ticket.len(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        assert!(
            !handle.is_null(),
            "host start failed: {}",
            unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy()
        );

        let ticket = unsafe { CStr::from_ptr(ticket.as_ptr()) }.to_str()?;
        let mut client = connect_encoded_ticket(ticket, BridgeRelayMode::Disabled, None).await?;
        client.write_payload(b"hello ffi").await?;
        let output = client
            .read_payload()
            .await?
            .context("expected framed output")?;
        assert_eq!(output, b"hello host");

        client.send.shutdown().await?;
        client.endpoint.close().await;
        unsafe {
            cmux_iroh_host_stop(handle);
        }
        unix_server.await??;
        Ok(())
    }

    #[tokio::test]
    async fn host_ffi_retire_keeps_active_stream_alive() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let socket_path = dir.path().join("cmx.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let unix_server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            let first = read_cmx_payload(&mut socket)
                .await?
                .context("expected first framed input")?;
            assert_eq!(first, b"first");
            write_cmx_payload(&mut socket, b"first ok").await?;

            let second = read_cmx_payload(&mut socket)
                .await?
                .context("expected second framed input")?;
            assert_eq!(second, b"second");
            write_cmx_payload(&mut socket, b"second ok").await?;
            Result::<()>::Ok(())
        });

        let config = serde_json::json!({
            "socket_path": socket_path,
            "relay_mode": 1,
            "node": {
                "id": "node-retire",
                "name": "Mac",
                "subtitle": "retire test",
                "kind": "macos"
            }
        });
        let config = CString::new(config.to_string())?;
        let mut ticket = vec![0 as c_char; 64 * 1024];
        let mut error = vec![0 as c_char; 4096];
        let handle = unsafe {
            cmux_iroh_host_start(
                config.as_ptr(),
                ticket.as_mut_ptr(),
                ticket.len(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        assert!(
            !handle.is_null(),
            "host start failed: {}",
            unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy()
        );

        let ticket = unsafe { CStr::from_ptr(ticket.as_ptr()) }.to_str()?;
        let mut client = connect_encoded_ticket(ticket, BridgeRelayMode::Disabled, None).await?;
        client.write_payload(b"first").await?;
        let first_output = client
            .read_payload()
            .await?
            .context("expected first framed output")?;
        assert_eq!(first_output, b"first ok");

        unsafe {
            cmux_iroh_host_retire(handle);
        }

        client.write_payload(b"second").await?;
        let second_output = client
            .read_payload()
            .await?
            .context("expected second framed output")?;
        assert_eq!(second_output, b"second ok");

        client.send.shutdown().await?;
        client.endpoint.close().await;
        unix_server.await??;
        Ok(())
    }
}
