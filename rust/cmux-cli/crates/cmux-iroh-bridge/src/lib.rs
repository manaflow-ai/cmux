#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

pub mod ffi;

use std::io::{ErrorKind, IsTerminal, Write as _};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use hmac::{Hmac, Mac};
use iroh::{Endpoint, EndpointAddr, RelayMode, Watcher, endpoint::presets};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use tokio::io::{self, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::UnixStream;

pub const CMUX_IROH_ALPN: &[u8] = b"/cmux/cmx/3";
const MAX_AUTH_FRAME_BYTES: usize = 4096;
const MAX_CMX_FRAME_BYTES: usize = 64 * 1024 * 1024;
const RELAY_ADDR_WAIT: Duration = Duration::from_secs(5);
type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BridgeTicket {
    pub version: u32,
    pub alpn: String,
    pub endpoint: EndpointAddr,
    pub auth: BridgeTicketAuth,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node: Option<BridgeNodeInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum BridgeTicketAuth {
    Direct,
    RivetStack {
        pairing_id: String,
        rivet_endpoint: String,
        stack_project_id: String,
        expires_at_unix: u64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BridgeNodeInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

impl BridgeNodeInfo {
    pub fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty() {
            bail!("missing node name");
        }
        if self
            .id
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
        {
            bail!("empty node id");
        }
        if self
            .kind
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
        {
            bail!("empty node kind");
        }
        Ok(())
    }
}

impl BridgeTicket {
    pub const VERSION: u32 = 1;

    pub fn new(endpoint: EndpointAddr, auth: BridgeTicketAuth) -> Self {
        Self::new_with_node(endpoint, auth, None)
    }

    pub fn new_with_node(
        endpoint: EndpointAddr,
        auth: BridgeTicketAuth,
        node: Option<BridgeNodeInfo>,
    ) -> Self {
        Self {
            version: Self::VERSION,
            alpn: String::from_utf8_lossy(CMUX_IROH_ALPN).into_owned(),
            endpoint,
            auth,
            node,
        }
    }

    pub fn encode(&self) -> Result<String> {
        Ok(serde_json::to_string(self)?)
    }

    pub fn decode(encoded: &str) -> Result<Self> {
        let ticket: Self = serde_json::from_str(encoded).context("decode bridge ticket")?;
        if ticket.version != Self::VERSION {
            bail!("unsupported bridge ticket version {}", ticket.version);
        }
        if ticket.alpn.as_bytes() != CMUX_IROH_ALPN {
            bail!("unsupported bridge ALPN {}", ticket.alpn);
        }
        ticket.auth.validate()?;
        if let Some(node) = &ticket.node {
            node.validate()?;
        }
        Ok(ticket)
    }
}

impl BridgeTicketAuth {
    fn validate(&self) -> Result<()> {
        match self {
            Self::Direct => Ok(()),
            Self::RivetStack {
                pairing_id,
                rivet_endpoint,
                stack_project_id,
                expires_at_unix,
            } => {
                if pairing_id.trim().is_empty() {
                    bail!("missing Rivet pairing id");
                }
                if rivet_endpoint.trim().is_empty() {
                    bail!("missing Rivet endpoint");
                }
                if stack_project_id.trim().is_empty() {
                    bail!("missing Stack project id");
                }
                if *expires_at_unix == 0 {
                    bail!("missing pairing expiration");
                }
                Ok(())
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct BridgeOptions {
    pub cmx_socket_path: PathBuf,
    pub relay_mode: BridgeRelayMode,
    pub pairing: Option<BridgePairingOptions>,
    pub node: Option<BridgeNodeInfo>,
}

#[derive(Debug, Clone)]
pub struct BridgePairingOptions {
    pub pairing_id: String,
    pub secret: String,
    pub rivet_endpoint: String,
    pub stack_project_id: String,
    pub expires_at_unix: u64,
}

impl BridgePairingOptions {
    fn ticket_auth(&self) -> BridgeTicketAuth {
        BridgeTicketAuth::RivetStack {
            pairing_id: self.pairing_id.clone(),
            rivet_endpoint: self.rivet_endpoint.clone(),
            stack_project_id: self.stack_project_id.clone(),
            expires_at_unix: self.expires_at_unix,
        }
    }

    fn validate(&self) -> Result<()> {
        self.ticket_auth().validate()?;
        if self.secret.trim().is_empty() {
            bail!("missing pairing secret");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeRelayMode {
    Default,
    Disabled,
}

impl BridgeRelayMode {
    fn as_iroh(self) -> RelayMode {
        match self {
            Self::Default => RelayMode::Default,
            Self::Disabled => RelayMode::Disabled,
        }
    }
}

#[derive(Debug, Clone)]
pub struct BridgeClientOptions {
    pub ticket: BridgeTicket,
    pub relay_mode: BridgeRelayMode,
    pub pairing_secret: Option<String>,
}

pub struct BridgeClientConnection {
    /// Keep the local iroh endpoint alive for as long as the cmx stream is in use.
    pub endpoint: Endpoint,
    pub connection: iroh::endpoint::Connection,
    pub send: iroh::endpoint::SendStream,
    pub recv: iroh::endpoint::RecvStream,
}

impl BridgeClientConnection {
    pub async fn write_payload(&mut self, payload: &[u8]) -> Result<()> {
        write_cmx_payload(&mut self.send, payload).await
    }

    pub async fn read_payload(&mut self) -> Result<Option<Vec<u8>>> {
        read_cmx_payload(&mut self.recv).await
    }
}

pub async fn connect_encoded_ticket(
    encoded_ticket: &str,
    relay_mode: BridgeRelayMode,
    pairing_secret: Option<String>,
) -> Result<BridgeClientConnection> {
    connect_ticket(BridgeClientOptions {
        ticket: BridgeTicket::decode(encoded_ticket)?,
        relay_mode,
        pairing_secret,
    })
    .await
}

pub async fn connect_ticket(options: BridgeClientOptions) -> Result<BridgeClientConnection> {
    if let Some(node) = &options.ticket.node {
        node.validate()?;
    }
    options.ticket.auth.validate()?;
    if options.ticket.alpn.as_bytes() != CMUX_IROH_ALPN {
        bail!("unsupported bridge ALPN {}", options.ticket.alpn);
    }
    let pairing_secret = match &options.ticket.auth {
        BridgeTicketAuth::Direct => None,
        BridgeTicketAuth::RivetStack { .. } => Some(
            options
                .pairing_secret
                .as_deref()
                .filter(|value| !value.trim().is_empty())
                .context("missing pairing secret")?,
        ),
    };

    let endpoint = Endpoint::builder(presets::N0)
        .relay_mode(options.relay_mode.as_iroh())
        .bind()
        .await
        .context("bind iroh client endpoint")?;
    let connection = endpoint
        .connect(options.ticket.endpoint.clone(), CMUX_IROH_ALPN)
        .await
        .context("connect iroh bridge")?;
    let (mut send, mut recv) = connection.open_bi().await.context("open cmx stream")?;

    if let (BridgeTicketAuth::RivetStack { pairing_id, .. }, Some(pairing_secret)) =
        (&options.ticket.auth, pairing_secret)
    {
        complete_client_pairing_auth(&mut send, &mut recv, pairing_id, pairing_secret).await?;
    }

    Ok(BridgeClientConnection {
        endpoint,
        connection,
        send,
        recv,
    })
}

pub async fn write_cmx_payload<W>(writer: &mut W, payload: &[u8]) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let len = u32::try_from(payload.len()).context("cmx frame is too large")?;
    writer.write_all(&len.to_be_bytes()).await?;
    writer.write_all(payload).await?;
    writer.flush().await?;
    Ok(())
}

pub async fn read_cmx_payload<R>(reader: &mut R) -> Result<Option<Vec<u8>>>
where
    R: AsyncRead + Unpin,
{
    let mut len_bytes = [0u8; 4];
    if !read_exact_or_eof(reader, &mut len_bytes)
        .await
        .context("read cmx frame length")?
    {
        return Ok(None);
    }
    let len = u32::from_be_bytes(len_bytes) as usize;
    if len > MAX_CMX_FRAME_BYTES {
        bail!("cmx frame is too large");
    }

    let mut payload = vec![0u8; len];
    if let Err(error) = reader.read_exact(&mut payload).await {
        if error.kind() == ErrorKind::UnexpectedEof {
            bail!("cmx frame payload truncated");
        }
        return Err(error).context("read cmx frame payload");
    }
    Ok(Some(payload))
}

pub async fn serve(options: BridgeOptions) -> Result<()> {
    if let Some(pairing) = &options.pairing {
        pairing.validate()?;
    }
    if let Some(node) = &options.node {
        node.validate()?;
    }

    let endpoint = Endpoint::builder(presets::N0)
        .alpns(vec![CMUX_IROH_ALPN.to_vec()])
        .relay_mode(options.relay_mode.as_iroh())
        .bind()
        .await
        .context("bind iroh endpoint")?;
    let addr = publishable_endpoint_addr(&endpoint, options.relay_mode).await;
    let ticket_auth = options
        .pairing
        .as_ref()
        .map(BridgePairingOptions::ticket_auth)
        .unwrap_or(BridgeTicketAuth::Direct);
    let ticket = BridgeTicket::new_with_node(addr, ticket_auth, options.node.clone()).encode()?;
    println!("{ticket}");
    spawn_ticket_copy_shortcut(ticket);

    while let Some(incoming) = endpoint.accept().await {
        let socket_path = options.cmx_socket_path.clone();
        let pairing = options.pairing.clone();
        tokio::spawn(async move {
            if let Err(error) = proxy_incoming(incoming, socket_path, pairing).await {
                tracing::warn!(?error, "iroh cmux bridge connection failed");
            }
        });
    }

    endpoint.close().await;
    Ok(())
}

fn spawn_ticket_copy_shortcut(ticket: String) {
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        return;
    }
    let spawn_result = std::thread::Builder::new()
        .name("cmux-iroh-ticket-copy".into())
        .spawn(move || {
            if let Err(error) = ticket_copy_loop(&ticket) {
                eprintln!("cmux iroh ticket copy shortcut disabled: {error:#}");
            }
        });
    if let Err(error) = spawn_result {
        eprintln!("cmux iroh ticket copy shortcut disabled: {error}");
    }
}

fn ticket_copy_loop(ticket: &str) -> Result<()> {
    crossterm::terminal::enable_raw_mode().context("enable raw mode for ticket copy shortcut")?;
    let _raw_mode = RawModeGuard;
    eprintln!("press c to copy the iroh ticket, Ctrl-C to stop the bridge");

    loop {
        if !event::poll(Duration::from_millis(250)).context("poll terminal input")? {
            continue;
        }
        let Event::Key(key) = event::read().context("read terminal input")? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            crossterm::terminal::disable_raw_mode().ok();
            std::process::exit(130);
        }
        if matches!(key.code, KeyCode::Char('c') | KeyCode::Char('C'))
            && !key.modifiers.contains(KeyModifiers::CONTROL)
            && !key.modifiers.contains(KeyModifiers::ALT)
        {
            write_ticket_osc52(ticket).context("copy ticket with OSC 52")?;
            eprintln!("copied iroh ticket");
        }
    }
}

struct RawModeGuard;

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        crossterm::terminal::disable_raw_mode().ok();
    }
}

fn write_ticket_osc52(ticket: &str) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    write!(stdout, "{}", ticket_osc52_sequence(ticket)).context("write OSC 52 sequence")?;
    stdout.flush().context("flush OSC 52 sequence")
}

fn ticket_osc52_sequence(ticket: &str) -> String {
    format!("\x1b]52;c;{}\x07", STANDARD.encode(ticket.as_bytes()))
}

async fn read_exact_or_eof<R>(reader: &mut R, bytes: &mut [u8]) -> Result<bool>
where
    R: AsyncRead + Unpin,
{
    let mut offset = 0;
    while offset < bytes.len() {
        let read = reader.read(&mut bytes[offset..]).await?;
        if read == 0 {
            if offset == 0 {
                return Ok(false);
            }
            bail!("cmx frame length truncated");
        }
        offset += read;
    }
    Ok(true)
}

async fn proxy_incoming(
    incoming: iroh::endpoint::Incoming,
    socket_path: PathBuf,
    pairing: Option<BridgePairingOptions>,
) -> Result<()> {
    let connection = incoming
        .accept()
        .context("accept incoming iroh connection")?
        .await?;
    let (mut iroh_send, mut iroh_recv) = connection.accept_bi().await?;
    if let Some(pairing) = pairing.as_ref() {
        complete_pairing_auth(&mut iroh_send, &mut iroh_recv, pairing).await?;
    }

    let mut cmx = UnixStream::connect(&socket_path)
        .await
        .with_context(|| format!("connect cmx socket {}", socket_path.display()))?;
    let (mut cmx_recv, mut cmx_send) = cmx.split();

    let client_to_cmx = copy_then_shutdown(
        &mut iroh_recv,
        &mut cmx_send,
        "copy iroh client to cmx socket",
        "shutdown cmx socket write half",
    );
    let cmx_to_client = copy_then_shutdown(
        &mut cmx_recv,
        &mut iroh_send,
        "copy cmx socket to iroh client",
        "shutdown iroh client write half",
    );
    tokio::try_join!(client_to_cmx, cmx_to_client)?;
    Ok(())
}

async fn copy_then_shutdown<R, W>(
    reader: &mut R,
    writer: &mut W,
    copy_context: &'static str,
    shutdown_context: &'static str,
) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    if let Err(error) = io::copy(reader, writer).await
        && !is_expected_stream_close(&error)
    {
        return Err(error).context(copy_context);
    }
    if let Err(error) = writer.shutdown().await
        && !is_expected_stream_close(&error)
    {
        return Err(error).context(shutdown_context);
    }
    Ok(())
}

fn is_expected_stream_close(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::BrokenPipe
            | ErrorKind::ConnectionAborted
            | ErrorKind::ConnectionReset
            | ErrorKind::NotConnected
            | ErrorKind::UnexpectedEof
    )
}

async fn publishable_endpoint_addr(
    endpoint: &Endpoint,
    relay_mode: BridgeRelayMode,
) -> EndpointAddr {
    if relay_mode != BridgeRelayMode::Disabled
        && tokio::time::timeout(RELAY_ADDR_WAIT, endpoint.online())
            .await
            .is_err()
    {
        tracing::warn!(
            wait_ms = RELAY_ADDR_WAIT.as_millis(),
            "iroh relay did not become ready before bridge ticket was printed"
        );
    }
    endpoint.watch_addr().get()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingStart {
    #[serde(rename = "type")]
    pub kind: String,
    pub pairing_id: String,
    pub client_nonce: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingChallenge {
    #[serde(rename = "type")]
    pub kind: String,
    pub pairing_id: String,
    pub server_nonce: String,
    pub alpn: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingResponse {
    #[serde(rename = "type")]
    pub kind: String,
    pub pairing_id: String,
    pub proof: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingAccepted {
    #[serde(rename = "type")]
    pub kind: String,
}

pub fn pairing_proof(
    secret: &str,
    pairing_id: &str,
    client_nonce: &str,
    server_nonce: &str,
) -> Result<String> {
    Ok(URL_SAFE_NO_PAD.encode(pairing_proof_bytes(
        secret,
        pairing_id,
        client_nonce,
        server_nonce,
    )?))
}

fn pairing_proof_bytes(
    secret: &str,
    pairing_id: &str,
    client_nonce: &str,
    server_nonce: &str,
) -> Result<Vec<u8>> {
    let mut mac =
        HmacSha256::new_from_slice(secret.as_bytes()).map_err(|_| anyhow!("invalid HMAC key"))?;
    mac.update(CMUX_IROH_ALPN);
    mac.update(b"\n");
    mac.update(pairing_id.as_bytes());
    mac.update(b"\n");
    mac.update(client_nonce.as_bytes());
    mac.update(b"\n");
    mac.update(server_nonce.as_bytes());
    Ok(mac.finalize().into_bytes().to_vec())
}

fn verify_pairing_proof(
    secret: &str,
    pairing_id: &str,
    client_nonce: &str,
    server_nonce: &str,
    proof: &str,
) -> Result<bool> {
    let Ok(proof) = URL_SAFE_NO_PAD.decode(proof) else {
        return Ok(false);
    };
    let mut mac =
        HmacSha256::new_from_slice(secret.as_bytes()).map_err(|_| anyhow!("invalid HMAC key"))?;
    mac.update(CMUX_IROH_ALPN);
    mac.update(b"\n");
    mac.update(pairing_id.as_bytes());
    mac.update(b"\n");
    mac.update(client_nonce.as_bytes());
    mac.update(b"\n");
    mac.update(server_nonce.as_bytes());
    Ok(mac.verify_slice(&proof).is_ok())
}

async fn complete_pairing_auth<W, R>(
    writer: &mut W,
    reader: &mut R,
    pairing: &BridgePairingOptions,
) -> Result<()>
where
    W: AsyncWrite + Unpin,
    R: AsyncRead + Unpin,
{
    let start: PairingStart = read_json_line(reader).await?;
    if start.kind != "pairing_start" {
        bail!("unexpected pairing auth frame {}", start.kind);
    }
    if start.pairing_id != pairing.pairing_id {
        bail!("pairing id mismatch");
    }
    if start.client_nonce.trim().is_empty() {
        bail!("missing client nonce");
    }

    let server_nonce = generate_nonce()?;
    let challenge = PairingChallenge {
        kind: "pairing_challenge".into(),
        pairing_id: pairing.pairing_id.clone(),
        server_nonce: server_nonce.clone(),
        alpn: String::from_utf8_lossy(CMUX_IROH_ALPN).into_owned(),
    };
    write_json_line(writer, &challenge).await?;

    let response: PairingResponse = read_json_line(reader).await?;
    if response.kind != "pairing_response" {
        bail!("unexpected pairing auth frame {}", response.kind);
    }
    if response.pairing_id != pairing.pairing_id {
        bail!("pairing id mismatch");
    }
    if !verify_pairing_proof(
        &pairing.secret,
        &pairing.pairing_id,
        &start.client_nonce,
        &server_nonce,
        &response.proof,
    )? {
        bail!("pairing proof rejected");
    }

    write_json_line(
        writer,
        &PairingAccepted {
            kind: "pairing_accepted".into(),
        },
    )
    .await
}

async fn complete_client_pairing_auth<W, R>(
    writer: &mut W,
    reader: &mut R,
    pairing_id: &str,
    pairing_secret: &str,
) -> Result<()>
where
    W: AsyncWrite + Unpin,
    R: AsyncRead + Unpin,
{
    let client_nonce = generate_nonce()?;
    write_json_line(
        writer,
        &PairingStart {
            kind: "pairing_start".into(),
            pairing_id: pairing_id.into(),
            client_nonce: client_nonce.clone(),
        },
    )
    .await?;

    let challenge: PairingChallenge = read_json_line(reader).await?;
    if challenge.kind != "pairing_challenge" {
        bail!("unexpected pairing auth frame {}", challenge.kind);
    }
    if challenge.pairing_id != pairing_id {
        bail!("pairing id mismatch");
    }
    if challenge.alpn.as_bytes() != CMUX_IROH_ALPN {
        bail!("unsupported pairing ALPN {}", challenge.alpn);
    }
    if challenge.server_nonce.trim().is_empty() {
        bail!("missing server nonce");
    }

    write_json_line(
        writer,
        &PairingResponse {
            kind: "pairing_response".into(),
            pairing_id: pairing_id.into(),
            proof: pairing_proof(
                pairing_secret,
                pairing_id,
                &client_nonce,
                &challenge.server_nonce,
            )?,
        },
    )
    .await?;

    let accepted: PairingAccepted = read_json_line(reader).await?;
    if accepted.kind != "pairing_accepted" {
        bail!("unexpected pairing auth frame {}", accepted.kind);
    }
    Ok(())
}

fn generate_nonce() -> Result<String> {
    let mut nonce = [0u8; 32];
    getrandom::fill(&mut nonce).map_err(|error| anyhow!("generate pairing nonce: {error}"))?;
    Ok(URL_SAFE_NO_PAD.encode(nonce))
}

async fn write_json_line<W, T>(writer: &mut W, value: &T) -> Result<()>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let mut bytes = serde_json::to_vec(value).context("encode auth frame")?;
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}

async fn read_json_line<R, T>(reader: &mut R) -> Result<T>
where
    R: AsyncRead + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let mut bytes = Vec::new();
    loop {
        let byte = reader.read_u8().await.context("read auth frame")?;
        if byte == b'\n' {
            break;
        }
        bytes.push(byte);
        if bytes.len() > MAX_AUTH_FRAME_BYTES {
            bail!("auth frame too large");
        }
    }
    serde_json::from_slice(&bytes).context("decode auth frame")
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_cli_protocol::{
        ClientMsg, PROTOCOL_VERSION, ServerMsg, Viewport, read_msg, write_msg,
    };
    use cmux_cli_server::{ServerOptions, run};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;
    use tokio::time::{Duration, Instant, sleep, timeout};

    #[test]
    fn ticket_roundtrips_json() {
        let endpoint = EndpointAddr::new(iroh::SecretKey::generate().public());
        let ticket = BridgeTicket::new(
            endpoint,
            BridgeTicketAuth::RivetStack {
                pairing_id: "pairing-1".into(),
                rivet_endpoint: "https://rivet.example.test".into(),
                stack_project_id: "stack-project".into(),
                expires_at_unix: 1_800_000_000,
            },
        );
        let encoded = ticket.encode().expect("encode");
        let decoded = BridgeTicket::decode(&encoded).expect("decode");
        assert_eq!(decoded, ticket);
    }

    #[test]
    fn ticket_roundtrips_node_metadata_without_secret_material() {
        let endpoint = EndpointAddr::new(iroh::SecretKey::generate().public());
        let ticket = BridgeTicket::new_with_node(
            endpoint,
            BridgeTicketAuth::RivetStack {
                pairing_id: "pairing-1".into(),
                rivet_endpoint: "https://rivet.example.test".into(),
                stack_project_id: "stack-project".into(),
                expires_at_unix: 1_800_000_000,
            },
            Some(BridgeNodeInfo {
                id: Some("node-mbp".into()),
                name: "MacBook Pro".into(),
                subtitle: Some("local dev node".into()),
                kind: Some("macbook".into()),
            }),
        );

        let encoded = ticket.encode().expect("encode");
        assert!(encoded.contains("\"node\""));
        assert!(encoded.contains("\"node-mbp\""));
        assert!(!encoded.contains("secret"));
        assert_eq!(BridgeTicket::decode(&encoded).expect("decode"), ticket);
    }

    #[test]
    fn ticket_copy_shortcut_emits_osc52_payload() {
        assert_eq!(ticket_osc52_sequence("ticket"), "\x1b]52;c;dGlja2V0\x07");
    }

    #[test]
    fn ticket_rejects_empty_node_metadata() {
        let endpoint = EndpointAddr::new(iroh::SecretKey::generate().public());
        let ticket = BridgeTicket::new_with_node(
            endpoint,
            BridgeTicketAuth::Direct,
            Some(BridgeNodeInfo {
                id: Some(String::new()),
                name: "MacBook Pro".into(),
                subtitle: None,
                kind: None,
            }),
        );
        let encoded = ticket.encode().expect("encode");
        let error = BridgeTicket::decode(&encoded).expect_err("empty node id should fail");
        assert!(error.to_string().contains("empty node id"));
    }

    #[test]
    fn ticket_rejects_wrong_alpn() {
        let endpoint = EndpointAddr::new(iroh::SecretKey::generate().public());
        let mut ticket = BridgeTicket::new(endpoint, BridgeTicketAuth::Direct);
        ticket.alpn = "wrong".into();
        let encoded = ticket.encode().expect("encode");
        let error = BridgeTicket::decode(&encoded).expect_err("wrong alpn should fail");
        assert!(error.to_string().contains("unsupported bridge ALPN"));
    }

    #[test]
    fn ticket_rejects_incomplete_rivet_auth() {
        let endpoint = EndpointAddr::new(iroh::SecretKey::generate().public());
        let ticket = BridgeTicket::new(
            endpoint,
            BridgeTicketAuth::RivetStack {
                pairing_id: String::new(),
                rivet_endpoint: "https://rivet.example.test".into(),
                stack_project_id: "stack-project".into(),
                expires_at_unix: 1_800_000_000,
            },
        );
        let encoded = ticket.encode().expect("encode");
        let error = BridgeTicket::decode(&encoded).expect_err("missing pairing id should fail");
        assert!(error.to_string().contains("missing Rivet pairing id"));
    }

    #[tokio::test]
    async fn publishable_addr_does_not_wait_for_relay_when_disabled() -> Result<()> {
        let endpoint = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;

        let addr = timeout(
            Duration::from_secs(1),
            publishable_endpoint_addr(&endpoint, BridgeRelayMode::Disabled),
        )
        .await
        .context("relay-disabled address should be available immediately")?;

        assert_eq!(addr.id, endpoint.id());
        endpoint.close().await;
        Ok(())
    }

    #[test]
    fn pairing_proof_depends_on_secret_and_nonce() {
        let proof = pairing_proof("secret-a", "pairing-1", "client-a", "server-a").expect("proof");
        assert_eq!(proof, "w62sYb9esNfmw-GwP36Z2ooce7olwxryi3xdRWVRpHs");
        assert_ne!(
            proof,
            pairing_proof("secret-b", "pairing-1", "client-a", "server-a").expect("proof")
        );
        assert_ne!(
            proof,
            pairing_proof("secret-a", "pairing-1", "client-b", "server-a").expect("proof")
        );
        assert_ne!(
            proof,
            pairing_proof("secret-a", "pairing-1", "client-a", "server-b").expect("proof")
        );
    }

    #[test]
    fn pairing_proof_verification_rejects_tampered_or_malformed_proofs() -> Result<()> {
        let proof = pairing_proof("secret-a", "pairing-1", "client-a", "server-a")?;

        assert!(verify_pairing_proof(
            "secret-a",
            "pairing-1",
            "client-a",
            "server-a",
            &proof,
        )?);
        assert!(!verify_pairing_proof(
            "secret-a",
            "pairing-1",
            "client-a",
            "server-b",
            &proof,
        )?);
        assert!(!verify_pairing_proof(
            "secret-a",
            "pairing-1",
            "client-a",
            "server-a",
            "not base64",
        )?);
        Ok(())
    }

    #[tokio::test]
    async fn connect_ticket_opens_authenticated_stream() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let socket_path = dir.path().join("cmx.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let unix_server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            let mut input = [0u8; 4];
            socket.read_exact(&mut input).await?;
            assert_eq!(&input, b"ping");
            socket.write_all(b"pong").await?;
            Result::<()>::Ok(())
        });

        let pairing = BridgePairingOptions {
            pairing_id: "pairing-1".into(),
            secret: "shared-secret-from-rivet".into(),
            rivet_endpoint: "https://rivet.example.test".into(),
            stack_project_id: "stack-project".into(),
            expires_at_unix: 1_800_000_000,
        };
        let server = Endpoint::builder(presets::Minimal)
            .alpns(vec![CMUX_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let encoded_ticket = BridgeTicket::new(server.watch_addr().get(), pairing.ticket_auth())
            .encode()
            .expect("encode ticket");
        let server_task = tokio::spawn({
            let socket_path = socket_path.clone();
            let server = server.clone();
            let pairing = pairing.clone();
            async move {
                let incoming = server.accept().await.context("accept iroh")?;
                proxy_incoming(incoming, socket_path, Some(pairing)).await
            }
        });

        let mut client = connect_encoded_ticket(
            &encoded_ticket,
            BridgeRelayMode::Disabled,
            Some(pairing.secret.clone()),
        )
        .await?;
        client.send.write_all(b"ping").await?;
        let mut output = [0u8; 4];
        client.recv.read_exact(&mut output).await?;
        assert_eq!(&output, b"pong");

        client.send.shutdown().await?;
        client.endpoint.close().await;
        server.close().await;
        unix_server.await??;
        timeout(Duration::from_secs(2), server_task)
            .await
            .context("proxy should finish after both streams close")???;
        Ok(())
    }

    #[tokio::test]
    async fn framed_client_roundtrips_payload_over_authenticated_stream() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let socket_path = dir.path().join("cmx.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let unix_server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            let input = read_cmx_payload(&mut socket)
                .await?
                .context("expected framed payload")?;
            assert_eq!(input, b"hello from ios");
            write_cmx_payload(&mut socket, b"hello from cmx").await?;
            Result::<()>::Ok(())
        });

        let pairing = BridgePairingOptions {
            pairing_id: "pairing-1".into(),
            secret: "shared-secret-from-rivet".into(),
            rivet_endpoint: "https://rivet.example.test".into(),
            stack_project_id: "stack-project".into(),
            expires_at_unix: 1_800_000_000,
        };
        let server = Endpoint::builder(presets::Minimal)
            .alpns(vec![CMUX_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let encoded_ticket = BridgeTicket::new(server.watch_addr().get(), pairing.ticket_auth())
            .encode()
            .expect("encode ticket");
        let server_task = tokio::spawn({
            let socket_path = socket_path.clone();
            let server = server.clone();
            let pairing = pairing.clone();
            async move {
                let incoming = server.accept().await.context("accept iroh")?;
                proxy_incoming(incoming, socket_path, Some(pairing)).await
            }
        });

        let mut client = connect_encoded_ticket(
            &encoded_ticket,
            BridgeRelayMode::Disabled,
            Some(pairing.secret.clone()),
        )
        .await?;
        client.write_payload(b"hello from ios").await?;
        let output = client
            .read_payload()
            .await?
            .context("expected reply payload")?;
        assert_eq!(output, b"hello from cmx");

        client.send.shutdown().await?;
        client.endpoint.close().await;
        server.close().await;
        unix_server.await??;
        timeout(Duration::from_secs(2), server_task)
            .await
            .context("framed proxy should finish after both streams close")???;
        Ok(())
    }

    #[tokio::test]
    async fn connect_ticket_rejects_missing_pairing_secret_before_network_connect() -> Result<()> {
        let endpoint = EndpointAddr::new(iroh::SecretKey::generate().public());
        let ticket = BridgeTicket::new(
            endpoint,
            BridgeTicketAuth::RivetStack {
                pairing_id: "pairing-1".into(),
                rivet_endpoint: "https://rivet.example.test".into(),
                stack_project_id: "stack-project".into(),
                expires_at_unix: 1_800_000_000,
            },
        );

        let error = match connect_ticket(BridgeClientOptions {
            ticket,
            relay_mode: BridgeRelayMode::Disabled,
            pairing_secret: None,
        })
        .await
        {
            Ok(_) => bail!("missing pairing secret should fail before dialing"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("missing pairing secret"));
        Ok(())
    }

    #[tokio::test]
    async fn iroh_stream_is_proxied_to_unix_socket() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let socket_path = dir.path().join("cmx.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let unix_server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            let mut input = [0u8; 4];
            socket.read_exact(&mut input).await?;
            assert_eq!(&input, b"ping");
            socket.write_all(b"pong").await?;
            Result::<()>::Ok(())
        });

        let server = Endpoint::builder(presets::Minimal)
            .alpns(vec![CMUX_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let server_addr = server.watch_addr().get();
        let server_task = tokio::spawn({
            let socket_path = socket_path.clone();
            let server = server.clone();
            async move {
                let incoming = server.accept().await.context("accept iroh")?;
                proxy_incoming(incoming, socket_path, None).await
            }
        });

        let client = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let connection = client.connect(server_addr, CMUX_IROH_ALPN).await?;
        let (mut send, mut recv) = connection.open_bi().await?;
        send.write_all(b"ping").await?;
        let mut output = [0u8; 4];
        recv.read_exact(&mut output).await?;
        assert_eq!(&output, b"pong");

        client.close().await;
        server.close().await;
        unix_server.await??;
        server_task.abort();
        Ok(())
    }

    #[tokio::test]
    async fn iroh_stream_requires_pairing_proof_before_proxying() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let socket_path = dir.path().join("cmx.sock");
        let listener = UnixListener::bind(&socket_path)?;
        let unix_server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            let mut input = [0u8; 4];
            socket.read_exact(&mut input).await?;
            assert_eq!(&input, b"ping");
            socket.write_all(b"pong").await?;
            Result::<()>::Ok(())
        });

        let pairing = BridgePairingOptions {
            pairing_id: "pairing-1".into(),
            secret: "shared-secret-from-rivet".into(),
            rivet_endpoint: "https://rivet.example.test".into(),
            stack_project_id: "stack-project".into(),
            expires_at_unix: 1_800_000_000,
        };
        let server = Endpoint::builder(presets::Minimal)
            .alpns(vec![CMUX_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let server_addr = server.watch_addr().get();
        let server_task = tokio::spawn({
            let socket_path = socket_path.clone();
            let server = server.clone();
            let pairing = pairing.clone();
            async move {
                let incoming = server.accept().await.context("accept iroh")?;
                proxy_incoming(incoming, socket_path, Some(pairing)).await
            }
        });

        let client = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let connection = client.connect(server_addr, CMUX_IROH_ALPN).await?;
        let (mut send, mut recv) = connection.open_bi().await?;
        let client_nonce = "client-nonce-a";
        write_json_line(
            &mut send,
            &PairingStart {
                kind: "pairing_start".into(),
                pairing_id: pairing.pairing_id.clone(),
                client_nonce: client_nonce.into(),
            },
        )
        .await?;
        let challenge: PairingChallenge =
            tokio::time::timeout(Duration::from_secs(5), read_json_line(&mut recv))
                .await
                .context("pairing challenge timed out")??;
        assert_eq!(challenge.kind, "pairing_challenge");
        assert_eq!(challenge.pairing_id, pairing.pairing_id);
        write_json_line(
            &mut send,
            &PairingResponse {
                kind: "pairing_response".into(),
                pairing_id: pairing.pairing_id.clone(),
                proof: pairing_proof(
                    &pairing.secret,
                    &pairing.pairing_id,
                    client_nonce,
                    &challenge.server_nonce,
                )?,
            },
        )
        .await?;
        let accepted: PairingAccepted =
            tokio::time::timeout(Duration::from_secs(5), read_json_line(&mut recv))
                .await
                .context("pairing accepted timed out")??;
        assert_eq!(accepted.kind, "pairing_accepted");

        send.write_all(b"ping").await?;
        let mut output = [0u8; 4];
        tokio::time::timeout(Duration::from_secs(5), recv.read_exact(&mut output))
            .await
            .context("pong timed out")??;
        assert_eq!(&output, b"pong");

        client.close().await;
        server.close().await;
        tokio::time::timeout(Duration::from_secs(5), unix_server)
            .await
            .context("unix echo server timed out")???;
        server_task.abort();
        Ok(())
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cmx_tui_frames_sync_over_authenticated_iroh() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let socket_path = dir.path().join("cmx.sock");
        let cmx_server = tokio::spawn({
            let socket_path = socket_path.clone();
            let cwd = dir.path().to_path_buf();
            async move {
                let _ = run(ServerOptions {
                    socket_path,
                    shell: "/bin/sh".into(),
                    cwd: Some(cwd),
                    initial_viewport: (80, 24),
                    snapshot_path: None,
                    settings_path: None,
                    ws_bind: None,
                    auth_token: None,
                })
                .await;
            }
        });
        wait_for_socket(&socket_path).await?;

        let pairing = BridgePairingOptions {
            pairing_id: "pairing-1".into(),
            secret: "shared-secret-from-rivet".into(),
            rivet_endpoint: "https://rivet.example.test".into(),
            stack_project_id: "stack-project".into(),
            expires_at_unix: 1_800_000_000,
        };
        let iroh_server = Endpoint::builder(presets::Minimal)
            .alpns(vec![CMUX_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let iroh_addr = iroh_server.watch_addr().get();
        let bridge_task =
            spawn_one_bridge_accept(iroh_server.clone(), socket_path.clone(), pairing.clone());

        let client = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let connection = client.connect(iroh_addr.clone(), CMUX_IROH_ALPN).await?;
        let (mut send, mut recv) = connection.open_bi().await?;
        let client_nonce = "client-nonce-a";
        write_json_line(
            &mut send,
            &PairingStart {
                kind: "pairing_start".into(),
                pairing_id: pairing.pairing_id.clone(),
                client_nonce: client_nonce.into(),
            },
        )
        .await?;
        let challenge: PairingChallenge = read_json_line(&mut recv).await?;
        write_json_line(
            &mut send,
            &PairingResponse {
                kind: "pairing_response".into(),
                pairing_id: pairing.pairing_id.clone(),
                proof: pairing_proof(
                    &pairing.secret,
                    &pairing.pairing_id,
                    client_nonce,
                    &challenge.server_nonce,
                )?,
            },
        )
        .await?;
        let accepted: PairingAccepted = read_json_line(&mut recv).await?;
        assert_eq!(accepted.kind, "pairing_accepted");

        write_msg(
            &mut send,
            &ClientMsg::Hello {
                version: PROTOCOL_VERSION,
                viewport: Viewport { cols: 80, rows: 24 },
                token: None,
            },
        )
        .await?;
        match read_msg::<_, ServerMsg>(&mut recv).await? {
            Some(ServerMsg::Welcome { .. }) => {}
            other => bail!("expected Welcome, got {other:?}"),
        }
        wait_for_tui_frame(&mut recv, |_| true).await?;

        write_msg(
            &mut send,
            &ClientMsg::Input {
                data: b"printf ios-sync-ok\\n\n".to_vec(),
            },
        )
        .await?;
        wait_for_tui_frame(&mut recv, |frame| frame.contains("ios-sync-ok")).await?;

        client.close().await;
        bridge_task.abort();

        let bridge_task =
            spawn_one_bridge_accept(iroh_server.clone(), socket_path.clone(), pairing.clone());
        let reconnecting_client = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await?;
        let connection = reconnecting_client
            .connect(iroh_addr, CMUX_IROH_ALPN)
            .await?;
        let (mut send, mut recv) = connection.open_bi().await?;
        let client_nonce = "client-nonce-b";
        write_json_line(
            &mut send,
            &PairingStart {
                kind: "pairing_start".into(),
                pairing_id: pairing.pairing_id.clone(),
                client_nonce: client_nonce.into(),
            },
        )
        .await?;
        let challenge: PairingChallenge = read_json_line(&mut recv).await?;
        write_json_line(
            &mut send,
            &PairingResponse {
                kind: "pairing_response".into(),
                pairing_id: pairing.pairing_id.clone(),
                proof: pairing_proof(
                    &pairing.secret,
                    &pairing.pairing_id,
                    client_nonce,
                    &challenge.server_nonce,
                )?,
            },
        )
        .await?;
        let accepted: PairingAccepted = read_json_line(&mut recv).await?;
        assert_eq!(accepted.kind, "pairing_accepted");
        write_msg(
            &mut send,
            &ClientMsg::Hello {
                version: PROTOCOL_VERSION,
                viewport: Viewport { cols: 80, rows: 24 },
                token: None,
            },
        )
        .await?;
        match read_msg::<_, ServerMsg>(&mut recv).await? {
            Some(ServerMsg::Welcome { .. }) => {}
            other => bail!("expected reconnect Welcome, got {other:?}"),
        }
        wait_for_tui_frame(&mut recv, |frame| frame.contains("ios-sync-ok")).await?;

        reconnecting_client.close().await;
        iroh_server.close().await;
        bridge_task.abort();
        cmx_server.abort();
        Ok(())
    }

    fn spawn_one_bridge_accept(
        iroh_server: Endpoint,
        socket_path: std::path::PathBuf,
        pairing: BridgePairingOptions,
    ) -> tokio::task::JoinHandle<Result<()>> {
        tokio::spawn(async move {
            let incoming = iroh_server.accept().await.context("accept iroh")?;
            proxy_incoming(incoming, socket_path, Some(pairing)).await
        })
    }

    async fn wait_for_socket(socket_path: &std::path::Path) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if socket_path.exists() {
                return Ok(());
            }
            sleep(Duration::from_millis(20)).await;
        }
        bail!("timed out waiting for cmx socket {}", socket_path.display())
    }

    async fn wait_for_tui_frame<R>(recv: &mut R, predicate: impl Fn(&str) -> bool) -> Result<String>
    where
        R: tokio::io::AsyncRead + Unpin,
    {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut last_frame = String::new();
        while Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let message = tokio::time::timeout(remaining, read_msg::<_, ServerMsg>(recv)).await??;
            match message {
                Some(ServerMsg::PtyBytes { data, .. }) => {
                    let frame = String::from_utf8_lossy(&data).into_owned();
                    if predicate(&frame) {
                        return Ok(frame);
                    }
                    last_frame = frame;
                }
                Some(_) => {}
                None => break,
            }
        }
        bail!("timed out waiting for matching TUI frame; last frame: {last_frame:?}")
    }
}
