//! The `cmux-vm` command-line client for the cmux VM API.
//!
//! Every verb calls one operation of the generated client. The CLI uses its
//! raw variant ([`cmux_vm_client::raw::Client`]) so `--json` prints the server's
//! response body unchanged, fields newer than this CLI included; human output
//! decodes the same bytes into the typed [`cmux_vm_client::types`].
//! [`run`] takes its environment and its confirmation prompt as parameters so
//! tests can drive it without touching the process environment or a terminal.

pub mod exit;

mod config;
mod creation_history;
mod error;
mod output;
mod prompt;

pub use prompt::{NoPrompt, Prompt, StdinPrompt};

use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use clap::{Args, Parser, Subcommand};
use cmux_vm_client::raw::{ByteStream, Client, types};
use futures::StreamExt;
use serde_json::{Value, json};

use crate::config::Settings;
use crate::error::CliError;

const EXIT_CODES_HELP: &str = "\
Configuration:
  CMUX_VM_API_KEY    API key (or \"apiKey\" in the config file)
  CMUX_VM_BASE_URL   API base URL (or --base-url, or \"baseUrl\"); default https://vm.cmux.dev
  CMUX_VM_TEAM_ID    team for session tokens (or --team, or \"teamId\")
  CMUX_VM_CONFIG     config file; default $XDG_CONFIG_HOME/cmux/vm.json or ~/.config/cmux/vm.json

Exit codes:
  0  success
  1  unexpected error (undocumented HTTP status or unreadable response)
  2  usage error
  3  network error (the API could not be reached)
  4  cancelled (delete or revoke was not confirmed)
  10 bad request (400)          11 not authenticated (401, or no API key)
  12 payment required (402)     13 forbidden, missing scope (403)
  14 not found (404)            15 conflict (409)
  16 quota or rate limit (429; --json names the budget)
  17 not available yet (501)    18 service unavailable (503)
  19 payload too large (413)    20 WebSocket upgrade required (426)";

#[derive(Parser, Debug)]
#[command(
    name = "cmux-vm",
    version,
    about = "Manage cmux VMs",
    after_help = EXIT_CODES_HELP
)]
struct Cli {
    /// Print the API response as JSON; errors go to stderr as JSON.
    #[arg(long, global = true)]
    json: bool,

    /// API base URL [env: CMUX_VM_BASE_URL]
    #[arg(long, global = true, value_name = "URL")]
    base_url: Option<String>,

    /// Team id sent as x-cmux-team-id [env: CMUX_VM_TEAM_ID]
    #[arg(long, global = true, value_name = "TEAM_ID")]
    team: Option<String>,

    /// Config file [env: CMUX_VM_CONFIG]
    #[arg(long, global = true, value_name = "PATH")]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Inspect a device's network permissions
    #[command(subcommand)]
    Device(DeviceCommand),
    /// Inspect or reconcile an original VM creation without allocating another VM
    #[command(subcommand)]
    Creation(CreationCommand),
    /// Create a VM
    Create(CreateArgs),
    /// Grow an existing VM to at least the requested resources
    Resize(ResizeArgs),
    /// Show a VM
    Get(VmArg),
    /// Show the canonical allocation fingerprint, optionally checking whether the VM still exists
    Identity(IdentityArgs),
    /// List the team's VMs
    List(ListArgs),
    /// Start a stopped VM
    Start(VmArg),
    /// Stop a running VM
    Stop(VmArg),
    /// Pause a running VM, keeping its memory
    Pause(VmArg),
    /// Permanently fence a VM against starts and inbound wakes (requires confirmation)
    Retire(DeleteArgs),
    /// Resume a paused VM
    Resume(VmArg),
    /// Run a command in a VM (the guest's shell); fails when the command fails
    Exec(ExecArgs),
    /// Fork a VM into a new VM with the same memory and disk
    Fork(ForkArgs),
    /// Delete a VM permanently (asks to type the VM id, or needs --yes without a terminal)
    Delete(DeleteArgs),
    /// Create, list, show and delete snapshots
    #[command(subcommand)]
    Snapshot(SnapshotCommand),
    /// Mint and manage SSH client sessions for a VM
    #[command(name = "client-session", subcommand)]
    ClientSession(ClientSessionCommand),
    /// List approved service boot images
    #[command(subcommand)]
    Image(ImageCommand),
    /// Create, list and revoke API keys
    #[command(subcommand, name = "api-key")]
    ApiKey(ApiKeyCommand),
    /// Read guest file metadata without starting the VM
    #[command(subcommand)]
    File(FileCommand),
}

#[derive(Subcommand, Debug)]
enum CreationCommand {
    /// Discover server-issued handles after a lost create response
    List(CreationListArgs),
    /// Read retained creation intent and ownership without provider I/O
    Get(CreationArgs),
    /// Recover the original allocation; never creates, starts or grows a VM
    Reconcile(CreationArgs),
    /// Fence a pending creation and delete its verified allocation (requires confirmation)
    Cancel(CreationCancelArgs),
}

#[derive(Args, Debug)]
struct CreationCancelArgs {
    #[arg(long)]
    idempotency_key: String,
    /// Confirm cancellation without an interactive prompt
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
struct CreationArgs {
    /// The original creation's idempotency key
    #[arg(long)]
    idempotency_key: String,
}

#[derive(Args, Debug)]
struct CreationListArgs {
    /// List pending server-issued work newest first, without scanning completed history
    #[arg(long)]
    pending: bool,
    /// Backfill pages to advance before returning a resumable cursor (default 32)
    #[arg(long, requires = "pending", value_parser = clap::value_parser!(u32).range(1..=128))]
    index_pages: Option<u32>,
    /// Page size (1-100)
    #[arg(long, value_parser = clap::value_parser!(u32).range(1..=100))]
    limit: Option<u32>,
    /// Continue from a previous page's opaque cursor
    #[arg(long)]
    cursor: Option<String>,
}

#[derive(Subcommand, Debug)]
enum FileCommand {
    /// Show file metadata on a running, paused, stopped or retired VM
    Stat(FileStatArgs),
}

#[derive(Subcommand, Debug)]
enum DeviceCommand {
    /// Read public peer identities and directed overlay permissions
    OverlayPolicy(DeviceArg),
    /// Enroll a provider-free destination using a locally signed public request
    EnrollServer(ServerEnrollArgs),
    /// Approve public keys and print a short-lived server enrollment code
    ServerCode(ServerEnrollArgs),
    /// Redeem a signed code file without reading account configuration
    RedeemServerCode(ServerEnrollArgs),
    /// Read a provider-free server's identity
    GetServer(DeviceArg),
    /// List visible provider-free servers in a mesh
    Servers(ServerListArgs),
    /// Read a provider-free server's directed policy and Native tenant binding
    ServerPolicy(DeviceArg),
    /// Revoke a provider-free server identity (requires confirmation)
    RevokeServer(ServerRevokeArgs),
}

#[derive(Args, Debug)]
struct ServerEnrollArgs {
    /// Mesh id (mesh_...)
    mesh_id: String,
    /// Public binding JSON, or a signed enrollment JSON for enroll/redeem
    #[arg(long)]
    request: PathBuf,
}

#[derive(Args, Debug)]
struct ServerListArgs {
    mesh_id: String,
}

#[derive(Args, Debug)]
struct ServerRevokeArgs {
    device_id: String,
    /// Confirm revoking this identity without a prompt
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
struct DeviceArg {
    /// Device id (dev_...)
    device_id: String,
}

#[derive(Args, Debug)]
struct FileStatArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Absolute guest path, without parent segments
    path: String,
}

#[derive(Subcommand, Debug)]
enum SnapshotCommand {
    /// Capture a VM's memory and disk as a snapshot
    Create(SnapshotCreateArgs),
    /// Show a snapshot
    Get(SnapshotArg),
    /// List the team's snapshots
    List(SnapshotListArgs),
    /// Delete a snapshot permanently (asks to type the snapshot id, or needs --yes without a terminal)
    Delete(SnapshotDeleteArgs),
}

#[derive(Subcommand, Debug)]
enum ClientSessionCommand {
    /// Mint a one-time provider token and SSH line
    Create(ClientSessionCreateArgs),
    /// List live sessions without tokens
    List(ClientSessionVmArgs),
    /// Revoke one session
    Revoke(ClientSessionRevokeArgs),
}

#[derive(Args, Debug)]
struct ClientSessionVmArgs {
    /// VM id (vm_...)
    vm_id: String,
}

#[derive(Args, Debug)]
struct ClientSessionCreateArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Linux user for the SSH grant (defaults to ubuntu)
    #[arg(long)]
    user: Option<String>,
    /// Write the one-time token to this new file with mode 0600
    #[arg(long, value_name = "PATH")]
    token_file: Option<PathBuf>,
}

#[derive(Args, Debug)]
struct ClientSessionRevokeArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Client session id (vcs_...)
    session_id: String,
    /// Revoke without an interactive confirmation
    #[arg(long)]
    yes: bool,
}

