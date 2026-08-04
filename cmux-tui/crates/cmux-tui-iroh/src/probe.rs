use std::path::Path;

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
use tokio::net::UnixStream;

use crate::transport::{read_json_line, write_bounded_json_line};

const CONTROL_FRAME_BYTES: usize = 1024 * 1024;
const TRANSPORT_FRAME_BYTES: usize = 64 * 1024;

pub async fn run(socket: &Path, machine_id: Option<&str>, marker_key: &str) -> Result<()> {
    let mut control = UnixStream::connect(socket)
        .await
        .with_context(|| format!("cannot connect provider probe to {}", socket.display()))?;
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
    ensure!(identify["data"]["protocol"] == 10, "reattached protocol is not v10");
    let workspaces =
        raw_request(&mut second.stream, json!({"id":"list-2","cmd":"list-workspaces"})).await?;
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
    stream: UnixStream,
}

async fn open(
    control: &mut UnixStream,
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
    let mut stream = UnixStream::connect(socket).await.context("cannot open provider transport")?;
    write_bounded_json_line(
        &mut stream,
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
    let result: TransportHandshakeResult =
        read_json_line(&mut stream, TRANSPORT_FRAME_BYTES).await?;
    ensure!(result.accepted, "provider transport was rejected");
    Ok(Opened { connection_id: opened.connection_id, stream })
}

async fn close(control: &mut UnixStream, request_id: u64, connection_id: OpaqueId) -> Result<()> {
    let _: CloseMachineResult = request(
        control,
        request_id,
        ProviderRequest::CloseMachine(CloseMachineParams { connection_id }),
    )
    .await?;
    Ok(())
}

async fn request<T: DeserializeOwned>(
    stream: &mut UnixStream,
    id: u64,
    request: ProviderRequest,
) -> Result<T> {
    let id = OpaqueId::new(format!("probe-{id}"))
        .map_err(|_| anyhow::anyhow!("probe request ID is invalid"))?;
    write_bounded_json_line(
        stream,
        &RequestEnvelope::new(id.clone(), request),
        CONTROL_FRAME_BYTES,
    )
    .await?;
    let response: ResponseEnvelope<T> = read_json_line(stream, CONTROL_FRAME_BYTES).await?;
    ensure!(response.id == id, "provider response ID changed");
    match response.response {
        ProviderResponse::Success(value) => Ok(value),
        ProviderResponse::Failure(error) => {
            bail!("provider request failed: {}", error.code.as_str())
        }
    }
}

async fn raw_request(stream: &mut UnixStream, request: Value) -> Result<Value> {
    write_raw_json_line(stream, &request).await?;
    let response: Value = read_json_line(stream, CONTROL_FRAME_BYTES).await?;
    ensure!(response.get("event").is_none(), "unexpected event before protocol response");
    Ok(response)
}

async fn write_raw_json_line<T: Serialize>(stream: &mut UnixStream, value: &T) -> Result<()> {
    write_bounded_json_line(stream, value, CONTROL_FRAME_BYTES).await
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
