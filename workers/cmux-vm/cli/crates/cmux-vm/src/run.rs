//! `cmux-vm run [--sync] [--pull PATH]... [--keep] -- COMMAND...`: one command
//! on a fresh VM that is deleted when it ends (paused with `--keep`).
//!
//! The VM is created with an idle timeout and, unless kept, an auto-delete
//! window, so a client that dies mid-run leaves nothing billing for long: the
//! VM pauses once its traffic stops and the service deletes it after
//! `AUTO_DELETE_SECONDS` without running. An agent key's VMs also go when the
//! key expires or is revoked.
//!
//! Everything goes through `exec` (an agent key holds only `vm:read`,
//! `vm:write` and `vm:exec`): `--sync` uploads a gzip tarball of the directory
//! in 1 MB `stdinBase64` chunks and unpacks it in `/work` (or `~/work` when the
//! guest user cannot make `/work`); the command runs detached in its own
//! session with stdout and stderr in files, and the client reads new bytes of
//! both with long-polling `exec` calls, so output arrives while it runs and a
//! command may outlast one exec's five-minute limit. `--pull PATH` copies paths
//! under the work directory back into the local directory afterwards.
//!
//! What syncs: in a git work tree, the tracked and untracked-but-not-ignored
//! files (`git ls-files -co --exclude-standard`); elsewhere, every file. Build
//! and dependency directories (`node_modules`, `target`, `.git`, ...) and
//! credential-shaped files (`.env`, keys, `.npmrc`, ...) never sync, and the
//! local environment is never sent: no credential reaches the VM.
//!
//! The exit status is the command's; 124 when `--timeout` killed it and 130
//! when the run was interrupted. The last stderr line names the VM and what
//! happened to it (`deleted` or `paused`).

use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use clap::Args;
use cmux_vm_client::raw::{Client, types};
use serde_json::{Value, json};

use crate::error::CliError;
use crate::{exit, fetch_body, new_idempotency_key, parse_key, request_body};

/// Seconds without traffic before the VM pauses itself (`--idle-timeout`).
const DEFAULT_IDLE_TIMEOUT_SECONDS: i64 = 900;
/// A VM that is not kept is deleted once it has been this long without running.
const AUTO_DELETE_SECONDS: i64 = 900;
/// Raw bytes per upload or download chunk: 1 MB is 1,333,336 base64
/// characters, under the API's 1 MiB `stdinBase64` limit.
const CHUNK_BYTES: usize = 1_000_000;
/// The largest archive `--sync` uploads.
const MAX_SYNC_BYTES: u64 = 64 * 1024 * 1024;
/// The largest archive `--pull` downloads, and the most it may unpack to: the
/// guest reports both sizes, so neither is trusted past these.
const MAX_PULL_BYTES: u64 = 256 * 1024 * 1024;
const MAX_PULL_UNPACKED_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// How long one output poll waits in the guest for something new.
const POLL_WAIT_TENTHS: u32 = 200;
/// How long to wait for a new VM to reach `running`.
const BOOT_DEADLINE: Duration = Duration::from_secs(300);
/// Retries for a 429 or a 503 on one call, with backoff.
const RETRIES: u32 = 6;
/// Where the run keeps its files on the guest.
const RUN_DIR: &str = "/tmp/cmux-run";

/// Directories that never sync, at any depth.
const SKIPPED_DIRS: &[&str] = &[
    ".git",
    "node_modules",
    "target",
    "dist",
    ".next",
    ".turbo",
    ".venv",
    "__pycache__",
    "DerivedData",
    ".build",
];

/// Directories that hold credentials (cloud, cluster, registry and key
/// stores). Nothing under them syncs, at any depth, and they are reported.
const CREDENTIAL_DIRS: &[&str] = &[
    ".ssh",
    ".aws",
    ".gnupg",
    ".docker",
    ".kube",
    ".azure",
    ".gcloud",
    ".terraform.d",
    ".password-store",
    ".vercel",
];

/// Credential directories under `.config` (`.config/gcloud`, `.config/gh`).
const CREDENTIAL_CONFIG_DIRS: &[&str] = &["gcloud", "gh", "op", "doctl", "hub"];