#[derive(Subcommand, Debug)]
enum ImageCommand {
    /// List images available to this service and team
    List,
}

#[derive(Args, Debug)]
struct SnapshotArg {
    /// Snapshot id (snap_...)
    snapshot_id: String,
}

#[derive(Args, Debug)]
struct SnapshotDeleteArgs {
    /// Snapshot id (snap_...)
    snapshot_id: String,
    /// Delete without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
struct SnapshotCreateArgs {
    /// VM to capture (vm_...)
    vm_id: String,
    /// Display name
    #[arg(long)]
    name: Option<String>,
    /// Seconds the snapshot is kept after its last use (60-31536000)
    #[arg(long, value_name = "SECONDS")]
    ttl: Option<i64>,
    /// Seconds after creation when the snapshot is deleted (60-31536000)
    #[arg(long, value_name = "SECONDS")]
    auto_delete: Option<i64>,
    /// Reuse this key when retrying, so the snapshot is created only once [default: a new random key]
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

#[derive(Args, Debug)]
struct SnapshotListArgs {
    /// Only snapshots created by the authenticated caller
    #[arg(long)]
    created_by_me: bool,
    /// Page size (1-100)
    #[arg(long, value_parser = clap::value_parser!(u32).range(1..=100))]
    limit: Option<u32>,
    /// Continue from a previous page's next cursor
    #[arg(long)]
    cursor: Option<String>,
    /// Only snapshots captured from this VM (vm_...)
    #[arg(long, value_name = "VM_ID")]
    vm: Option<String>,
}

#[derive(Subcommand, Debug)]
enum ApiKeyCommand {
    /// Create an API key; the secret is printed once
    Create(ApiKeyCreateArgs),
    /// List the team's API keys (never their secrets)
    List,
    /// Revoke an API key (asks to type the key id, or needs --yes without a terminal)
    Revoke(ApiKeyRevokeArgs),
}

#[derive(Args, Debug)]
struct ApiKeyCreateArgs {
    /// Name of the key
    #[arg(long)]
    name: String,
    /// Scope to grant; repeat for several (vm:read, vm:write, vm:exec, vm:files,
    /// vm:terminal, snapshot:read, snapshot:write, snapshot:*, admin, ...)
    #[arg(long = "scope", value_name = "SCOPE", required = true)]
    scopes: Vec<String>,
    /// Limit the key to this VM or snapshot id; repeat for several [default: every resource of the team]
    #[arg(long = "resource", value_name = "ID")]
    resources: Vec<String>,
    /// Expiry as an RFC 3339 time; a key never outlives the credential that creates it
    #[arg(long, value_name = "TIME")]
    expires_at: Option<String>,
}

#[derive(Args, Debug)]
struct ApiKeyRevokeArgs {
    /// API key id (vmk_...)
    key_id: String,
    /// Revoke without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
struct VmArg {
    /// VM id (vm_...)
    vm_id: String,
}

#[derive(Args, Debug)]
struct ExecArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Kill the command after this many milliseconds
    #[arg(long)]
    timeout_ms: Option<u64>,
    /// The command; several words are joined with spaces (put them after `--`)
    #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
    command: Vec<String>,
}

#[derive(Args, Debug)]
struct IdentityArgs {
    vm_id: String,
    /// Read provider presence without starting the VM
    #[arg(long)]
    check_presence: bool,
}

#[derive(Args, Debug)]
struct DeleteArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Delete without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
struct ResizeArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Minimum vCPU count; larger current values are retained
    #[arg(long, value_parser = clap::value_parser!(u32).range(2..=32), required_unless_present_any = ["memory_mib", "disk_mib"])]
    vcpus: Option<u32>,
    /// Minimum memory in MiB
    #[arg(long, value_parser = clap::value_parser!(u32).range(4096..=65536))]
    memory_mib: Option<u32>,
    /// Minimum disk in MiB; growing the disk requires a running VM
    #[arg(long, value_parser = clap::value_parser!(u32).range(16384..=131072))]
    disk_mib: Option<u32>,
    /// Reuse this key when retrying the same resize
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

#[derive(Args, Debug)]
struct CreateArgs {
    /// Display name
    #[arg(long)]
    name: Option<String>,
    /// Boot from this snapshot (snap_...)
    #[arg(long, value_name = "SNAPSHOT_ID")]
    snapshot: Option<String>,
    /// Approved image id; requires --image-revision
    #[arg(
        long,
        value_name = "IMAGE_ID",
        requires = "image_revision",
        conflicts_with = "snapshot"
    )]
    image: Option<String>,
    /// Exact approved image revision
    #[arg(long, value_name = "REVISION", requires = "image")]
    image_revision: Option<String>,
    /// Allow public outbound traffic; requires vm:network
    #[arg(long)]
    public_egress: bool,
    /// Seconds without network activity before the VM pauses; -1 never pauses
    #[arg(long, value_name = "SECONDS", allow_negative_numbers = true)]
    idle_timeout: Option<i64>,
    /// Reuse this key when retrying, so the VM is created only once [default: a new random key]
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

#[derive(Args, Debug)]
struct ForkArgs {
    /// VM id to fork (vm_...)
    vm_id: String,
    /// Display name of the new VM
    #[arg(long)]
    name: Option<String>,
    /// Seconds without network activity before the new VM pauses; -1 never pauses
    #[arg(long, value_name = "SECONDS", allow_negative_numbers = true)]
    idle_timeout: Option<i64>,
    /// Reuse this key when retrying, so the fork happens only once [default: a new random key]
    #[arg(long, value_name = "KEY")]
    idempotency_key: Option<String>,
}

#[derive(Args, Debug)]
struct ListArgs {
    /// Only VMs created by the authenticated caller
    #[arg(long)]
    created_by_me: bool,
    /// Page size (1-100)
    #[arg(long, value_parser = clap::value_parser!(u32).range(1..=100))]
    limit: Option<u32>,
    /// Continue from a previous page's next cursor
    #[arg(long)]
    cursor: Option<String>,
    /// Only VMs in this state (starting, running, pausing, paused, stopped, unknown)
    #[arg(long)]
    state: Option<String>,
}

/// Runs the CLI with `args` (including the program name), reading
/// configuration through `env` and confirmations through `prompt`, and
/// returns the process exit code.
pub async fn run<I, T>(
    args: I,
    env: &dyn Fn(&str) -> Option<String>,
    prompt: &mut dyn Prompt,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> i32
where
    I: IntoIterator<Item = T>,
    T: Into<OsString> + Clone,
{
    let args: Vec<OsString> = args.into_iter().map(Into::into).collect();
    let cli = match Cli::try_parse_from(&args) {
        Ok(cli) => cli,
        Err(e) if !e.use_stderr() => {
            // --help and --version.
            let _ = stdout.write_all(e.render().to_string().as_bytes());
            return exit::OK;
        }
        Err(e) => {
            let rendered = e.render().to_string();
            if json_requested(&args) {
                CliError::usage(rendered.trim_end()).report(true, stderr);
            } else {
                let _ = stderr.write_all(rendered.as_bytes());
            }
            return exit::USAGE;
        }
    };
    let json = cli.json;
    match execute(cli, env, prompt, stdout, stderr).await {
        Ok(()) => exit::OK,
        Err(error) => {
            error.report(json, stderr);
            error.exit_code()
        }
    }
}

/// Whether `--json` appears before any `--`, so a parse failure can still be
/// reported as JSON.
fn json_requested(args: &[OsString]) -> bool {
    args.iter()
        .skip(1)
        .take_while(|a| a.as_os_str() != "--")
        .any(|a| a.as_os_str() == "--json")
}

// Bound the file and serialize through generated public types so extra local
// fields (including private keys) cannot enter an API request or an error.
fn server_request<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, CliError> {
    let file =
        std::fs::File::open(path).map_err(|_| CliError::usage("could not read server request"))?;
    let mut bytes = Vec::new();
    file.take(16_385)
        .read_to_end(&mut bytes)
        .map_err(|_| CliError::usage("could not read server request"))?;
    if bytes.len() > 16_384 {
        return Err(CliError::usage("server request exceeds 16 KiB"));
    }
    serde_json::from_slice(&bytes).map_err(|_| CliError::usage("invalid server request"))
}

async fn execute(
    cli: Cli,
    env: &dyn Fn(&str) -> Option<String>,
    prompt: &mut dyn Prompt,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> Result<(), CliError> {
    if matches!(
        &cli.command,
        Command::Device(DeviceCommand::RedeemServerCode(_))
    ) {
        if cli.config.is_some() || cli.team.is_some() {
            return Err(CliError::usage(
                "server code redemption uses --base-url or CMUX_VM_BASE_URL; --config and --team do not apply",
            ));
        }
        let base_url = cli
            .base_url
            .or_else(|| env("CMUX_VM_BASE_URL"))
            .unwrap_or_else(|| cmux_vm_client::DEFAULT_BASE_URL.to_owned());
        let client = cmux_vm_client::unauthenticated_raw_client(
            &base_url,
            concat!("cmux-vm/", env!("CARGO_PKG_VERSION")),
        )
        .map_err(|e| CliError::usage(e.to_string()))?;
        return dispatch(
            &client,
            cli.command,
            prompt,
            output::Printer::new(cli.json, stdout),
        )
        .await;
    }
    let settings = Settings::resolve(
        cli.base_url.as_deref(),
        cli.team.as_deref(),
        cli.config.as_deref(),
        env,
    )?;
    for warning in &settings.warnings {
        error::report_warning(warning, cli.json, stderr);
    }
    let client = cmux_vm_client::authenticated_raw_client(
        &settings.base_url,
        &settings.api_key,
        settings.team_id.as_deref(),
        concat!("cmux-vm/", env!("CARGO_PKG_VERSION")),
    )
    .map_err(|e| CliError::usage(e.to_string()))?;
    let out = output::Printer::new(cli.json, stdout);
    dispatch(&client, cli.command, prompt, out).await
}

async fn dispatch(
    client: &Client,
    command: Command,
    prompt: &mut dyn Prompt,
    mut out: output::Printer<'_>,
) -> Result<(), CliError> {
    match command {
        Command::Create(args) => {
            let image = args
                .image
                .as_ref()
                .zip(args.image_revision.as_ref())
                .map(|(id, revision)| json!({ "id": id, "revision": revision }));
            let body: types::CreateVmRequest = request_body(json!({
                "displayName": args.name,
                "snapshotId": args.snapshot,
                "idleTimeoutSeconds": args.idle_timeout,
                "image": image,
                "initialNetwork": args.public_egress.then(|| json!({ "publicEgress": true })),
            }))?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::VmsCreateVmIdempotencyKey>(&key_text)?;
            let vm = fetch_body(client.vms_create_vm(Some(&key), None, &body))
                .await
                .map_err(|e| e.with_idempotency_hint(&key_text))?;
            if args.image.is_some() || args.public_egress {
                let response: Option<Value> = serde_json::from_slice(&vm).ok();
                let confirmed = response.as_ref().is_some_and(|value| {
                    let image_confirmed = args.image.as_deref().is_none_or(|expected| {
                        value.pointer("/bootImage/id").and_then(Value::as_str) == Some(expected)
                            && value.pointer("/bootImage/revision").and_then(Value::as_str)
                                == args.image_revision.as_deref()
                    });
                    let network_confirmed = !args.public_egress
                        || value
                            .pointer("/initialNetwork/publicEgress")
                            .and_then(Value::as_bool)
                            == Some(true);
                    image_confirmed && network_confirmed
                });
                if !confirmed {
                    let public_id = serde_json::from_slice::<types::Vm>(&vm)
                        .ok()
                        .map(|value| value.id.to_string());
                    let message = match public_id {
                        Some(id) => format!("The API did not confirm the requested VM creation policy; inspect VM {id}. Creation may have succeeded"),
                        None => "The API did not confirm the requested VM creation policy; creation may have succeeded".to_owned(),
                    };
                    return Err(CliError::unexpected(format!(
                        "{message}; retry the same intent with --idempotency-key {key_text}"
                    )));
                }
            }
            out.vm(&vm)
        }
        Command::Resize(args) => {
            let vm_id = args.vm_id.parse::<types::VmId>().map_err(|error| {
                CliError::usage(format!("invalid VM id {:?}: {error}", args.vm_id))
            })?;
            let body: types::ResizeVmRequest = request_body(json!({ "resources": {
                "vcpus": args.vcpus, "memoryMib": args.memory_mib, "diskMib": args.disk_mib,
            }}))?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::VmsResizeVmIdempotencyKey>(&key_text)?;
            let response =
                fetch_body(client.vms_resize_vm(vm_id.as_str(), Some(&key), None, &body))
                    .await
                    .map_err(|e| e.with_retry_key(&key_text))?;
            let confirmed = serde_json::from_slice::<types::Vm>(&response)
                .ok()
                .is_some_and(|actual| {
                    actual.id.as_str() == vm_id.as_str()
                        && args
                            .vcpus
                            .is_none_or(|want| actual.resources.vcpus >= f64::from(want))
                        && args
                            .memory_mib
                            .is_none_or(|want| actual.resources.memory_mib >= f64::from(want))
                        && args
                            .disk_mib
                            .is_none_or(|want| actual.resources.disk_mib >= f64::from(want))
                });
            if !confirmed {
                return Err(CliError::unexpected(format!(
                    "The API did not confirm the requested resources for VM {}; inspect it and retry the same intent with --idempotency-key {key_text}",
                    vm_id.as_str()
                )));
            }
            out.vm(&response)
        }
        Command::Creation(command) => {
            let body = match command {
                CreationCommand::List(args) => {
                    let page = creation_history::fetch(
                        client,
                        args.cursor,
                        args.limit,
                        args.pending,
                        args.index_pages.unwrap_or(32),
                    )
                    .await?;
                    return out.creation_list(&page, args.pending, args.index_pages);
                }
                CreationCommand::Get(args) => {
                    let key = parse_key::<types::VmCreationsGetVmCreationIdempotencyKey>(
                        &args.idempotency_key,
                    )?;
                    fetch_body(client.vm_creations_get_vm_creation(&key, None)).await?
                }
                CreationCommand::Cancel(args) => {
                    let key = parse_key::<types::VmCreationsCancelVmCreationIdempotencyKey>(
                        &args.idempotency_key,
                    )?;
                    if !args.yes {
                        if !prompt.is_interactive() {
                            return Err(CliError::usage(
                                "creation cancel requires --yes without a terminal",
                            ));
                        }
                        let answer = prompt.ask("Cancel this pending VM creation and delete its allocation? Type cancel to confirm: ")
                            .map_err(|e| CliError::cancelled(format!("could not read confirmation: {e}")))?;
                        if answer.trim() != "cancel" {
                            return Err(CliError::cancelled(
                                "creation cancellation was not confirmed",
                            ));
                        }
                    }
                    return out.creation_cancellation(
                        &fetch_body(client.vm_creations_cancel_vm_creation(&key, None)).await?,
                    );
                }
                CreationCommand::Reconcile(args) => {
                    let key = parse_key::<types::VmCreationsReconcileVmCreationIdempotencyKey>(
                        &args.idempotency_key,
                    )?;
                    fetch_body(client.vm_creations_reconcile_vm_creation(&key, None)).await?
                }
            };
            out.creation(&body)
        }
        Command::Image(ImageCommand::List) => {
            let images = fetch_body(client.vms_list_vm_images(None)).await?;
            out.image_list(&images)
        }
        Command::Get(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_get_vm(&vm_id, None)).await?;
            out.vm(&vm)
        }
        Command::List(args) => {
            let cursor = parse_opt::<types::VmsListVmsCursor>("--cursor", args.cursor)?;
            let state = parse_opt::<types::VmsListVmsState>("--state", args.state)?;
            let limit = args.limit.map(|n| n.to_string());
            // Label filters (`label=key:value`) are not a CLI flag yet.
            let page = fetch_body(
                client.vms_list_vms(
                    args.created_by_me
                        .then_some(types::VmsListVmsCreatedBy::Caller),
                    cursor.as_ref(),
                    None,
                    limit.as_deref(),
                    state,
                    None,
                ),
            )
            .await?;
            out.vm_list(&page)
        }
        Command::Start(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_start_vm(&vm_id, None)).await?;
            out.vm(&vm)
        }
        Command::Identity(IdentityArgs {
            vm_id,
            check_presence,
        }) => {
            let id = vm_id
                .parse::<types::VmId>()
                .map_err(|_| CliError::usage("invalid VM id"))?;
            let presence = parse_opt(
                "--check-presence",
                check_presence.then(|| "true".to_owned()),
            )?;
            let body = fetch_body(client.vms_get_vm_instance_identity(id.as_str(), presence, None))
                .await?;
            let receipt: serde_json::Value = serde_json::from_slice(&body)
                .map_err(|_| CliError::unexpected("the VM instance identity is unconfirmed"))?;
            if receipt["id"] != id.as_str()
                || receipt["scheme"] != "sha256-v1"
                || (check_presence
                    && !matches!(receipt["presence"].as_str(), Some("present" | "missing")))
            {
                return Err(CliError::unexpected(
                    "the VM instance identity is unconfirmed",
                ));
            }
            out.identity(&body)
        }
        Command::Stop(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_stop_vm(&vm_id, None)).await?;
            out.vm(&vm)
        }
        Command::Pause(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_pause_vm(&vm_id, None)).await?;
            out.vm(&vm)
        }
        Command::Retire(DeleteArgs { vm_id, yes }) => {
            let id = vm_id
                .parse::<types::VmId>()
                .map_err(|_| CliError::usage("invalid VM id"))?;
            if !yes {
                confirm(prompt, Destroy::RetireVm, id.as_str())?;
            }
            let response = fetch_body(client.vms_retire_vm(id.as_str(), None)).await?;
            let receipt: serde_json::Value = serde_json::from_slice(&response).map_err(|_| {
                CliError::unexpected("retirement is unconfirmed; retry retire for the same VM")
            })?;
            if receipt["id"] != id.as_str()
                || receipt["retired"] != true
                || !matches!(receipt["state"].as_str(), Some("paused" | "stopped"))
            {
                return Err(CliError::unexpected(
                    "retirement is unconfirmed; retry retire for the same VM",
                ));
            }
            out.retired(&response, id.as_str())
        }
        Command::Exec(args) => {
            let body: types::ExecRequest = request_body(json!({
                "command": args.command.join(" "),
                "timeoutMs": args.timeout_ms,
            }))?;
            let result = fetch_body(client.exec_exec_vm(&args.vm_id, None, &body)).await?;
            out.exec(&result)
        }
        Command::Resume(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_resume_vm(&vm_id, None)).await?;
            out.vm(&vm)
        }
        Command::Fork(args) => {
            let body: types::ForkVmRequest = request_body(json!({
                "displayName": args.name,
                "idleTimeoutSeconds": args.idle_timeout,
            }))?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::VmsForkVmIdempotencyKey>(&key_text)?;
            let vm = fetch_body(client.vms_fork_vm(&args.vm_id, Some(&key), None, &body))
                .await
                .map_err(|e| e.with_idempotency_hint(&key_text))?;
            out.vm(&vm)
        }
        Command::Delete(DeleteArgs { vm_id, yes }) => {
            if !yes {
                confirm(prompt, Destroy::DeleteVm, &vm_id)?;
            }
            call(client.vms_delete_vm(&vm_id, None)).await?;
            out.deleted(&vm_id)
        }
        Command::ClientSession(command) => client_session(client, command, prompt, out).await,
        Command::Snapshot(command) => snapshot(client, command, prompt, out).await,
        Command::Device(DeviceCommand::OverlayPolicy(args)) => {
            let id = args
                .device_id
                .parse::<types::DeviceId>()
                .map_err(|_| CliError::usage("invalid device id"))?;
            let body = fetch_body(client.mesh_get_device_overlay_policy(id.as_str(), None)).await?;
            out.overlay_policy(&body)
        }
        Command::Device(DeviceCommand::EnrollServer(args)) => {
            let id = args
                .mesh_id
                .parse::<types::MeshId>()
                .map_err(|_| CliError::usage("invalid mesh id"))?;
            let request: types::EnrollDeviceRequest = server_request(&args.request)?;
            let body = fetch_body(client.overlay_servers_enroll_overlay_server(
                id.as_str(),
                None,
                None,
                &request,
            ))
            .await?;
            out.overlay_server(&body)
        }
        Command::Device(DeviceCommand::ServerCode(args)) => {
            let id = args
                .mesh_id
                .parse::<types::MeshId>()
                .map_err(|_| CliError::usage("invalid mesh id"))?;
            let request: types::OverlayServerBinding = server_request(&args.request)?;
            let body = fetch_body(client.overlay_servers_create_overlay_server_code(
                id.as_str(),
                None,
                None,
                &request,
            ))
            .await?;
            out.overlay_server_code(&body)
        }
        Command::Device(DeviceCommand::RedeemServerCode(args)) => {
            let id = args
                .mesh_id
                .parse::<types::MeshId>()
                .map_err(|_| CliError::usage("invalid mesh id"))?;
            let request: types::CodeEnrollOverlayServerRequest = server_request(&args.request)?;
            let body = fetch_body(
                client.overlay_server_device_code_enroll_overlay_server(id.as_str(), &request),
            )
            .await?;
            out.overlay_server(&body)
        }
        Command::Device(DeviceCommand::GetServer(args)) => {
            let id = args
                .device_id
                .parse::<types::DeviceId>()
                .map_err(|_| CliError::usage("invalid device id"))?;
            let body =
                fetch_body(client.overlay_servers_get_overlay_server(id.as_str(), None)).await?;
            out.overlay_server(&body)
        }
        Command::Device(DeviceCommand::Servers(args)) => {
            let id = args
                .mesh_id
                .parse::<types::MeshId>()
                .map_err(|_| CliError::usage("invalid mesh id"))?;
            let body =
                fetch_body(client.overlay_servers_list_overlay_servers(id.as_str(), None)).await?;
            out.overlay_server_list(&body)
        }
        Command::Device(DeviceCommand::ServerPolicy(args)) => {
            let id = args
                .device_id
                .parse::<types::DeviceId>()
                .map_err(|_| CliError::usage("invalid device id"))?;
            let body =
                fetch_body(client.overlay_servers_get_overlay_server_policy(id.as_str(), None))
                    .await?;
            let _: cmux_vm_client::types::OverlayServerPolicy = serde_json::from_slice(&body)
                .map_err(|_| CliError::unexpected("invalid server policy response"))?;
            out.overlay_policy(&body)
        }
        Command::Device(DeviceCommand::RevokeServer(args)) => {
            let id = args
                .device_id
                .parse::<types::DeviceId>()
                .map_err(|_| CliError::usage("invalid device id"))?;
            if !args.yes {
                confirm(prompt, Destroy::RevokeOverlayServer, id.as_str())?;
            }
            call(client.overlay_servers_revoke_overlay_server(id.as_str(), None)).await?;
            out.revoked(id.as_str())
        }
        Command::ApiKey(command) => api_key(client, command, prompt, out).await,
        Command::File(FileCommand::Stat(args)) => {
            let id = args
                .vm_id
                .parse::<types::VmId>()
                .map_err(|_| CliError::usage("invalid VM id"))?;
            if !args.path.starts_with('/')
                || args.path.contains('\0')
                || args.path.split('/').any(|part| part == "..")
                || args.path.encode_utf16().count() > 4096
            {
                return Err(CliError::usage(
                    "guest path must be absolute, at most 4096 characters, without parent segments or NUL",
                ));
            }
            let path = args
                .path
                .parse::<types::GuestPath>()
                .map_err(|_| CliError::usage("invalid guest path"))?;
            let body = fetch_body(client.files_stat_file(id.as_str(), &path, None)).await?;
            out.file_stat(&body)
        }
    }
}

