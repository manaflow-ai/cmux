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
mod error;
mod output;
mod prompt;

pub use prompt::{NoPrompt, Prompt, StdinPrompt};

use std::ffi::OsString;
use std::io::Write;
use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};
use cmux_vm_client::raw::{ByteStream, Client, types};
use futures::StreamExt;
use serde_json::{Value, json};

use crate::config::Settings;
use crate::error::CliError;

const EXIT_CODES_HELP: &str = "\
Configuration:
  CMUX_VM_API_KEY    API key (or \"apiKey\" in the config file)
  CMUX_VM_BASE_URL   API base URL (or --base-url, or \"baseUrl\"); default https://vm.cmux.com
  CMUX_VM_TEAM_ID    team for session tokens (or --team, or \"teamId\")
  CMUX_VM_CONFIG     config file; default $XDG_CONFIG_HOME/cmux/vm.json or ~/.config/cmux/vm.json

Exit codes:
  0  success
  1  unexpected error (undocumented HTTP status or unreadable response)
  2  usage error
  3  network error (the API could not be reached)
  4  cancelled (delete was not confirmed)
  10 bad request (400)          11 not authenticated (401, or no API key)
  12 payment required (402)     13 forbidden, missing scope (403)
  14 not found (404)            15 conflict (409)
  16 quota or rate limit (429)  17 not available yet (501)
  18 service unavailable (503)";

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
    /// Create a VM
    Create(CreateArgs),
    /// Show a VM
    Get(VmArg),
    /// List the team's VMs
    List(ListArgs),
    /// Start a stopped VM
    Start(VmArg),
    /// Stop a running VM
    Stop(VmArg),
    /// Pause a running VM, keeping its memory
    Pause(VmArg),
    /// Resume a paused VM
    Resume(VmArg),
    /// Fork a VM into a new VM with the same memory and disk
    Fork(ForkArgs),
    /// Delete a VM permanently (asks to type the VM id, or needs --yes without a terminal)
    Delete(DeleteArgs),
}

#[derive(Args, Debug)]
struct VmArg {
    /// VM id (vm_...)
    vm_id: String,
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
struct CreateArgs {
    /// Display name
    #[arg(long)]
    name: Option<String>,
    /// Boot from this snapshot (snap_...)
    #[arg(long, value_name = "SNAPSHOT_ID")]
    snapshot: Option<String>,
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

async fn execute(
    cli: Cli,
    env: &dyn Fn(&str) -> Option<String>,
    prompt: &mut dyn Prompt,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> Result<(), CliError> {
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
            let body: types::CreateVmRequest = request_body(json!({
                "displayName": args.name,
                "snapshotId": args.snapshot,
                "idleTimeoutSeconds": args.idle_timeout,
            }))?;
            let key_text = args.idempotency_key.unwrap_or_else(new_idempotency_key);
            let key = parse_key::<types::VmsCreateVmIdempotencyKey>(&key_text)?;
            let vm = fetch_body(client.vms_create_vm(Some(&key), None, &body))
                .await
                .map_err(|e| e.with_idempotency_hint(&key_text))?;
            out.vm(&vm)
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
            let page = fetch_body(client.vms_list_vms(
                cursor.as_ref(),
                None,
                limit.as_deref(),
                state,
                None,
            ))
            .await?;
            out.vm_list(&page)
        }
        Command::Start(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_start_vm(&vm_id, None)).await?;
            out.vm(&vm)
        }
        Command::Stop(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_stop_vm(&vm_id, None)).await?;
            out.vm(&vm)
        }
        Command::Pause(VmArg { vm_id }) => {
            let vm = fetch_body(client.vms_pause_vm(&vm_id, None)).await?;
            out.vm(&vm)
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
                confirm_delete(prompt, &vm_id)?;
            }
            call(client.vms_delete_vm(&vm_id, None)).await?;
            out.deleted(&vm_id)
        }
    }
}

/// Asks a person at a terminal to type the VM id. Without a terminal the
/// caller (usually an agent or a script) must pass `--yes` instead.
fn confirm_delete(prompt: &mut dyn Prompt, vm_id: &str) -> Result<(), CliError> {
    if !prompt.is_interactive() {
        return Err(CliError::usage(format!(
            "refusing to delete {vm_id} without confirmation: stdin is not a terminal, so pass --yes"
        )));
    }
    let answer = prompt
        .ask(&format!(
            "Delete {vm_id} permanently? This cannot be undone. Type the VM id to confirm: "
        ))
        .map_err(|e| CliError::cancelled(format!("could not read the confirmation: {e}")))?;
    if answer.trim() == vm_id {
        Ok(())
    } else {
        Err(CliError::cancelled(format!(
            "the typed id did not match {vm_id}; nothing was deleted"
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

/// A fresh idempotency key for one create or fork.
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