#[derive(Args, Debug)]
pub struct RunArgs {
    /// Upload the current directory (or --dir) to the VM's work directory first
    #[arg(long)]
    sync: bool,
    /// The directory --sync uploads and --pull writes into [default: the current directory]
    #[arg(long, value_name = "DIR")]
    dir: Option<PathBuf>,
    /// Copy this path (relative to the work directory) back afterwards; repeat for several
    #[arg(long = "pull", value_name = "PATH")]
    pull: Vec<String>,
    /// Pause the VM at the end instead of deleting it (prints its id)
    #[arg(long)]
    keep: bool,
    /// Seconds without network traffic before the VM pauses itself
    #[arg(long, value_name = "SECONDS", default_value_t = DEFAULT_IDLE_TIMEOUT_SECONDS,
          value_parser = clap::value_parser!(i64).range(60..=86_400))]
    idle_timeout: i64,
    /// Kill the command after this many seconds (0: no limit)
    #[arg(long, value_name = "SECONDS", default_value_t = 3600)]
    timeout: u64,
    /// Minimum vCPU count
    #[arg(long, value_parser = clap::value_parser!(u32).range(2..=32))]
    vcpus: Option<u32>,
    /// Minimum memory in MiB
    #[arg(long, value_name = "MIB")]
    memory_mib: Option<u32>,
    /// The command. One word is a shell command line (`'bun test && bun run build'`);
    /// several are quoted one by one (`bun test foo.test.ts`)
    #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
    command: Vec<String>,
}

/// How a run ended.
enum Outcome {
    Exited(i32),
    TimedOut,
    Interrupted,
}

pub async fn run(
    client: &Client,
    args: RunArgs,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> Result<i32, CliError> {
    let local = match &args.dir {
        Some(dir) => dir.clone(),
        None => std::env::current_dir()
            .map_err(|e| CliError::usage(format!("no current directory: {e}")))?,
    };
    for path in &args.pull {
        check_pull_path(path)?;
    }
    let archive = if args.sync {
        let (bytes, synced) = archive(&local)?;
        note(
            stderr,
            &format!(
                "syncing {} files ({} KiB)",
                synced.files.len(),
                bytes.len().div_ceil(1024)
            ),
        );
        if !synced.credentials.is_empty() {
            note(
                stderr,
                &format!(
                    "not syncing {} credential files: {}",
                    synced.credentials.len(),
                    summary(&synced.credentials)
                ),
            );
        }
        if !synced.linked.is_empty() {
            note(
                stderr,
                &format!(
                    "not syncing {} files under a symlinked directory: {}",
                    synced.linked.len(),
                    summary(&synced.linked)
                ),
            );
        }
        Some(bytes)
    } else {
        None
    };
    let command = command_line(&args.command);

    // The signal handlers are in place before the VM exists. A signal while
    // the create call is in flight does not cancel it (its answer names the
    // VM to clean up); it only stops the run before any work.
    let signal = shutdown_signal();
    tokio::pin!(signal);
    let mut interrupted = false;
    let created = create(client, &args, &local);
    tokio::pin!(created);
    let vm_id = loop {
        tokio::select! {
            result = &mut created => break result?,
            () = &mut signal, if !interrupted => interrupted = true,
        }
    };
    note(stderr, &format!("vm {vm_id} created"));
    // From here every exit path ends the VM: a boot failure or timeout too.
    let outcome = if interrupted {
        Ok(Outcome::Interrupted)
    } else {
        tokio::select! {
            result = async {
                wait_running(client, &vm_id).await?;
                work(client, &vm_id, &args, archive.as_deref(), &command, &local, stdout, stderr).await
            } => result,
            () = &mut signal => Ok(Outcome::Interrupted),
        }
    };
    if matches!(outcome, Ok(Outcome::Interrupted)) {
        note(stderr, "interrupted");
    }
    let ended = finish(client, &vm_id, args.keep).await;
    match &ended {
        Ok(state) => note(stderr, &format!("vm {vm_id} {state}")),
        Err(error) => note(
            stderr,
            &format!(
                "vm {vm_id} was not cleaned up: {}; run `cmux vm rm {vm_id} --yes`",
                error.message()
            ),
        ),
    }
    let code = match outcome? {
        Outcome::Exited(code) => code,
        Outcome::TimedOut => {
            note(
                stderr,
                &format!(
                    "the command ran past --timeout {}s and was killed",
                    args.timeout
                ),
            );
            124
        }
        Outcome::Interrupted => 130,
    };
    ended?;
    Ok(code)
}

async fn create(client: &Client, args: &RunArgs, local: &Path) -> Result<String, CliError> {
    let name = local
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| format!("cmux run {}", name.chars().take(80).collect::<String>()));
    let resources = (args.vcpus.is_some() || args.memory_mib.is_some())
        .then(|| json!({ "vcpus": args.vcpus, "memoryMib": args.memory_mib }));
    let body: types::CreateVmRequest = request_body(json!({
        "displayName": name,
        "idleTimeoutSeconds": args.idle_timeout,
        "autoDeleteSeconds": (!args.keep).then_some(AUTO_DELETE_SECONDS),
        "resources": resources.map(drop_nulls),
        "labels": { "cmux.run": "1" },
    }))?;
    let key_text = new_idempotency_key();
    let key = parse_key::<types::VmsCreateVmIdempotencyKey>(&key_text)?;
    let created = retrying(|| fetch_body(client.vms_create_vm(Some(&key), None, &body)))
        .await
        .map_err(|e| e.with_idempotency_hint(&key_text))?;
    let vm: Value = serde_json::from_slice(&created)
        .map_err(|_| CliError::unexpected("the create response was not a VM"))?;
    let id = vm["id"]
        .as_str()
        .ok_or_else(|| CliError::unexpected("the create response named no VM"))?
        .to_owned();
    Ok(id)
}