async fn client_session(
    client: &Client,
    command: ClientSessionCommand,
    prompt: &mut dyn Prompt,
    mut out: output::Printer<'_>,
) -> Result<(), CliError> {
    match command {
        ClientSessionCommand::Create(args) => {
            let body: types::CreateClientSessionRequest = request_body(json!({
                "linuxUser": args.user,
            }))?;
            let reserved = match args.token_file.as_ref() {
                Some(path) => {
                    if path.to_str().is_none() {
                        return Err(CliError::usage(
                            "--token-file must be a UTF-8 path so JSON output can name it",
                        ));
                    }
                    Some((path.clone(), output::reserve_token_file(path)?))
                }
                None => None,
            };
            let response =
                match fetch_body(client.agents_create_client_session(&args.vm_id, None, &body))
                    .await
                {
                    Ok(response) => response,
                    Err(error) => {
                        // Keep the empty 0600 reservation in place. Removing
                        // by pathname after a network wait could unlink a
                        // different file if a parent was replaced.
                        return Err(error.for_vm(&args.vm_id, "client-session create"));
                    }
                };
            out.client_session_create(&response, reserved, &args.vm_id)
        }
        ClientSessionCommand::List(ClientSessionVmArgs { vm_id }) => {
            let response = fetch_body(client.agents_list_client_sessions(&vm_id, None))
                .await
                .map_err(|e| e.for_vm(&vm_id, "client-session list"))?;
            out.client_session_list(&response, &vm_id)
        }
        ClientSessionCommand::Revoke(ClientSessionRevokeArgs {
            vm_id,
            session_id,
            yes,
        }) => {
            if !yes {
                if !prompt.is_interactive() {
                    return Err(CliError::usage(format!(
                        "client-session revoke for VM {vm_id} session {session_id} requires --yes without a terminal"
                    )));
                }
                let answer = prompt
                    .ask(&format!(
                        "Revoke client session {session_id} on VM {vm_id}? Type the session id to confirm: "
                    ))
                    .map_err(|e| {
                        CliError::cancelled(format!("could not read confirmation: {e}"))
                    })?;
                if answer.trim() != session_id {
                    return Err(CliError::cancelled(format!(
                        "revocation of client session {session_id} on VM {vm_id} was not confirmed"
                    )));
                }
            }
            call(client.agents_revoke_client_session(&vm_id, &session_id, None))
                .await
                .map_err(|e| e.for_vm(&vm_id, "client-session revoke"))?;
            out.revoked_session(&vm_id, &session_id)
        }
    }
}

