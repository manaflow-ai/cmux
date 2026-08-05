use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_tui_machine_protocol::{
    BearerToken, ClientDescriptor, CloseMachineParams, CloseMachineResult, HelloParams,
    HelloResult, OpaqueId, OpenMachineParams, OpenMachineResult, Protocol, ProviderRequest,
    ProviderResponse, RequestEnvelope, ResponseEnvelope, SnapshotParams, SnapshotResult,
    TransportDescriptor, TransportHandshake, TransportHandshakeResult, TransportRole, Version,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

use crate::transport::{read_json_line, write_bounded_json_line};

const CONTROL_FRAME_BYTES: usize = 1024 * 1024;
const TRANSPORT_FRAME_BYTES: usize = 64 * 1024;
/// Deadline for every probe read so a silent peer fails the acceptance run
/// with a clear message instead of hanging until the outer job timeout.
const PROBE_READ_TIMEOUT: Duration = Duration::from_secs(30);
/// The v10 protocol multiplexes events with responses on one stream; bound
/// how many unsolicited lines a single request will skip.
const MAX_SKIPPED_LINES: usize = 256;

/// One probe connection: a persistent buffered reader (bytes after each
/// newline stay available) plus the write half.
struct Wire {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
}

impl Wire {
    async fn connect(socket: &Path, purpose: &str) -> Result<Self> {
        let stream = UnixStream::connect(socket)
            .await
            .with_context(|| format!("cannot connect {purpose} to {}", socket.display()))?;
        let (read_half, writer) = stream.into_split();
        Ok(Self { reader: BufReader::new(read_half), writer })
    }

    async fn write<T: Serialize>(&mut self, value: &T, maximum_bytes: usize) -> Result<()> {
        write_bounded_json_line(&mut self.writer, value, maximum_bytes).await
    }

    async fn read<T: DeserializeOwned>(&mut self, maximum_bytes: usize) -> Result<T> {
        tokio::time::timeout(PROBE_READ_TIMEOUT, read_json_line(&mut self.reader, maximum_bytes))
            .await
            .context("probe read timed out")?
    }
}

pub async fn run(socket: &Path, machine_id: Option<&str>, marker_key: &str) -> Result<()> {
    let mut control = Wire::connect(socket, "provider probe").await?;
    let token = BearerToken::new(random_bearer(32)?)
        .map_err(|_| anyhow::anyhow!("generated provider bearer is invalid"))?;
    let hello: HelloResult = request(
        &mut control,
        1,
        ProviderRequest::Hello(HelloParams {
            token: token.clone(),
            client: ClientDescriptor {
                name: "cmux-tui-iroh-probe".into(),
                version: env!("CARGO_PKG_VERSION").into(),
                supported_versions: vec![1],
            },
        }),
    )
    .await?;
    ensure!(hello.negotiated_version == Version, "provider did not negotiate v1");
    let snapshot: SnapshotResult =
        request(&mut control, 2, ProviderRequest::Snapshot(SnapshotParams::default())).await?;
    let machine = match machine_id {
        Some(machine_id) => snapshot
            .machines
            .iter()
            .find(|machine| machine.id.as_str() == machine_id)
            .context("requested machine is absent from provider snapshot")?,
        None => snapshot
            .machines
            .iter()
            .find(|machine| machine.connectable)
            .context("provider snapshot has no connectable Linux machine")?,
    };
    let selected_machine = machine.id.clone();

    let mut first = open(&mut control, &token, socket, 3, selected_machine.clone()).await?;
    let identify =
        raw_request(&mut first.stream, json!({"id":"identify-1","cmd":"identify"})).await?;
    ensure!(identify["ok"] == true, "protocol identify failed");
    ensure!(identify["data"]["protocol"] == 10, "remote protocol is not v10");
    let mut workspaces =
        raw_request(&mut first.stream, json!({"id":"list-1","cmd":"list-workspaces"})).await?;
    ensure!(workspaces["ok"] == true, "initial workspace listing failed");
    if !workspace_present(&workspaces, marker_key) {
        let revision = workspaces["data"]["workspace_revision"]
            .as_u64()
            .context("workspace revision is missing")?;
        let created = raw_request(
            &mut first.stream,
            json!({
                "id":"create-marker",
                "cmd":"create-workspace",
                "name":"iroh-stage1-marker",
                "key":marker_key,
                "expected_revision":revision
            }),
        )
        .await?;
        ensure!(created["ok"] == true, "marker workspace creation failed");
        workspaces = raw_request(
            &mut first.stream,
            json!({"id":"list-after-create","cmd":"list-workspaces"}),
        )
        .await?;
        ensure!(workspace_present(&workspaces, marker_key), "marker workspace was not persisted");
    }
    drop(first.stream);
    close(&mut control, 4, first.connection_id).await?;

    let mut second = open(&mut control, &token, socket, 5, selected_machine.clone()).await?;
    let identify =
        raw_request(&mut second.stream, json!({"id":"identify-2","cmd":"identify"})).await?;
    ensure!(identify["ok"] == true, "reattached protocol identify failed");
    ensure!(identify["data"]["protocol"] == 10, "reattached protocol is not v10");
    let workspaces =
        raw_request(&mut second.stream, json!({"id":"list-2","cmd":"list-workspaces"})).await?;
    ensure!(workspaces["ok"] == true, "reattached workspace listing failed");
    ensure!(workspace_present(&workspaces, marker_key), "marker workspace did not survive detach");
    drop(second.stream);
    close(&mut control, 6, second.connection_id).await?;
    println!(
        "probe protocol=10 machine={} resolution=broker detach_reattach=ok marker={} provider={}",
        selected_machine, marker_key, hello.provider_id,
    );
    Ok(())
}

struct Opened {
    connection_id: OpaqueId,
    stream: Wire,
}

async fn open(
    control: &mut Wire,
    token: &BearerToken,
    socket: &Path,
    request_id: u64,
    machine_id: OpaqueId,
) -> Result<Opened> {
    let opened: OpenMachineResult = request(
        control,
        request_id,
        ProviderRequest::OpenMachine(OpenMachineParams {
            machine_id,
            workspace_mirror_authority: false,
        }),
    )
    .await?;
    let TransportDescriptor::ProviderStream { ticket, expires_at: _ } = opened.transport;
    let mut stream = Wire::connect(socket, "provider transport").await?;
    stream
        .write(
            &TransportHandshake {
                protocol: Protocol,
                version: Version,
                role: TransportRole::Transport,
                token: token.clone(),
                ticket,
            },
            TRANSPORT_FRAME_BYTES,
        )
        .await?;
    let result: TransportHandshakeResult = stream.read(TRANSPORT_FRAME_BYTES).await?;
    ensure!(result.accepted, "provider transport was rejected");
    Ok(Opened { connection_id: opened.connection_id, stream })
}

async fn close(control: &mut Wire, request_id: u64, connection_id: OpaqueId) -> Result<()> {
    let _: CloseMachineResult = request(
        control,
        request_id,
        ProviderRequest::CloseMachine(CloseMachineParams { connection_id }),
    )
    .await?;
    Ok(())
}

async fn request<T: DeserializeOwned>(
    wire: &mut Wire,
    id: u64,
    request: ProviderRequest,
) -> Result<T> {
    let id = OpaqueId::new(format!("probe-{id}"))
        .map_err(|_| anyhow::anyhow!("probe request ID is invalid"))?;
    wire.write(&RequestEnvelope::new(id.clone(), request), CONTROL_FRAME_BYTES).await?;
    let response: ResponseEnvelope<T> = wire.read(CONTROL_FRAME_BYTES).await?;
    ensure!(response.id == id, "provider response ID changed");
    match response.response {
        ProviderResponse::Success(value) => Ok(value),
        ProviderResponse::Failure(error) => {
            bail!("provider request failed: {}", error.code.as_str())
        }
    }
}

/// Sends one raw v10 request and returns the response correlated by `id`,
/// skipping interleaved event lines and stale responses to earlier requests.
async fn raw_request(wire: &mut Wire, request: Value) -> Result<Value> {
    let id = request["id"].as_str().context("raw protocol request needs an id")?.to_string();
    wire.write(&request, CONTROL_FRAME_BYTES).await?;
    for _ in 0..MAX_SKIPPED_LINES {
        let response: Value = wire.read(CONTROL_FRAME_BYTES).await?;
        if response.get("event").is_some() {
            continue;
        }
        if response["id"].as_str() == Some(id.as_str()) {
            return Ok(response);
        }
    }
    bail!("no protocol response matched request id {id:?}")
}

fn workspace_present(response: &Value, marker_key: &str) -> bool {
    response["data"]["workspaces"]
        .as_array()
        .is_some_and(|workspaces| workspaces.iter().any(|workspace| workspace["key"] == marker_key))
}

fn random_bearer(bytes: usize) -> Result<String> {
    let mut value = vec![0_u8; bytes];
    getrandom::fill(&mut value).context("cannot generate probe bearer")?;
    Ok(URL_SAFE_NO_PAD.encode(value))
}