async fn wait_running(client: &Client, vm_id: &str) -> Result<(), CliError> {
    let start = Instant::now();
    loop {
        let body = retrying(|| fetch_body(client.vms_get_vm(vm_id, None))).await?;
        let vm: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        match vm["state"].as_str() {
            Some("running") => return Ok(()),
            Some("starting") | None => {}
            Some(other) => {
                return Err(
                    CliError::unexpected(format!("the new VM is {other}, not running"))
                        .for_vm(vm_id, "run"),
                );
            }
        }
        if start.elapsed() > BOOT_DEADLINE {
            return Err(
                CliError::unexpected("the new VM did not start within 5 minutes")
                    .for_vm(vm_id, "run"),
            );
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

#[allow(clippy::too_many_arguments)]
async fn work(
    client: &Client,
    vm_id: &str,
    args: &RunArgs,
    archive: Option<&[u8]>,
    command: &str,
    local: &Path,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> Result<Outcome, CliError> {
    let workdir = prepare(client, vm_id, archive).await?;
    let launch = format!(
        "set -e; rm -rf {RUN_DIR}; mkdir -p {RUN_DIR}; cd {}; \
         setsid sh -c 'sh -c \"$CMUX_RUN_COMMAND\" >{RUN_DIR}/out 2>{RUN_DIR}/err </dev/null; \
         echo $? >{RUN_DIR}/rc.tmp; mv {RUN_DIR}/rc.tmp {RUN_DIR}/rc' >/dev/null 2>&1 </dev/null & \
         echo $! >{RUN_DIR}/pid",
        shell_quote(&workdir)
    );
    exec(
        client,
        vm_id,
        &launch,
        &[("CMUX_RUN_COMMAND", command)],
        30_000,
    )
    .await?;
    let outcome = follow(client, vm_id, args.timeout, stdout, stderr).await?;
    if !args.pull.is_empty() && !matches!(outcome, Outcome::Interrupted) {
        pull(client, vm_id, &workdir, &args.pull, local, stderr).await?;
    }
    Ok(outcome)
}

/// Makes the work directory, unpacks the archive into it and returns its path.
async fn prepare(client: &Client, vm_id: &str, archive: Option<&[u8]>) -> Result<String, CliError> {
    if let Some(archive) = archive {
        for (index, chunk) in archive.chunks(CHUNK_BYTES).enumerate() {
            let redirect = if index == 0 { ">" } else { ">>" };
            let script = format!("cat {redirect} /tmp/cmux-run.tgz");
            exec_stdin(client, vm_id, &script, chunk).await?;
        }
    }
    let unpack = if archive.is_some() {
        "tar -xzf /tmp/cmux-run.tgz -C \"$W\" && rm -f /tmp/cmux-run.tgz"
    } else {
        "true"
    };
    let script = format!(
        "W=/work; if ! {{ mkdir -p \"$W\" 2>/dev/null && [ -w \"$W\" ]; }}; then \
         if sudo -n mkdir -p \"$W\" 2>/dev/null && sudo -n chown \"$(id -u):$(id -g)\" \"$W\"; then :; \
         else W=\"$HOME/work\"; mkdir -p \"$W\"; fi; fi; {unpack} && printf %s \"$W\""
    );
    let result = exec(client, vm_id, &script, &[], 120_000).await?;
    if result.code != Some(0) {
        return Err(CliError::unexpected(format!(
            "could not prepare the work directory: {}",
            result.stderr.trim()
        ))
        .for_vm(vm_id, "run"));
    }
    Ok(String::from_utf8_lossy(&result.stdout).trim().to_owned())
}

/// Streams the command's output until it ends, the deadline passes or the
/// run is interrupted.
async fn follow(
    client: &Client,
    vm_id: &str,
    timeout: u64,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> Result<Outcome, CliError> {
    let deadline = (timeout > 0).then(|| Instant::now() + Duration::from_secs(timeout));
    let (mut out_at, mut err_at) = (0_u64, 0_u64);
    loop {
        if deadline.is_some_and(|deadline| Instant::now() > deadline) {
            let kill = format!(
                "kill -TERM -- -$(cat {RUN_DIR}/pid) 2>/dev/null; sleep 2; kill -KILL -- -$(cat {RUN_DIR}/pid) 2>/dev/null; true"
            );
            let _ = exec(client, vm_id, &kill, &[], 30_000).await;
            return Ok(Outcome::TimedOut);
        }
        let poll = format!(
            "d={RUN_DIR}; i=0; size() {{ stat -c %s \"$1\" 2>/dev/null || echo 0; }}; \
             while [ $i -lt {POLL_WAIT_TENTHS} ] && [ ! -f $d/rc ] && [ $(size $d/out) -le {out_at} ] && [ $(size $d/err) -le {err_at} ]; do sleep 0.1; i=$((i+1)); done; \
             cat $d/rc 2>/dev/null || echo -; \
             tail -c +{} $d/out 2>/dev/null | head -c {CHUNK_BYTES} | base64 -w0; echo; \
             tail -c +{} $d/err 2>/dev/null | head -c {CHUNK_BYTES} | base64 -w0; echo",
            out_at + 1,
            err_at + 1,
        );
        let result = exec(client, vm_id, &poll, &[], 60_000).await?;
        let text = String::from_utf8_lossy(&result.stdout).into_owned();
        let mut lines = text.split('\n');
        let rc = lines.next().unwrap_or("-").trim().to_owned();
        let out = decode(lines.next().unwrap_or(""))?;
        let err = decode(lines.next().unwrap_or(""))?;
        out_at += out.len() as u64;
        err_at += err.len() as u64;
        if !out.is_empty() {
            let _ = stdout.write_all(&out);
            let _ = stdout.flush();
        }
        if !err.is_empty() {
            let _ = stderr.write_all(&err);
            let _ = stderr.flush();
        }
        // Done once the exit status is there and nothing more was read.
        if rc != "-" && out.is_empty() && err.is_empty() {
            return Ok(Outcome::Exited(rc.parse().unwrap_or(exit::UNEXPECTED)));
        }
    }
}

async fn pull(
    client: &Client,
    vm_id: &str,
    workdir: &str,
    paths: &[String],
    local: &Path,
    stderr: &mut dyn Write,
) -> Result<(), CliError> {
    let quoted: Vec<String> = paths.iter().map(|path| shell_quote(path)).collect();
    let pack = format!(
        "cd {} && tar -czf /tmp/cmux-pull.tgz -- {} && stat -c %s /tmp/cmux-pull.tgz",
        shell_quote(workdir),
        quoted.join(" ")
    );
    let packed = exec(client, vm_id, &pack, &[], 300_000).await?;
    if packed.code != Some(0) {
        return Err(CliError::unexpected(format!(
            "--pull failed on the VM: {}",
            packed.stderr.trim()
        )));
    }
    let size: u64 = String::from_utf8_lossy(&packed.stdout)
        .trim()
        .parse()
        .map_err(|_| CliError::unexpected("--pull could not size its archive"))?;
    if size > MAX_PULL_BYTES {
        return Err(CliError::usage(format!(
            "--pull would download {} MiB, over the {} MiB limit; pull less",
            size / (1024 * 1024),
            MAX_PULL_BYTES / (1024 * 1024)
        )));
    }
    let mut bytes = Vec::with_capacity(usize::try_from(size.min(MAX_PULL_BYTES)).unwrap_or(0));
    while (bytes.len() as u64) < size {
        let read = format!(
            "tail -c +{} /tmp/cmux-pull.tgz | head -c {CHUNK_BYTES} | base64 -w0",
            bytes.len() + 1
        );
        let chunk = decode(
            String::from_utf8_lossy(&exec(client, vm_id, &read, &[], 60_000).await?.stdout).trim(),
        )?;
        if chunk.is_empty() {
            return Err(CliError::unexpected("--pull ended early"));
        }
        bytes.extend_from_slice(&chunk);
        if bytes.len() as u64 > size {
            return Err(CliError::unexpected(
                "--pull read more than the archive's size",
            ));
        }
    }
    unpack_local(&bytes, local)?;
    note(
        stderr,
        &format!("pulled {} into {}", paths.join(", "), local.display()),
    );
    Ok(())
}

/// Ends the VM: paused when kept, else deleted. Returns what happened.
async fn finish(client: &Client, vm_id: &str, keep: bool) -> Result<&'static str, CliError> {
    if keep {
        retrying(|| fetch_body(client.vms_pause_vm(vm_id, None))).await?;
        Ok("paused")
    } else {
        retrying(|| crate::call(client.vms_delete_vm(vm_id, None))).await?;
        Ok("deleted")
    }
}

struct ExecResult {
    code: Option<i32>,
    stdout: Vec<u8>,
    stderr: String,
}

async fn exec(
    client: &Client,
    vm_id: &str,
    script: &str,
    env: &[(&str, &str)],
    timeout_ms: u64,
) -> Result<ExecResult, CliError> {
    let env: serde_json::Map<String, Value> = env
        .iter()
        .map(|(name, value)| ((*name).to_owned(), json!(value)))
        .collect();
    let body: types::ExecRequest = request_body(json!({
        "command": script,
        "env": (!env.is_empty()).then_some(env),
        "timeoutMs": timeout_ms,
    }))?;
    send_exec(client, vm_id, &body).await
}

async fn exec_stdin(
    client: &Client,
    vm_id: &str,
    script: &str,
    stdin: &[u8],
) -> Result<(), CliError> {
    let body: types::ExecRequest = request_body(json!({
        "command": script,
        "stdinBase64": B64.encode(stdin),
        "timeoutMs": 120_000,
    }))?;
    let result = send_exec(client, vm_id, &body).await?;
    if result.code != Some(0) {
        return Err(CliError::unexpected(format!(
            "upload failed on the VM: {}",
            result.stderr.trim()
        ))
        .for_vm(vm_id, "run"));
    }
    Ok(())
}

async fn send_exec(
    client: &Client,
    vm_id: &str,
    body: &types::ExecRequest,
) -> Result<ExecResult, CliError> {
    let bytes = retrying(|| fetch_body(client.exec_exec_vm(vm_id, None, body))).await?;
    let result: Value = serde_json::from_slice(&bytes)
        .map_err(|_| CliError::unexpected("the exec response was not JSON"))?;
    Ok(ExecResult {
        code: result["exitCode"]
            .as_i64()
            .and_then(|code| i32::try_from(code).ok()),
        stdout: result["stdout"]
            .as_str()
            .unwrap_or_default()
            .as_bytes()
            .to_vec(),
        stderr: result["stderr"].as_str().unwrap_or_default().to_owned(),
    })
}

/// Retries a call the server refused for load (429, 503) with backoff.
async fn retrying<T, F, Fut>(mut call: F) -> Result<T, CliError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, CliError>>,
{
    let mut delay = Duration::from_millis(500);
    for _ in 0..RETRIES {
        match call().await {
            Err(error) if matches!(error.status(), Some(429 | 503)) => {
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(Duration::from_secs(10));
            }
            other => return other,
        }
    }
    call().await
}

/// Ctrl-C, or SIGTERM on Unix.
async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut term = match signal(SignalKind::terminate()) {
            Ok(term) => term,
            Err(_) => {
                let _ = tokio::signal::ctrl_c().await;
                return;
            }
        };
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

/// The guest command line: one word as written, several quoted one by one.
pub(crate) fn command_line(words: &[String]) -> String {
    match words {
        [one] => one.clone(),
        many => many
            .iter()
            .map(|word| shell_quote(word))
            .collect::<Vec<_>>()
            .join(" "),
    }
}

pub(crate) fn shell_quote(word: &str) -> String {
    if !word.is_empty()
        && word
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_./=:@%+,".contains(&b))
    {
        return word.to_owned();
    }
    format!("'{}'", word.replace('\'', "'\\''"))
}

/// A `--pull` path must stay inside the work directory.
pub(crate) fn check_pull_path(path: &str) -> Result<(), CliError> {
    let candidate = Path::new(path);
    let inside = !path.is_empty()
        && candidate
            .components()
            .all(|part| matches!(part, Component::Normal(_) | Component::CurDir));
    if inside {
        Ok(())
    } else {
        Err(CliError::usage(format!(
            "--pull {path:?} must be a relative path inside the work directory"
        )))
    }
}

/// Whether a file name looks like it holds a credential. Such files never sync.
pub(crate) fn credential_shaped(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    let env_template = matches!(
        lower.as_str(),
        ".env.example" | ".env.sample" | ".env.template" | ".env.dist"
    );
    (lower == ".env" || lower.starts_with(".env.")) && !env_template
        || [
            ".pem",
            ".key",
            ".p12",
            ".pfx",
            ".keychain",
            ".keychain-db",
            ".kdbx",
            ".jks",
        ]
        .iter()
        .any(|suffix| lower.ends_with(suffix))
        || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
            .iter()
            .any(|prefix| lower.starts_with(prefix))
        || matches!(
            lower.as_str(),
            ".npmrc"
                | ".pypirc"
                | ".netrc"
                | ".git-credentials"
                | ".dockercfg"
                | "credentials"
                | "credentials.json"
                | "service-account.json"
                | "vm.json"
                | "vm-token.json"
                | "agent-issuer.json"
        )
}

/// Whether a path (relative to the synced directory) is a credential: a
/// credential-shaped name, or anything under a credential directory.
pub(crate) fn credential_path(path: &Path) -> bool {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    if credential_shaped(name) {
        return true;
    }
    let parts: Vec<&std::ffi::OsStr> = path
        .parent()
        .map(|parent| parent.components().map(Component::as_os_str).collect())
        .unwrap_or_default();
    parts
        .iter()
        .any(|part| CREDENTIAL_DIRS.iter().any(|dir| *part == *dir))
        || parts.windows(2).any(|pair| {
            pair[0] == ".config" && CREDENTIAL_CONFIG_DIRS.iter().any(|dir| pair[1] == *dir)
        })
}

/// Whether every directory on the way to `path` is a real directory inside
/// `dir`, not a symlink: tar follows a symlinked directory, so a tracked
/// `src/a` whose `src` became a link would archive a file outside `dir`.
fn inside_without_links(dir: &Path, path: &Path) -> bool {
    let mut at = dir.to_path_buf();
    let Some(parent) = path.parent() else {
        return true;
    };
    for part in parent.components() {
        match part {
            Component::Normal(name) => at.push(name),
            Component::CurDir => continue,
            _ => return false,
        }
        match std::fs::symlink_metadata(&at) {
            Ok(meta) if meta.is_dir() => {}
            _ => return false,
        }
    }
    true
}

/// The files `--sync` uploads, relative to `dir`, the credential files it
/// leaves out, and the files it leaves out because a directory on their way
/// is a symlink.
pub(crate) fn sync_list(dir: &Path) -> Result<SyncList, CliError> {
    let listed = git_files(dir).map_or_else(|| walk(dir), Ok)?;
    let mut list = SyncList::default();
    for path in listed {
        let in_skipped_dir = path.parent().is_some_and(|parent| {
            parent
                .components()
                .any(|part| SKIPPED_DIRS.iter().any(|dir| part.as_os_str() == *dir))
        });
        if in_skipped_dir {
            continue;
        }
        if credential_path(&path) {
            list.credentials.push(path);
            continue;
        }
        if !inside_without_links(dir, &path) {
            list.linked.push(path);
            continue;
        }
        // Only regular files and symlinks: a gitlink (submodule) is a directory.
        match std::fs::symlink_metadata(dir.join(&path)) {
            Ok(meta) if meta.is_file() || meta.file_type().is_symlink() => list.files.push(path),
            _ => {}
        }
    }
    list.files.sort();
    list.credentials.sort();
    list.linked.sort();
    Ok(list)
}

#[derive(Debug, Default)]
pub(crate) struct SyncList {
    pub files: Vec<PathBuf>,
    pub credentials: Vec<PathBuf>,
    pub linked: Vec<PathBuf>,
}

fn git_files(dir: &Path) -> Option<Vec<PathBuf>> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let mut seen = std::collections::BTreeSet::new();
    Some(
        output
            .stdout
            .split(|b| *b == 0)
            .filter(|entry| !entry.is_empty())
            .filter_map(|entry| std::str::from_utf8(entry).ok().map(PathBuf::from))
            .filter(|path| seen.insert(path.clone()))
            .collect(),
    )
}

fn walk(dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    let mut out = Vec::new();
    let mut stack = vec![PathBuf::new()];
    while let Some(relative) = stack.pop() {
        let entries = std::fs::read_dir(dir.join(&relative)).map_err(|e| {
            CliError::usage(format!(
                "cannot read {}: {e}",
                dir.join(&relative).display()
            ))
        })?;
        for entry in entries.flatten() {
            let name = entry.file_name();
            let path = relative.join(&name);
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => {
                    if !SKIPPED_DIRS.iter().any(|skip| name == *skip) {
                        stack.push(path);
                    }
                }
                Ok(_) => out.push(path),
                Err(_) => {}
            }
        }
    }
    Ok(out)
}

/// A gzip tarball of the sync list, the number of files in it and the
/// credential-shaped files left out.
fn archive(dir: &Path) -> Result<(Vec<u8>, SyncList), CliError> {
    let synced = sync_list(dir)?;
    let mut list = Vec::new();
    for file in &synced.files {
        list.extend_from_slice(file.as_os_str().as_encoded_bytes());
        list.push(0);
    }
    let mut child = std::process::Command::new("tar")
        .current_dir(dir)
        // No AppleDouble files or extended attributes from macOS.
        .env("COPYFILE_DISABLE", "1")
        .args([
            "--no-recursion",
            "--no-xattrs",
            "--null",
            "-czf",
            "-",
            "-T",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| CliError::usage(format!("--sync needs tar: {e}")))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| CliError::unexpected("tar has no stdin"))?;
    let writer = std::thread::spawn(move || stdin.write_all(&list));
    let output = child
        .wait_with_output()
        .map_err(|e| CliError::unexpected(format!("tar failed: {e}")))?;
    let _ = writer.join();
    if !output.status.success() {
        return Err(CliError::unexpected(format!(
            "tar could not archive {}: {}",
            dir.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    if output.stdout.len() as u64 > MAX_SYNC_BYTES {
        return Err(CliError::usage(format!(
            "the sync archive is {} MiB, over the {} MiB limit; sync a smaller directory with --dir",
            output.stdout.len() / (1024 * 1024),
            MAX_SYNC_BYTES / (1024 * 1024)
        )));
    }
    Ok((output.stdout, synced))
}

/// Unpacks a pulled archive into `dir`, refusing entries that would land
/// outside it.
fn unpack_local(bytes: &[u8], dir: &Path) -> Result<(), CliError> {
    let unpacked = gunzipped_len(bytes, MAX_PULL_UNPACKED_BYTES)?;
    if unpacked > MAX_PULL_UNPACKED_BYTES {
        return Err(CliError::usage(format!(
            "--pull would unpack more than {} MiB; pull less",
            MAX_PULL_UNPACKED_BYTES / (1024 * 1024)
        )));
    }
    let listing = tar_with_stdin(&["-tzf", "-"], bytes, dir)?;
    for entry in String::from_utf8_lossy(&listing).lines() {
        if check_pull_path(entry.trim_end_matches('/')).is_err() {
            return Err(CliError::unexpected(format!(
                "--pull refused an archive entry outside the directory: {entry:?}"
            )));
        }
    }
    tar_with_stdin(&["-xzf", "-", "--no-same-owner"], bytes, dir).map(drop)
}

/// The unpacked size of a gzip stream, counted while it streams and stopped
/// once it passes `limit` (then a size past `limit` is returned).
fn gunzipped_len(bytes: &[u8], limit: u64) -> Result<u64, CliError> {
    use std::io::Read;
    let mut child = std::process::Command::new("gzip")
        .arg("-dc")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| CliError::usage(format!("--pull needs gzip: {e}")))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| CliError::unexpected("gzip has no stdin"))?;
    let data = bytes.to_vec();
    let writer = std::thread::spawn(move || stdin.write_all(&data));
    let mut out = child
        .stdout
        .take()
        .ok_or_else(|| CliError::unexpected("gzip has no stdout"))?;
    let mut total = 0_u64;
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = out
            .read(&mut buffer)
            .map_err(|e| CliError::unexpected(format!("gzip failed: {e}")))?;
        if read == 0 {
            break;
        }
        total += read as u64;
        if total > limit {
            break;
        }
    }
    drop(out);
    let _ = child.kill();
    let _ = child.wait();
    let _ = writer.join();
    Ok(total)
}

fn tar_with_stdin(args: &[&str], bytes: &[u8], dir: &Path) -> Result<Vec<u8>, CliError> {
    let mut child = std::process::Command::new("tar")
        .current_dir(dir)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| CliError::usage(format!("--pull needs tar: {e}")))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| CliError::unexpected("tar has no stdin"))?;
    let data = bytes.to_vec();
    let writer = std::thread::spawn(move || stdin.write_all(&data));
    let output = child
        .wait_with_output()
        .map_err(|e| CliError::unexpected(format!("tar failed: {e}")))?;
    let _ = writer.join();
    if !output.status.success() {
        return Err(CliError::unexpected(format!(
            "tar could not unpack the pulled files: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    Ok(output.stdout)
}

fn decode(text: &str) -> Result<Vec<u8>, CliError> {
    B64.decode(text.trim())
        .map_err(|_| CliError::unexpected("the VM sent output that is not base64"))
}

fn drop_nulls(mut value: Value) -> Value {
    if let Value::Object(fields) = &mut value {
        fields.retain(|_, v| !v.is_null());
    }
    value
}

fn summary(paths: &[PathBuf]) -> String {
    let mut names: Vec<String> = paths
        .iter()
        .take(5)
        .map(|path| path.display().to_string())
        .collect();
    if paths.len() > 5 {
        names.push(format!("and {} more", paths.len() - 5));
    }
    names.join(", ")
}

fn note(stderr: &mut dyn Write, message: &str) {
    let _ = writeln!(stderr, "cmux vm run: {message}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_word_is_a_command_line_and_several_are_quoted() {
        assert_eq!(
            command_line(&["bun test && bun run build".to_owned()]),
            "bun test && bun run build"
        );
        assert_eq!(
            command_line(&["bun".to_owned(), "--version".to_owned()]),
            "bun --version"
        );
        assert_eq!(
            command_line(&["echo".to_owned(), "it's".to_owned(), "a b".to_owned()]),
            "echo 'it'\\''s' 'a b'"
        );
    }

    #[test]
    fn pull_paths_stay_inside_the_work_directory() {
        assert!(check_pull_path("dist").is_ok());
        assert!(check_pull_path("./out/report.json").is_ok());
        assert!(check_pull_path("/etc/passwd").is_err());
        assert!(check_pull_path("../up").is_err());
        assert!(check_pull_path("a/../../b").is_err());
        assert!(check_pull_path("").is_err());
    }

    #[test]
    fn credential_shaped_files_never_sync() {
        for name in [
            ".env",
            ".env.local",
            "server.pem",
            "id_ed25519",
            "id_rsa.pub",
            ".npmrc",
            "vm-token.json",
            "x.KEY",
        ] {
            assert!(credential_shaped(name), "{name}");
        }
        for name in [
            ".env.example",
            "env.ts",
            "keys.ts",
            "package.json",
            "README.md",
            "monkey.txt",
        ] {
            assert!(!credential_shaped(name), "{name}");
        }
    }

    #[test]
    fn the_sync_list_skips_build_dirs_and_credentials_outside_git() {
        let dir = std::env::temp_dir().join(format!("cmux-vm-run-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for path in [
            "src/a.ts",
            "node_modules/x/index.js",
            "target/debug/b",
            ".env",
            "nested/.env.example",
            "nested/key.pem",
            ".docker/config.json",
            "deploy/.kube/config",
            "home/.config/gcloud/application_default_credentials.json",
            ".azure/accessTokens.json",
        ] {
            let full = dir.join(path);
            std::fs::create_dir_all(full.parent().unwrap()).unwrap();
            std::fs::write(&full, "x").unwrap();
        }
        let synced = sync_list(&dir).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        let (files, skipped) = (synced.files, synced.credentials);
        assert_eq!(
            files,
            vec![
                PathBuf::from("nested/.env.example"),
                PathBuf::from("src/a.ts")
            ]
        );
        assert_eq!(
            skipped,
            vec![
                PathBuf::from(".azure/accessTokens.json"),
                PathBuf::from(".docker/config.json"),
                PathBuf::from(".env"),
                PathBuf::from("deploy/.kube/config"),
                PathBuf::from("home/.config/gcloud/application_default_credentials.json"),
                PathBuf::from("nested/key.pem"),
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_file_under_a_symlinked_directory_never_syncs() {
        let base = std::env::temp_dir().join(format!("cmux-vm-run-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let (dir, outside) = (base.join("tree"), base.join("outside"));
        std::fs::create_dir_all(dir.join("ok")).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(dir.join("ok/a.txt"), "x").unwrap();
        std::fs::write(outside.join("secret.txt"), "s").unwrap();
        std::os::unix::fs::symlink(&outside, dir.join("src")).unwrap();
        assert!(inside_without_links(&dir, Path::new("ok/a.txt")));
        assert!(!inside_without_links(&dir, Path::new("src/secret.txt")));
        assert!(!inside_without_links(
            &dir,
            Path::new("../outside/secret.txt")
        ));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn an_oversized_pull_is_counted_and_stopped() {
        // 1 MiB of zeros gzips to about 1 KiB; the count stops past the limit.
        let raw = vec![0_u8; 1024 * 1024];
        let mut child = std::process::Command::new("gzip")
            .arg("-c")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let writer = std::thread::spawn(move || stdin.write_all(&raw));
        let gz = child.wait_with_output().unwrap().stdout;
        writer.join().unwrap().unwrap();
        assert_eq!(gunzipped_len(&gz, 4 * 1024 * 1024).unwrap(), 1024 * 1024);
        assert!(gunzipped_len(&gz, 1000).unwrap() > 1000);
    }
}