async fn snapshot(
    client: &Client,
    command: SnapshotCommand,
    prompt: &mut dyn Prompt,
    mut out: output::Printer<'_>,
) -> Result<(), CliError> {
    match command {
        SnapshotCommand::Create(args) => {
            let body: types::CreateSnapshotRequest = request_body(json!({
                "displayName": args.name,
                "ttlSeconds": args.ttl,
                "autoDeleteSeconds": args.auto_delete,
            }))?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::SnapshotsCreateSnapshotIdempotencyKey>(&key_text)?;
            let snapshot =
                fetch_body(client.snapshots_create_snapshot(&args.vm_id, Some(&key), None, &body))
                    .await
                    .map_err(|e| e.with_idempotency_hint(&key_text))?;
            out.snapshot(&snapshot)
        }
        SnapshotCommand::Get(SnapshotArg { snapshot_id }) => {
            let snapshot = fetch_body(client.snapshots_get_snapshot(&snapshot_id, None)).await?;
            out.snapshot(&snapshot)
        }
        SnapshotCommand::List(args) => {
            let cursor = parse_opt::<types::SnapshotsListSnapshotsCursor>("--cursor", args.cursor)?;
            let vm = parse_opt::<types::SnapshotsListSnapshotsSourceVmId>("--vm", args.vm)?;
            let limit = args.limit.map(|n| n.to_string());
            // Label filters (`labels=key:value`) are not a CLI flag yet.
            let page = fetch_body(
                client.snapshots_list_snapshots(
                    args.created_by_me
                        .then_some(types::SnapshotsListSnapshotsCreatedBy::Caller),
                    cursor.as_ref(),
                    None,
                    limit.as_deref(),
                    vm.as_ref(),
                    None,
                ),
            )
            .await?;
            out.snapshot_list(&page)
        }
        SnapshotCommand::Delete(SnapshotDeleteArgs { snapshot_id, yes }) => {
            if !yes {
                confirm(prompt, Destroy::DeleteSnapshot, &snapshot_id)?;
            }
            call(client.snapshots_delete_snapshot(&snapshot_id, None)).await?;
            out.deleted(&snapshot_id)
        }
    }
}

async fn api_key(
    client: &Client,
    command: ApiKeyCommand,
    prompt: &mut dyn Prompt,
    mut out: output::Printer<'_>,
) -> Result<(), CliError> {
    match command {
        ApiKeyCommand::Create(args) => {
            let resources = (!args.resources.is_empty()).then_some(args.resources);
            let body: types::CreateApiKeyRequest = request_body(json!({
                "name": args.name,
                "scopes": args.scopes,
                "resourceAllowlist": resources,
                "expiresAt": args.expires_at,
            }))?;
            let key = fetch_body(client.api_keys_create_api_key(None, &body)).await?;
            out.created_api_key(&key)
        }
        ApiKeyCommand::List => {
            let page = fetch_body(client.api_keys_list_api_keys(None)).await?;
            out.api_key_list(&page)
        }
        ApiKeyCommand::Revoke(ApiKeyRevokeArgs { key_id, yes }) => {
            if !yes {
                confirm(prompt, Destroy::RevokeApiKey, &key_id)?;
            }
            call(client.api_keys_revoke_api_key(&key_id, None)).await?;
            out.revoked(&key_id)
        }
    }
}

/// A destructive verb that needs confirmation.
#[derive(Clone, Copy)]
enum Destroy {
    RetireVm,
    DeleteVm,
    DeleteSnapshot,
    RevokeApiKey,
    RevokeOverlayServer,
}

impl Destroy {
    /// The verb, the verb capitalized, and the name of the id to type.
    fn words(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Destroy::RetireVm => ("retire", "Retire", "VM id"),
            Destroy::DeleteVm => ("delete", "Delete", "VM id"),
            Destroy::DeleteSnapshot => ("delete", "Delete", "snapshot id"),
            Destroy::RevokeApiKey => ("revoke", "Revoke", "API key id"),
            Destroy::RevokeOverlayServer => ("revoke", "Revoke", "device id"),
        }
    }
}

/// Asks a person at a terminal to type the id of what is about to be
/// destroyed. Without a terminal the caller (usually an agent or a script)
/// must pass `--yes` instead.
fn confirm(prompt: &mut dyn Prompt, action: Destroy, id: &str) -> Result<(), CliError> {
    let (verb, question_verb, id_name) = action.words();
    if !prompt.is_interactive() {
        return Err(CliError::usage(format!(
            "refusing to {verb} {id} without confirmation: stdin is not a terminal, so pass --yes"
        )));
    }
    let question = match action {
        Destroy::RetireVm => format!(
            "Retire {id} permanently? It cannot run again; files remain readable until deletion. Type the VM id to confirm: "
        ),
        Destroy::RevokeApiKey => format!(
            "{question_verb} {id}? Requests that use it will fail. Type the {id_name} to confirm: "
        ),
        _ => format!(
            "{question_verb} {id} permanently? This cannot be undone. Type the {id_name} to confirm: "
        ),
    };
    let answer = prompt
        .ask(&question)
        .map_err(|e| CliError::cancelled(format!("could not read the confirmation: {e}")))?;
    if answer.trim() == id {
        Ok(())
    } else {
        let past = match action {
            Destroy::RetireVm => "retired",
            Destroy::RevokeApiKey | Destroy::RevokeOverlayServer => "revoked",
            _ => "deleted",
        };
        Err(CliError::cancelled(format!(
            "the typed id did not match {id}; nothing was {past}"
        )))
    }
}

/// Success bodies larger than this are refused rather than buffered.
const MAX_RESPONSE_BODY: usize = 16 * 1024 * 1024;

/// Awaits one raw API call and returns its whole success body.
async fn fetch_body(
    request: impl std::future::Future<
        Output = Result<
            cmux_vm_client::raw::ResponseValue<ByteStream>,
            cmux_vm_client::raw::Error<ByteStream>,
        >,
    >,
) -> Result<Vec<u8>, CliError> {
    let mut stream = call(request).await?.into_inner();
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| {
            CliError::network(format!(
                "the response from the cmux VM API was cut off: {e}"
            ))
        })?;
        if bytes.len() + chunk.len() > MAX_RESPONSE_BODY {
            return Err(CliError::unexpected(
                "the cmux VM API response is larger than 16 MiB",
            ));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

/// Awaits one API call and maps its failure to a [`CliError`].
async fn call<T>(
    request: impl std::future::Future<
        Output = Result<
            cmux_vm_client::raw::ResponseValue<T>,
            cmux_vm_client::raw::Error<ByteStream>,
        >,
    >,
) -> Result<T, CliError> {
    match request.await {
        Ok(response) => Ok(response.into_inner()),
        Err(error) => Err(CliError::from_api(error).await),
    }
}

/// Builds a generated request type from JSON, dropping unset fields. Going
/// through serde keeps the CLI independent of the generated field types and
/// applies their string checks (lengths, id patterns) before any request is
/// sent; numeric ranges are left to the server.
fn request_body<T: serde::de::DeserializeOwned>(mut body: Value) -> Result<T, CliError> {
    if let Value::Object(fields) = &mut body {
        fields.retain(|_, v| !v.is_null());
    }
    serde_json::from_value(body).map_err(|e| CliError::usage(format!("invalid argument: {e}")))
}

fn parse_key<T>(key: &str) -> Result<T, CliError>
where
    T: std::str::FromStr,
    T::Err: std::fmt::Display,
{
    key.parse::<T>()
        .map_err(|e| CliError::usage(format!("invalid --idempotency-key {key:?}: {e}")))
}

/// A fresh idempotency key for one create, fork or resize.
///
/// The randomness comes from the standard library's `RandomState`, whose
/// SipHash keys are seeded from the OS once per process and advanced for each
/// new state, mixed with the clock. That gives at least 64 unpredictable bits
/// per process, which is enough here: the key only has to differ from this
/// team's other recent keys so that a retry is recognized and a new request is
/// not. It is not a secret and needs no cryptographic generator, so the CLI
/// does not add a UUID or RNG dependency for it.
fn new_idempotency_key() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut words = [0_u64; 2];
    for word in &mut words {
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default(),
        );
        *word = hasher.finish();
    }
    format!("cmux-vm-{:016x}{:016x}", words[0], words[1])
}

fn parse_opt<T>(flag: &str, value: Option<String>) -> Result<Option<T>, CliError>
where
    T: std::str::FromStr,
    T::Err: std::fmt::Display,
{
    value
        .map(|v| {
            v.parse::<T>()
                .map_err(|e| CliError::usage(format!("invalid {flag} {v:?}: {e}")))
        })
        .transpose()
}
