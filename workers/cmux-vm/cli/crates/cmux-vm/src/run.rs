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
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use clap::Args;
use cmux_vm_client::raw::{Client, types};
use serde_json::{Value, json};

use crate::error::CliError;
use crate::{exit, fetch_body, new_idempotency_key, parse_key, request_body};

/// A VM that is not kept is deleted once it has been this long without running.
const AUTO_DELETE_SECONDS: i64 = 900;
/// Time a run may spend past its command's `--timeout` (boot, sync, pull).
const RUN_MARGIN_SECONDS: u64 = 1800;
/// `--timeout`'s ceiling, which also bounds a run with no timeout.
const MAX_TIMEOUT_SECONDS: u64 = 604_800;
/// Raw bytes per upload or download chunk: 1 MB is 1,333,336 base64
/// characters, under the API's 1 MiB `stdinBase64` limit.
const CHUNK_BYTES: usize = 1_000_000;
/// The largest archive `--sync` uploads.
const MAX_SYNC_BYTES: u64 = 64 * 1024 * 1024;
/// The most a `--sync` archive may unpack to on the guest, which extracts it
/// with no limit of its own: 16 times the upload cap, past what source code
/// compresses by (text gzips about 4 to 8 times), so only a tree of
/// near-empty or sparse files (a large file of zeros) is refused.
const MAX_SYNC_UNPACKED_BYTES: u64 = 16 * MAX_SYNC_BYTES;
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
/// The API's limits on one exec, counted as it counts them: JavaScript string
/// length, in UTF-16 code units (`workers/cmux-vm/src/api.ts`, `ExecRequest`).
/// The command goes in one env value; `--pull` packs in one exec command.
const MAX_ENV_VALUE_UNITS: usize = 32 * 1024;
const MAX_EXEC_COMMAND_UNITS: usize = 64 * 1024;
/// The env variable that names the work directory to the `--pull` script, so
/// the script's size is known before the VM (and its directory) exists.
const WORKDIR_ENV: &str = "CMUX_RUN_WORKDIR";

/// Directories that never sync, at any depth, in any case (`skipped_dir`).
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

/// Directories whose `auth.json` is a coding agent's auth store
/// (`~/.codex/auth.json`, `~/.local/share/opencode/auth.json`).
const AGENT_AUTH_DIRS: &[&str] = &[".codex", "opencode"];

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
    /// Seconds without network traffic before the VM pauses itself, 60 to
    /// 86400, or -1 never to pause (CPU and disk work do not count). Default:
    /// the team's own (dev/test teams pause after 300 s, at most; others never)
    #[arg(long, value_name = "SECONDS", allow_negative_numbers = true, value_parser = idle_seconds)]
    idle_timeout: Option<i64>,
    /// Kill the command after this many seconds (0: no limit; at most 7 days).
    /// The VM itself is paused by the service 30 minutes past it (7 days with
    /// none), so a run whose client dies still ends
    #[arg(long, value_name = "SECONDS", default_value_t = 3600,
          value_parser = clap::value_parser!(u64).range(0..=MAX_TIMEOUT_SECONDS))]
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
    let command = command_line(&args.command);
    // What the API would refuse after the VM is created and billed, refused
    // here instead: the measured size of what is sent.
    check_command_size(&command)?;
    if !args.pull.is_empty() {
        check_pull_size(&args.pull)?;
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
        if !synced.hard_linked.is_empty() {
            note(
                stderr,
                &format!(
                    "not syncing {} hard-linked files (their bytes may be another path's): {}",
                    synced.hard_linked.len(),
                    summary(&synced.hard_linked)
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
    // Set once an archive may be on the guest, so every exit path below
    // (a failure or an interrupt included) removes it.
    let staged = AtomicBool::new(false);
    // From here every exit path ends the VM: a boot failure or timeout too.
    let outcome = if interrupted {
        Ok(Outcome::Interrupted)
    } else {
        tokio::select! {
            result = async {
                wait_running(client, &vm_id).await?;
                work(client, &vm_id, &args, archive.as_deref(), &command, &local, &staged, stdout, stderr).await
            } => result,
            () = &mut signal => Ok(Outcome::Interrupted),
        }
    };
    if matches!(outcome, Ok(Outcome::Interrupted)) {
        note(stderr, "interrupted");
    }
    if staged.load(Ordering::SeqCst) {
        remove_archives(client, &vm_id, args.keep, stderr).await;
    }
    let ended = finish(client, &vm_id, args.keep).await;
    let p = crate::error::program();
    match &ended {
        Ok(state) => note(stderr, &format!("vm {vm_id} {state}")),
        Err(error) => note(
            stderr,
            &format!(
                "vm {vm_id} was not cleaned up: {}; run `{p} delete {vm_id} --yes`",
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
    // The exit status is the command's, as documented; a cleanup that
    // failed is said above with the command that finishes it.
    drop(ended);
    Ok(code)
}

/// The service's bound on one run: `--timeout` (or its ceiling, with no
/// timeout) plus the margin for boot, sync and pull.
fn max_run_seconds(timeout: u64) -> u64 {
    let command = if timeout == 0 {
        MAX_TIMEOUT_SECONDS
    } else {
        timeout.min(MAX_TIMEOUT_SECONDS)
    };
    command + RUN_MARGIN_SECONDS
}

fn idle_seconds(text: &str) -> Result<i64, String> {
    match text.parse::<i64>() {
        Ok(seconds) if seconds == -1 || (60..=86_400).contains(&seconds) => Ok(seconds),
        _ => Err("takes 60 to 86400 seconds, or -1 never to pause".to_owned()),
    }
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
        // The service's own bound on the run: the client's --timeout ends
        // nothing if the client dies, so the service pauses the VM (and
        // then, unless kept, deletes it) on its own.
        "maxRunSeconds": max_run_seconds(args.timeout),
        "resources": resources.map(drop_nulls),
        "labels": { "cmux.run": "1" },
    }))?;
    let key_text = new_idempotency_key();
    let key = parse_key::<types::VmsCreateVmIdempotencyKey>(&key_text)?;
    let created = match retrying(|| fetch_body(client.vms_create_vm(Some(&key), None, &body))).await
    {
        Ok(created) => created,
        Err(error) if unconfirmed(&error) => {
            return match recover_creation(client, &key_text).await {
                // The create committed and only its answer was lost: run on
                // that VM, which every exit path below then ends.
                Recovered::Vm(id) => Ok(id),
                Recovered::Settled(what) => Err(error.with_recovery(what)),
                Recovered::Open(what) => Err(error.with_recovery(&what)),
            };
        }
        Err(error) => return Err(error),
    };
    let id = serde_json::from_slice::<Value>(&created)
        .ok()
        .and_then(|vm| vm["id"].as_str().map(str::to_owned));
    match id {
        Some(id) => Ok(id),
        // A 2xx whose body names no VM may still have allocated one: read it
        // back by its key, as for a lost answer.
        None => {
            let error = CliError::unexpected("the create response named no VM");
            match recover_creation(client, &key_text).await {
                Recovered::Vm(id) => Ok(id),
                Recovered::Settled(what) => Err(error.with_recovery(what)),
                Recovered::Open(what) => Err(error.with_recovery(&what)),
            }
        }
    }
}

/// A create that failed without a definite answer (the connection dropped, or
/// the server failed) may still have allocated a VM. 501 is a definite no.
/// So may a 429 for `capacity`: the server keeps a VM whose growth failed
/// after allocation, uncommitted, under the create's key. A 429 for another
/// budget (`rate`, `vms`, the agent key's) is refused before anything runs.
fn unconfirmed(error: &CliError) -> bool {
    match error.status() {
        Some(429) => error.budget().is_none_or(|budget| budget == "capacity"),
        Some(status) => status >= 500 && status != 501,
        None => error.exit_code() == exit::NETWORK,
    }
}

/// What an unconfirmed create left behind, read back by its idempotency key.
#[derive(Debug, PartialEq, Eq)]
enum Recovered {
    /// The create committed: this VM exists and the run goes on with it.
    Vm(String),
    /// Nothing is left running (never created, cancelled or deleted).
    Settled(&'static str),
    /// Cleanup is not confirmed; the text names the command that finishes it.
    Open(String),
}

/// Reads an unconfirmed create back by its key, cancels it while it is still
/// pending, and says what is left (with --keep a lost VM would have no
/// auto-delete deadline).
async fn recover_creation(client: &Client, key_text: &str) -> Recovered {
    let p = crate::error::program();
    let open = |why: &str| {
        Recovered::Open(format!(
            "{why}: run `{p} creation get --idempotency-key {key_text}`, then `{p} creation cancel --idempotency-key {key_text} --yes` while it is pending, or `{p} delete <id> --yes` once it is committed"
        ))
    };
    let Ok(get_key) = parse_key::<types::VmCreationsGetVmCreationIdempotencyKey>(key_text) else {
        return open("the create was not confirmed");
    };
    let read = || async {
        retrying(|| fetch_body(client.vm_creations_get_vm_creation(&get_key, None)))
            .await
            .map(|body| serde_json::from_slice::<Value>(&body).unwrap_or(Value::Null))
    };
    let status = match read().await {
        Ok(status) => status,
        // 404: the server holds no creation under this key, so none ran.
        Err(error) if error.status() == Some(404) => {
            return Recovered::Settled(
                "the create was not confirmed and the server holds no creation under its key",
            );
        }
        Err(_) => return open("the create was not confirmed and its state could not be read"),
    };
    match settled(&status) {
        Some(found) => return found,
        None if !matches!(status["state"].as_str(), Some("pending" | "cancelling")) => {
            return open("the create was not confirmed and its state is unresolved");
        }
        None => {}
    }
    let Ok(cancel_key) = parse_key::<types::VmCreationsCancelVmCreationIdempotencyKey>(key_text)
    else {
        return open("the create was not confirmed");
    };
    let cancelled =
        retrying(|| fetch_body(client.vm_creations_cancel_vm_creation(&cancel_key, None))).await;
    let answer = match cancelled {
        Ok(body) => serde_json::from_slice::<Value>(&body).unwrap_or(Value::Null),
        // 409: it committed or changed between the read and the cancel.
        Err(error) if error.status() == Some(409) => match read().await {
            Ok(status) => status,
            Err(_) => {
                return open("the create was not confirmed and changed while it was cancelled");
            }
        },
        Err(_) => return open("the create was not confirmed and its cancellation failed"),
    };
    settled(&answer).unwrap_or_else(|| {
        open("the create was not confirmed and its cancellation is still in progress")
    })
}

/// A creation state that needs nothing more: committed (with its VM), or gone.
fn settled(status: &Value) -> Option<Recovered> {
    match status["state"].as_str() {
        Some("committed") => status["id"].as_str().map(|id| Recovered::Vm(id.to_owned())),
        Some("cancelled") => Some(Recovered::Settled(
            "the create was not confirmed, and its VM was cancelled",
        )),
        Some("deleted") => Some(Recovered::Settled(
            "the create was not confirmed, and its VM is deleted",
        )),
        _ => None,
    }
}

async fn wait_running(client: &Client, vm_id: &str) -> Result<(), CliError> {
    let start = Instant::now();
    loop {
        let body = retrying(|| fetch_body(client.vms_get_vm(vm_id, None))).await?;
        let vm: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        match vm["state"].as_str() {
            Some("running") => return Ok(()),
            Some("starting" | "unknown") => {}
            None => {
                return Err(
                    CliError::unexpected("the VM API answered without the new VM's state")
                        .for_vm(vm_id, "run"),
                );
            }
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
    staged: &AtomicBool,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> Result<Outcome, CliError> {
    if archive.is_some() {
        staged.store(true, Ordering::SeqCst);
    }
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
        staged.store(true, Ordering::SeqCst);
        pull_archive(client, vm_id, &workdir, &args.pull, local, stderr).await?;
    }
    Ok(outcome)
}

/// Makes the work directory, unpacks the archive into it and returns its path.
async fn prepare(client: &Client, vm_id: &str, archive: Option<&[u8]>) -> Result<String, CliError> {
    if let Some(archive) = archive {
        for (index, chunk) in archive.chunks(CHUNK_BYTES).enumerate() {
            let redirect = if index == 0 { ">" } else { ">>" };
            let script = fenced(STAGING_GUARD, &format!("cat {redirect} {SYNC_ARCHIVE}"));
            exec_stdin(client, vm_id, &script, chunk).await?;
        }
    }
    // The archive goes once tar ends, whether it succeeded or not.
    let unpack = if archive.is_some() {
        "tar -xzf /tmp/cmux-run.tgz -C \"$W\"; r=$?; rm -f /tmp/cmux-run.tgz; [ $r -eq 0 ]"
    } else {
        "true"
    };
    let script = format!(
        "W=/work; if ! {{ mkdir -p \"$W\" 2>/dev/null && [ -w \"$W\" ]; }}; then \
         if sudo -n mkdir -p \"$W\" 2>/dev/null && sudo -n chown \"$(id -u):$(id -g)\" \"$W\"; then :; \
         else W=\"$HOME/work\"; mkdir -p \"$W\"; fi; fi; {unpack} && printf %s \"$W\""
    );
    // Unpacking reads the archive: a registered reader, which the cleanup
    // stops before it removes the archive.
    let script = if archive.is_some() {
        fenced(STAGING_GUARD, &script)
    } else {
        script
    };
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

/// The script that ends a timed-out command's process group. It exits 0
/// once no live process is left in the group (or the command already ended)
/// and non-zero when there is no usable pid or the group outlives SIGKILL.
/// The members come from /proc and are signalled one by one: the VM's shell
/// may be dash, whose `kill` cannot signal a group (`kill -- -PGID`).
fn kill_script(run_dir: &str) -> String {
    format!(
        "d={run_dir}; [ -f $d/rc ] && exit 0; p=$(cat $d/pid 2>/dev/null); \
         case \"$p\" in ''|*[!0-9]*|0|1) echo 'no process id for the command' >&2; exit 1;; esac; \
         members() {{ for s in /proc/[0-9]*/stat; do read -r l 2>/dev/null < $s || continue; \
         set -- ${{l##*) }}; [ \"$3\" = \"$p\" ] && [ \"$1\" != Z ] && {{ s=${{s#/proc/}}; echo ${{s%/stat}}; }}; done; }}; \
         m=$(members); [ -z \"$m\" ] && exit 0; kill -s TERM $m 2>/dev/null; \
         i=0; while [ $i -lt 20 ]; do m=$(members); [ -z \"$m\" ] && exit 0; sleep 0.1; i=$((i+1)); done; \
         kill -s KILL $m 2>/dev/null; sleep 0.2; [ -z \"$(members)\" ] || [ -f $d/rc ]"
    )
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
    let mut deadline = (timeout > 0).then(|| Instant::now() + Duration::from_secs(timeout));
    let (mut out_at, mut err_at) = (0_u64, 0_u64);
    loop {
        if deadline.is_some_and(|deadline| Instant::now() > deadline) {
            match exec(client, vm_id, &kill_script(RUN_DIR), &[], 30_000).await {
                Ok(killed) if killed.code == Some(0) => {}
                Ok(killed) => note(
                    stderr,
                    &format!("could not kill the command: {}", killed.stderr.trim()),
                ),
                Err(error) => note(
                    stderr,
                    &format!("could not kill the command: {}", error.message()),
                ),
            }
            return Ok(Outcome::TimedOut);
        }
        let wait = poll_wait_tenths(deadline, Instant::now());
        let poll = format!(
            "d={RUN_DIR}; i=0; size() {{ stat -c %s \"$1\" 2>/dev/null || echo 0; }}; \
             while [ $i -lt {wait} ] && [ ! -f $d/rc ] && [ $(size $d/out) -le {out_at} ] && [ $(size $d/err) -le {err_at} ]; do sleep 0.1; i=$((i+1)); done; \
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
        if rc != "-" {
            // Done once the exit status is there and nothing more was read.
            if out.is_empty() && err.is_empty() {
                return Ok(Outcome::Exited(rc.parse().unwrap_or(exit::UNEXPECTED)));
            }
            // The command has ended: reading the rest of its output is not
            // running past --timeout.
            deadline = None;
        }
    }
}

/// How long one guest poll may wait for output, in tenths of a second: never
/// past the `--timeout` deadline, so the command is killed on time.
fn poll_wait_tenths(deadline: Option<Instant>, now: Instant) -> u32 {
    let Some(deadline) = deadline else {
        return POLL_WAIT_TENTHS;
    };
    let left = deadline
        .saturating_duration_since(now)
        .as_millis()
        .div_ceil(100);
    u32::try_from(left)
        .unwrap_or(u32::MAX)
        .clamp(1, POLL_WAIT_TENTHS)
}

/// The guest's archive for `--sync`.
const SYNC_ARCHIVE: &str = "/tmp/cmux-run.tgz";
/// The guest's archive for `--pull`.
const PULL_ARCHIVE: &str = "/tmp/cmux-pull.tgz";

/// The guard against writers outliving the run's cleanup, as a path prefix:
/// `<guard>.fence` exists once the cleanup has begun, and `<guard>.writers/`
/// holds one file per guest command in progress that writes or reads an
/// archive (upload, unpack, pull pack and reads), named for its process
/// group. Each registers, then checks the fence; the cleanup makes the
/// fence, then stops every registered group. Whichever comes second sees
/// the other, so no writer or reader holds an archive after the cleanup
/// (an open file keeps its bytes even unlinked), not even one
/// whose exec was still on its way when the run was interrupted.
const STAGING_GUARD: &str = "/tmp/cmux-run";

/// Every archive a run may leave on the guest.
const ARCHIVES: [&str; 3] = [SYNC_ARCHIVE, PULL_ARCHIVE, "/tmp/cmux-pull.tgz.rc"];

/// `script` as a registered writer (or reader) of an archive under `guard`: in its own process group
/// (so the cleanup can stop all of it), refused with status 4 once the
/// cleanup has begun.
fn fenced(guard: &str, script: &str) -> String {
    let inner = format!(
        "mkdir -p {guard}.writers && : >{guard}.writers/$$ || exit 1; \
         trap 'rm -f {guard}.writers/'$$ EXIT; \
         if [ -e {guard}.fence ]; then echo 'the run is cleaning up' >&2; exit 4; fi; {script}"
    );
    format!("setsid -w sh -c {}", shell_quote(&inner))
}

/// The guest command that removes `archives` for good: it makes the fence,
/// kills every registered writer's process group (an upload or pull whose
/// exec outlived an interrupted client; an open file would keep its bytes
/// even unlinked) until none is left, then removes the archives. It fails
/// when they cannot be removed or a writer survives five seconds.
fn remove_archives_script(archives: &[&str], guard: &str) -> String {
    let files: Vec<String> = archives.iter().map(|path| shell_quote(path)).collect();
    let files = files.join(" ");
    format!(
        ": >{guard}.fence || exit 1; n=0; while :; do w=; \
         for m in {guard}.writers/*; do [ -e \"$m\" ] || continue; g=${{m##*/}}; a=; \
         for s in /proc/[0-9]*/stat; do read -r l 2>/dev/null <$s || continue; set -- ${{l##*) }}; \
         [ \"$3\" = \"$g\" ] && [ \"$1\" != Z ] && {{ s=${{s#/proc/}}; kill -s KILL ${{s%/stat}} 2>/dev/null; a=1; }}; done; \
         if [ -n \"$a\" ]; then w=1; else rm -f \"$m\"; fi; done; \
         [ -z \"$w\" ] && {{ rm -f {files} || exit 1; exit 0; }}; n=$((n+1)); \
         [ $n -ge 50 ] && {{ rm -f {files}; echo 'a writer outlived its kill' >&2; exit 1; }}; sleep 0.1; done"
    )
}

/// Removes the run's archives from the guest, whatever happened before: a
/// kept VM is billed for them and they hold the user's files. A failure is
/// reported when the VM is kept, with the command that finishes the job; a
/// VM that is not kept is deleted with them.
async fn remove_archives(client: &Client, vm_id: &str, keep: bool, stderr: &mut dyn Write) {
    let script = remove_archives_script(&ARCHIVES, STAGING_GUARD);
    let why = match exec(client, vm_id, &script, &[], 30_000).await {
        Ok(result) if result.code == Some(0) => return,
        Ok(result) => result.stderr.trim().to_owned(),
        Err(error) => error.message().to_owned(),
    };
    if keep {
        let p = crate::error::program();
        note(
            stderr,
            &format!(
                "could not remove the run's archives from the kept VM: {why}; run `{p} resume {vm_id}`, `{p} exec {vm_id} -- 'rm -f {}'`, then `{p} pause {vm_id}`",
                ARCHIVES.join(" ")
            ),
        );
    }
}

/// The guest command `--pull` sends to pack `paths`: the pack script, as a
/// registered archive writer. Its size is what the API limits.
fn pull_command(paths: &[String]) -> String {
    fenced(
        STAGING_GUARD,
        &pull_pack_script(paths, PULL_ARCHIVE, MAX_PULL_BYTES),
    )
}

/// Packs `paths` into `archive` on the guest and prints "SIZE TAR_STATUS",
/// from the work directory named by `$CMUX_RUN_WORKDIR`.
/// It writes at most one byte over `limit`, so an oversized pull stops there
/// instead of filling the guest's disk; tar's own status is kept apart, since
/// `head` ending the pipe early is the oversized case. A path whose parent
/// resolves outside the work directory (the command made `leak -> /etc`, then
/// `--pull leak/passwd`) is refused: tar would follow that link. A path that
/// is itself a link is archived as the link.
fn pull_pack_script(paths: &[String], archive: &str, limit: u64) -> String {
    let quoted: Vec<String> = paths.iter().map(|path| shell_quote(path)).collect();
    format!(
        "cd \"${WORKDIR_ENV}\" && w=$(pwd -P) && for p in {}; do \
         r=$(cd -- \"$(dirname -- \"$p\")\" 2>/dev/null && pwd -P) || continue; \
         case \"$r/\" in \"$w\"/*) ;; *) echo \"--pull $p leaves the work directory through a link\" >&2; exit 3;; esac; \
         done && {{ tar -czf - -- {}; echo $? >{archive}.rc; }} | head -c {} >{archive} && \
         echo \"$(stat -c %s {archive}) $(cat {archive}.rc)\"",
        quoted.join(" "),
        quoted.join(" "),
        limit + 1
    )
}

async fn pull_archive(
    client: &Client,
    vm_id: &str,
    workdir: &str,
    paths: &[String],
    local: &Path,
    stderr: &mut dyn Write,
) -> Result<(), CliError> {
    let pack = pull_command(paths);
    let packed = exec(client, vm_id, &pack, &[(WORKDIR_ENV, workdir)], 300_000).await?;
    let answer = String::from_utf8_lossy(&packed.stdout).trim().to_owned();
    let mut words = answer.split_whitespace();
    let size: Option<u64> = words.next().and_then(|size| size.parse().ok());
    let tar_ok = words.next() == Some("0");
    match size {
        Some(size) if size > MAX_PULL_BYTES => {
            return Err(CliError::usage(format!(
                "--pull would download more than {} MiB; pull less",
                MAX_PULL_BYTES / (1024 * 1024)
            )));
        }
        Some(_) if packed.code == Some(0) && tar_ok => {}
        _ => {
            return Err(CliError::unexpected(format!(
                "--pull failed on the VM: {}",
                packed.stderr.trim()
            )));
        }
    }
    let size = size.unwrap_or_default();
    let mut bytes = Vec::with_capacity(usize::try_from(size.min(MAX_PULL_BYTES)).unwrap_or(0));
    while (bytes.len() as u64) < size {
        let read = fenced(
            STAGING_GUARD,
            &format!(
                "tail -c +{} {PULL_ARCHIVE} | head -c {CHUNK_BYTES} | base64 -w0",
                bytes.len() + 1
            ),
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
    // An exec is not idempotent: a 503 can come after the command started
    // (the upstream link failed mid-call), so only a 429, which refuses the
    // call before it runs, is retried. A retry could run the command twice
    // or append an upload chunk twice.
    let bytes = retrying_on(&[429], || {
        fetch_body(client.exec_exec_vm(vm_id, None, body))
    })
    .await?;
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

/// Retries a call the server refused for load (429, 503) with backoff. Only
/// for calls that are safe to repeat: reads, and creates under one
/// idempotency key.
async fn retrying<T, F, Fut>(call: F) -> Result<T, CliError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, CliError>>,
{
    retrying_on(&[429, 503], call).await
}

/// Retries a call answered with one of `statuses`, with backoff.
async fn retrying_on<T, F, Fut>(statuses: &[u16], mut call: F) -> Result<T, CliError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, CliError>>,
{
    let mut delay = Duration::from_millis(500);
    for _ in 0..RETRIES {
        match call().await {
            Err(error)
                if error
                    .status()
                    .is_some_and(|status| statuses.contains(&status)) =>
            {
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

/// A string's length as the API counts it (JavaScript `length`).
fn api_length(text: &str) -> usize {
    text.encode_utf16().count()
}

/// The command must fit the API's limit on one env value.
pub(crate) fn check_command_size(command: &str) -> Result<(), CliError> {
    let length = api_length(command);
    if length <= MAX_ENV_VALUE_UNITS {
        return Ok(());
    }
    Err(CliError::usage(format!(
        "the command is {length} characters; the VM API takes at most {} KiB ({MAX_ENV_VALUE_UNITS} UTF-16 units). Put a long command in a script and --sync it",
        MAX_ENV_VALUE_UNITS / 1024
    )))
}

/// The `--pull` command, as it is sent (fenced), must fit the API's limit on one exec
/// command.
pub(crate) fn check_pull_size(paths: &[String]) -> Result<(), CliError> {
    let length = api_length(&pull_command(paths));
    if length <= MAX_EXEC_COMMAND_UNITS {
        return Ok(());
    }
    Err(CliError::usage(format!(
        "the --pull paths make a {length}-character guest command; the VM API takes at most {} KiB. Pull fewer paths, or a directory that holds them",
        MAX_EXEC_COMMAND_UNITS / 1024
    )))
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
                // Coding agents' auth stores (acpmux hub/pool/auth.rs).
                | ".credentials.json"
                | ".claude.json"
                | "oauth_creds.json"
        )
}

/// Whether a path (relative to the synced directory) is a credential: a
/// credential-shaped name, or anything under a credential directory.
pub(crate) fn credential_path(path: &Path) -> bool {
    // Lossy, so a name that is not UTF-8 is still matched on the parts that
    // are (`.env.<bad byte>` starts with `.env.`, `x<bad byte>.pem` ends
    // with `.pem`): it syncs as raw bytes, so it must be filtered too.
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy())
        .unwrap_or_default();
    if credential_shaped(&name) {
        return true;
    }
    // Any case: macOS volumes are case-insensitive by default, so `.AWS`
    // is the AWS CLI's `.aws` there.
    let parts: Vec<String> = path
        .parent()
        .map(|parent| {
            parent
                .components()
                .map(|part| part.as_os_str().to_string_lossy().to_ascii_lowercase())
                .collect()
        })
        .unwrap_or_default();
    // Codex's and opencode's auth stores have a generic name; their
    // directory makes them credentials.
    let agent_auth = name.eq_ignore_ascii_case("auth.json")
        && parts
            .last()
            .is_some_and(|dir| AGENT_AUTH_DIRS.contains(&dir.as_str()));
    agent_auth
        || parts
            .iter()
            .any(|part| CREDENTIAL_DIRS.contains(&part.as_str()))
        || parts
            .windows(2)
            .any(|pair| pair[0] == ".config" && CREDENTIAL_CONFIG_DIRS.contains(&pair[1].as_str()))
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

/// Whether `--sync` skips a directory of this name. Any case: on a
/// case-insensitive macOS volume `Node_Modules` is `node_modules`.
fn skipped_dir(name: &std::ffi::OsStr) -> bool {
    let name = name.to_string_lossy();
    SKIPPED_DIRS
        .iter()
        .any(|dir| name.eq_ignore_ascii_case(dir))
}

/// The files `--sync` uploads, relative to `dir`, the credential files it
/// leaves out, and the files it leaves out because a directory on their way
/// is a symlink.
pub(crate) fn sync_list(dir: &Path) -> Result<SyncList, CliError> {
    let listed = match git_files(dir)? {
        Some(listed) => listed,
        None => walk(dir)?,
    };
    // Credentials are judged by where they are, not only by their path in
    // `dir`: `--sync --dir ~/.codex` sends Codex's auth.json as `auth.json`.
    let root = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    let mut list = SyncList::default();
    for path in listed {
        let in_skipped_dir = path.parent().is_some_and(|parent| {
            parent
                .components()
                .any(|part| skipped_dir(part.as_os_str()))
        });
        if in_skipped_dir {
            continue;
        }
        if credential_path(&path) || credential_path(&root.join(&path)) {
            list.credentials.push(path);
            continue;
        }
        if !inside_without_links(dir, &path) {
            list.linked.push(path);
            continue;
        }
        // Only regular files and symlinks: a gitlink (submodule) is a directory.
        match std::fs::symlink_metadata(dir.join(&path)) {
            Ok(meta) if meta.is_file() && hard_linked(&meta) => list.hard_linked.push(path),
            Ok(meta) if meta.is_file() || meta.file_type().is_symlink() => list.files.push(path),
            _ => {}
        }
    }
    list.files.sort();
    list.hard_linked.sort();
    list.credentials.sort();
    list.linked.sort();
    Ok(list)
}

#[derive(Debug, Default)]
pub(crate) struct SyncList {
    pub files: Vec<PathBuf>,
    pub credentials: Vec<PathBuf>,
    pub linked: Vec<PathBuf>,
    /// Regular files with more than one link: their bytes may be another
    /// path's, a credential's that the name filter skipped, so they never sync.
    pub hard_linked: Vec<PathBuf>,
}

#[cfg(unix)]
fn hard_linked(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    meta.nlink() > 1
}

#[cfg(not(unix))]
fn hard_linked(_meta: &std::fs::Metadata) -> bool {
    false
}

/// Whether `dir` or a directory above it holds a `.git`.
fn in_a_repository(dir: &Path) -> bool {
    let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
    dir.ancestors().any(|at| at.join(".git").exists())
}

/// The files git would show in `dir`: tracked and untracked, without the
/// ignored ones. `Ok(None)` outside a git worktree (the caller walks the
/// directory instead); an error inside one whose files git cannot list,
/// since walking it would upload what .gitignore leaves out.
fn git_files(dir: &Path) -> Result<Option<Vec<PathBuf>>, CliError> {
    let inside = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--is-inside-work-tree"])
        .stderr(Stdio::null())
        .output();
    match inside {
        Ok(out) if out.status.success() && out.stdout.starts_with(b"true") => {}
        // Not a worktree by git's own answer: nothing for git to ignore.
        Ok(out) if out.status.success() => return Ok(None),
        // git could not say (not installed, or failing) and no `.git` here.
        _ if !in_a_repository(dir) => return Ok(None),
        // git could not say beside a `.git`: walking it would upload what
        // .gitignore leaves out.
        _ => {
            return Err(CliError::usage(format!(
                "--sync needs git to list {}'s files (it is inside a git repository) and git did not run",
                dir.display()
            )));
        }
    }
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
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| CliError::unexpected(format!("--sync could not run git ls-files: {e}")))?;
    if !output.status.success() {
        return Err(CliError::unexpected(format!(
            "--sync could not list {}'s files with git, so it does not know what .gitignore leaves out: {}",
            dir.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    let mut seen = std::collections::BTreeSet::new();
    Ok(Some(
        output
            .stdout
            .split(|b| *b == 0)
            .filter(|entry| !entry.is_empty())
            .filter_map(git_path)
            .filter(|path| seen.insert(path.clone()))
            .collect(),
    ))
}

/// A path from `git ls-files -z`: its bytes as they are on unix, so a name
/// that is not UTF-8 still syncs.
#[cfg(unix)]
fn git_path(entry: &[u8]) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(entry)))
}

#[cfg(not(unix))]
fn git_path(entry: &[u8]) -> Option<PathBuf> {
    std::str::from_utf8(entry).ok().map(PathBuf::from)
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
                    if !skipped_dir(&name) {
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
    archive_within(dir, MAX_SYNC_BYTES, MAX_SYNC_UNPACKED_BYTES)
}

/// The sync archive, refused past `limit` compressed or `unpacked_limit`
/// unpacked, before any VM exists. The guest's `tar -x` has no limit of its
/// own and needs none: the files' sizes are summed first (a sparse file
/// counts at its full length, which the guest writes out), and the tar
/// stream itself is counted on its way into gzip, so a file that grows
/// while it is packed is refused too.
fn archive_within(
    dir: &Path,
    limit: u64,
    unpacked_limit: u64,
) -> Result<(Vec<u8>, SyncList), CliError> {
    archive_within_then(dir, limit, unpacked_limit, || {})
}

/// [`archive_within`], running `before_pack` between the size sum and
/// packing (where a test grows a file).
fn archive_within_then(
    dir: &Path,
    limit: u64,
    unpacked_limit: u64,
    before_pack: impl FnOnce(),
) -> Result<(Vec<u8>, SyncList), CliError> {
    let synced = sync_list(dir)?;
    let sizes = synced
        .files
        .iter()
        .filter_map(|file| std::fs::symlink_metadata(dir.join(file)).ok())
        .filter(|meta| meta.is_file())
        .fold(0_u64, |total, meta| total.saturating_add(meta.len()));
    if sizes > unpacked_limit {
        return Err(unpacks_past(unpacked_limit));
    }
    before_pack();
    let archive = pack(dir, &synced.files, limit, unpacked_limit)?;
    Ok((archive, synced))
}

fn unpacks_past(unpacked_limit: u64) -> CliError {
    CliError::usage(format!(
        "the synced files would unpack to more than {} MiB on the VM; sync a smaller directory with --dir",
        unpacked_limit / (1024 * 1024)
    ))
}

/// `tar -c` of `files` piped through gzip, with the tar stream (what the
/// guest unpacks) counted against `unpacked_limit` and the gzip stream
/// against `limit`. Neither is held past one byte over its limit.
fn pack(
    dir: &Path,
    files: &[PathBuf],
    limit: u64,
    unpacked_limit: u64,
) -> Result<Vec<u8>, CliError> {
    pack_with("tar", dir, files, limit, unpacked_limit)
}

/// [`pack`] with the tar program named (a test packs with bsdtar).
fn pack_with(
    program: &str,
    dir: &Path,
    files: &[PathBuf],
    limit: u64,
    unpacked_limit: u64,
) -> Result<Vec<u8>, CliError> {
    use std::io::Read;
    let dense = dense_args(&tar_version(program)?);
    let mut list = Vec::new();
    for file in files {
        list.extend_from_slice(file.as_os_str().as_encoded_bytes());
        list.push(0);
    }
    let mut tar = tar_command(program)
        .current_dir(dir)
        // No AppleDouble files or extended attributes from macOS.
        .env("COPYFILE_DISABLE", "1")
        .args(dense)
        .args([
            "--no-recursion",
            "--no-xattrs",
            "--null",
            "-cf",
            "-",
            "-T",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| CliError::usage(format!("--sync needs tar: {e}")))?;
    let mut gzip = match std::process::Command::new("gzip")
        .args(["-c", "-n"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(gzip) => gzip,
        Err(e) => {
            let _ = tar.kill();
            let _ = tar.wait();
            return Err(CliError::usage(format!("--sync needs gzip: {e}")));
        }
    };
    let (Some(mut tar_in), Some(mut tar_out), Some(mut errors), Some(mut gzip_in), Some(gzip_out)) = (
        tar.stdin.take(),
        tar.stdout.take(),
        tar.stderr.take(),
        gzip.stdin.take(),
        gzip.stdout.take(),
    ) else {
        let _ = tar.kill();
        let _ = gzip.kill();
        let _ = tar.wait();
        let _ = gzip.wait();
        return Err(CliError::unexpected("tar or gzip has no pipes"));
    };
    let writer = std::thread::spawn(move || tar_in.write_all(&list));
    let error_reader = std::thread::spawn(move || {
        let mut text = Vec::new();
        let _ = errors.read_to_end(&mut text);
        text
    });
    let pump = std::thread::spawn(move || pump(&mut tar_out, &mut gzip_in, unpacked_limit));
    let mut archive = Vec::new();
    let read = gzip_out.take(limit + 1).read_to_end(&mut archive);
    let oversized = archive.len() as u64 > limit;
    if oversized {
        let _ = gzip.kill();
    }
    let pumped = pump.join().unwrap_or(Ok(true));
    let unpacked_over = matches!(pumped, Ok(true));
    if oversized || unpacked_over || pumped.is_err() {
        let _ = tar.kill();
    }
    let tar_status = tar.wait();
    let gzip_status = gzip.wait();
    let _ = writer.join();
    let tar_errors = error_reader.join().unwrap_or_default();
    if unpacked_over {
        return Err(unpacks_past(unpacked_limit));
    }
    if let Err(e) = pumped {
        return Err(CliError::unexpected(format!(
            "could not read tar's archive of {}: {e}",
            dir.display()
        )));
    }
    if oversized {
        return Err(CliError::usage(format!(
            "the sync archive is over the {} MiB limit; sync a smaller directory with --dir",
            limit / (1024 * 1024)
        )));
    }
    read.map_err(|e| CliError::unexpected(format!("gzip failed: {e}")))?;
    let tar_status = tar_status.map_err(|e| CliError::unexpected(format!("tar failed: {e}")))?;
    if !tar_status.success() {
        return Err(CliError::unexpected(format!(
            "tar could not archive {}: {}",
            dir.display(),
            String::from_utf8_lossy(&tar_errors).trim()
        )));
    }
    match gzip_status {
        Ok(status) if status.success() => Ok(archive),
        _ => Err(CliError::unexpected(format!(
            "gzip could not compress the archive of {}",
            dir.display()
        ))),
    }
}

/// The local `tar` command every sync and pull runs, with only the
/// arguments given here: options from the caller's environment
/// (`TAR_OPTIONS=--sparse` for GNU tar, `TAR_READER_OPTIONS` and
/// `TAR_WRITER_OPTIONS` for bsdtar) could shrink a hole past the
/// unpacked-size count or change how pulled files unpack.
fn tar_command(program: &str) -> std::process::Command {
    let mut command = std::process::Command::new(program);
    for name in ["TAR_OPTIONS", "TAR_READER_OPTIONS", "TAR_WRITER_OPTIONS"] {
        command.env_remove(name);
    }
    command
}

/// `tar --version`'s text; a tar that cannot say what it is is not run.
fn tar_version(program: &str) -> Result<String, CliError> {
    let output = tar_command(program)
        .arg("--version")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| CliError::usage(format!("--sync needs tar: {e}")))?;
    if !output.status.success() {
        return Err(CliError::usage("--sync needs tar: `tar --version` failed"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// What makes the local tar write a sparse file's holes as zeros, so the
/// stream count sees the size the guest unpacks to. bsdtar (macOS's tar)
/// stores holes as a map unless told `--no-read-sparse`; GNU tar writes
/// them out unless asked for `--sparse`, and takes no such flag.
fn dense_args(version: &str) -> &'static [&'static str] {
    if version.contains("bsdtar") {
        &["--no-read-sparse"]
    } else {
        &[]
    }
}

/// Counts what tar writes and passes it to gzip; `Ok(true)` one buffer past
/// `limit`, where it stops, which ends both streams (tar's on a broken pipe).
/// A read error is returned, never taken as the end of tar's stream: a
/// truncated archive would otherwise pass once tar had exited cleanly.
fn pump(from: &mut impl std::io::Read, to: &mut impl Write, limit: u64) -> std::io::Result<bool> {
    let mut total = 0_u64;
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = match from.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        total = total.saturating_add(read as u64);
        if total > limit {
            return Ok(true);
        }
        let Some(chunk) = buffer.get(..read) else {
            break;
        };
        if to.write_all(chunk).is_err() {
            break;
        }
    }
    Ok(false)
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
    let mut child = tar_command("tar")
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
    let _ = writeln!(stderr, "{} run: {message}", crate::error::program());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_poll_never_waits_past_the_deadline() {
        let now = Instant::now();
        assert_eq!(poll_wait_tenths(None, now), POLL_WAIT_TENTHS);
        assert_eq!(
            poll_wait_tenths(Some(now + Duration::from_secs(1)), now),
            10
        );
        assert_eq!(
            poll_wait_tenths(Some(now + Duration::from_millis(250)), now),
            3
        );
        assert_eq!(
            poll_wait_tenths(Some(now + Duration::from_secs(3600)), now),
            POLL_WAIT_TENTHS
        );
        // Past the deadline: one short wait, then the loop kills the command.
        assert_eq!(poll_wait_tenths(Some(now), now + Duration::from_secs(5)), 1);
    }

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
    fn only_a_create_without_a_definite_answer_is_cancelled() {
        assert!(unconfirmed(&CliError::network("connection reset")));
        assert!(unconfirmed(&CliError::from_status(503, b"")));
        assert!(unconfirmed(&CliError::from_status(500, b"")));
        assert!(!unconfirmed(&CliError::from_status(501, b"")));
        // Capacity may have allocated a VM (growth failed after it); the
        // other budgets refuse before anything runs.
        assert!(unconfirmed(&CliError::from_status(429, b"")));
        assert!(unconfirmed(&CliError::from_status(
            429,
            br#"{"_tag":"QuotaExceeded","budget":"capacity","message":"VM capacity is exhausted for now; retry later"}"#
        )));
        for budget in ["rate", "vms", "agent_vms", "agent_usd_per_hour"] {
            let body = format!(r#"{{"_tag":"QuotaExceeded","budget":"{budget}","message":"no"}}"#);
            assert!(
                !unconfirmed(&CliError::from_status(429, body.as_bytes())),
                "{budget}"
            );
        }
        assert!(!unconfirmed(&CliError::from_status(402, b"")));
        assert!(!unconfirmed(&CliError::usage("bad flag")));
    }

    #[test]
    fn a_recovered_creation_is_run_on_or_reported_by_its_state() {
        assert_eq!(
            settled(&json!({"state": "committed", "id": "vm_1"})),
            Some(Recovered::Vm("vm_1".to_owned()))
        );
        assert!(matches!(
            settled(&json!({"state": "cancelled", "id": "vm_1"})),
            Some(Recovered::Settled(_))
        ));
        assert!(matches!(
            settled(&json!({"state": "deleted", "id": "vm_1"})),
            Some(Recovered::Settled(_))
        ));
        assert_eq!(settled(&json!({"state": "cancelling", "id": "vm_1"})), None);
        assert_eq!(settled(&json!({"state": "pending", "id": "vm_1"})), None);
        assert_eq!(settled(&json!({"state": "committed"})), None);
    }

    #[test]
    fn the_command_is_measured_as_the_api_counts_it() {
        assert!(check_command_size(&"x".repeat(MAX_ENV_VALUE_UNITS)).is_ok());
        assert!(check_command_size(&"x".repeat(MAX_ENV_VALUE_UNITS + 1)).is_err());
        // Two bytes but one UTF-16 unit each: within the limit at 64 KiB.
        assert!(check_command_size(&"\u{e9}".repeat(MAX_ENV_VALUE_UNITS)).is_ok());
        // Four bytes and two units each.
        assert!(check_command_size(&"\u{1F600}".repeat(MAX_ENV_VALUE_UNITS / 2)).is_ok());
        let over = check_command_size(&"\u{1F600}".repeat(MAX_ENV_VALUE_UNITS / 2 + 1));
        assert_eq!(over.unwrap_err().exit_code(), exit::USAGE);
    }

    #[test]
    fn the_pull_script_is_measured_as_it_is_sent() {
        // One path of `len` safe characters, named twice: the longest that
        // fits leaves the command at the limit (or one under, since every
        // path adds an even count), and one character more is over it. The
        // command is the fenced script, as `pull_archive` sends it.
        let paths = |len: usize| vec!["a".repeat(len)];
        let sent = |paths: &[String]| api_length(&pull_command(paths));
        let bare =
            |paths: &[String]| api_length(&pull_pack_script(paths, PULL_ARCHIVE, MAX_PULL_BYTES));
        let one = sent(&paths(1));
        assert_eq!(sent(&paths(2)), one + 2);
        let at = 1 + (MAX_EXEC_COMMAND_UNITS - one) / 2;
        assert!(sent(&paths(at)) >= MAX_EXEC_COMMAND_UNITS - 1);
        assert!(sent(&paths(at)) <= MAX_EXEC_COMMAND_UNITS);
        assert!(check_pull_size(&paths(at)).is_ok());
        assert!(sent(&paths(at + 1)) > MAX_EXEC_COMMAND_UNITS);
        let over = check_pull_size(&paths(at + 1)).unwrap_err();
        assert_eq!(over.exit_code(), exit::USAGE);
        assert!(over.message().contains("--pull"), "{}", over.message());
        // The fence counts: this list's bare script would fit, the command
        // that is sent does not.
        assert!(bare(&paths(at + 1)) < MAX_EXEC_COMMAND_UNITS);
        // A quote is escaped again by the fence's quoting, and measured so.
        let quoted = vec!["it's".to_owned()];
        assert!(sent(&quoted) > bare(&quoted) + sent(&paths(4)) - bare(&paths(4)));
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
    fn the_service_bounds_every_run() {
        assert_eq!(max_run_seconds(3600), 3600 + RUN_MARGIN_SECONDS);
        assert_eq!(max_run_seconds(0), MAX_TIMEOUT_SECONDS + RUN_MARGIN_SECONDS);
        // Within the API's maximum (30 days).
        assert!(max_run_seconds(MAX_TIMEOUT_SECONDS) <= 2_592_000);
    }

    #[test]
    fn idle_timeout_takes_a_range_or_never() {
        assert_eq!(idle_seconds("-1"), Ok(-1));
        assert_eq!(idle_seconds("60"), Ok(60));
        assert_eq!(idle_seconds("86400"), Ok(86_400));
        for bad in ["0", "59", "-2", "86401", "x"] {
            assert!(idle_seconds(bad).is_err(), "{bad}");
        }
    }

    /// Unpredictable bytes, so gzip cannot shrink them below a limit.
    fn noise(len: usize) -> Vec<u8> {
        let mut state = 0x2545_f491_4f6c_dd1d_u64;
        (0..len)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state.to_le_bytes()[0]
            })
            .collect()
    }

    #[test]
    fn an_oversized_sync_is_refused_while_it_streams() {
        let dir = std::env::temp_dir().join(format!("cmux-vm-run-sync-cap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("big.bin"), noise(256 * 1024)).unwrap();
        let error = archive_within(&dir, 16 * 1024, u64::MAX).unwrap_err();
        assert!(error.message().contains("over the"), "{}", error.message());
        let (bytes, synced) = archive_within(&dir, 1024 * 1024, u64::MAX).unwrap();
        assert!(!bytes.is_empty() && bytes.len() <= 1024 * 1024);
        assert_eq!(synced.files, vec![PathBuf::from("big.bin")]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_sync_that_unpacks_past_its_limit_is_refused_before_upload() {
        let dir =
            std::env::temp_dir().join(format!("cmux-vm-run-sync-unpacked-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let limit = 1024 * 1024;
        // Zeros gzip to almost nothing, so only the unpacked size can refuse them.
        std::fs::write(dir.join("zeros.bin"), vec![0_u8; limit as usize + 1]).unwrap();
        let error = archive_within(&dir, MAX_SYNC_BYTES, limit).unwrap_err();
        assert!(error.message().contains("unpack"), "{}", error.message());
        // Just under, with room for tar's headers and its padding to a whole
        // 10 KiB record: it syncs.
        std::fs::write(
            dir.join("zeros.bin"),
            vec![0_u8; limit as usize - 16 * 1024],
        )
        .unwrap();
        let (bytes, synced) = archive_within(&dir, MAX_SYNC_BYTES, limit).unwrap();
        assert!(!bytes.is_empty() && (bytes.len() as u64) < limit);
        assert_eq!(synced.files, vec![PathBuf::from("zeros.bin")]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_sparse_file_counts_at_its_full_size() {
        let dir =
            std::env::temp_dir().join(format!("cmux-vm-run-sync-sparse-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A hole takes no disk here, but the guest's tar writes it out in full.
        let file = std::fs::File::create(dir.join("sparse.img")).unwrap();
        file.set_len(4 * 1024 * 1024 * 1024).unwrap();
        drop(file);
        let error = archive_within(&dir, MAX_SYNC_BYTES, MAX_SYNC_UNPACKED_BYTES).unwrap_err();
        assert!(error.message().contains("unpack"), "{}", error.message());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_packed_stream_is_counted_not_only_the_sizes_listed() {
        // What tar actually writes is counted: a file that grew after its
        // size was summed is still refused.
        let dir =
            std::env::temp_dir().join(format!("cmux-vm-run-sync-stream-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let limit = 1024 * 1024;
        std::fs::write(dir.join("grown.bin"), vec![0_u8; limit as usize + 1]).unwrap();
        let files = vec![PathBuf::from("grown.bin")];
        let error = pack(&dir, &files, MAX_SYNC_BYTES, limit).unwrap_err();
        assert!(error.message().contains("unpack"), "{}", error.message());
        assert!(pack(&dir, &files, MAX_SYNC_BYTES, 2 * limit).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_grows_after_the_size_sum_is_refused() {
        let dir =
            std::env::temp_dir().join(format!("cmux-vm-run-sync-grows-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let limit = 1024 * 1024;
        std::fs::write(dir.join("grows.bin"), b"x").unwrap();
        let grown = dir.join("grows.bin");
        let error = archive_within_then(&dir, MAX_SYNC_BYTES, limit, || {
            std::fs::write(&grown, vec![1_u8; limit as usize + 1]).unwrap();
        })
        .unwrap_err();
        assert!(error.message().contains("unpack"), "{}", error.message());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_sparse_file_bsdtar_packs_is_counted_at_its_full_size() {
        // bsdtar (macOS's tar) stores holes as a map, so its stream is tiny
        // while the guest writes the file out in full. `pack` is called
        // directly, as if the file turned sparse after the size sum. On
        // macOS bsdtar is `tar` itself.
        let Some(program) = ["tar", "bsdtar"].into_iter().find(|program| {
            std::process::Command::new(program)
                .arg("--version")
                .output()
                .is_ok_and(|out| String::from_utf8_lossy(&out.stdout).contains("bsdtar"))
        }) else {
            eprintln!("skipped: no bsdtar on this host");
            return;
        };
        let dir = std::env::temp_dir().join(format!(
            "cmux-vm-run-sync-bsdtar-sparse-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = std::fs::File::create(dir.join("sparse.img")).unwrap();
        file.set_len(256 * 1024 * 1024).unwrap();
        drop(file);
        let files = vec![PathBuf::from("sparse.img")];
        let error = pack_with(program, &dir, &files, MAX_SYNC_BYTES, 1024 * 1024).unwrap_err();
        assert!(error.message().contains("unpack"), "{}", error.message());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn tar_runs_with_none_of_the_callers_tar_options() {
        // `TAR_OPTIONS=--sparse` would let GNU tar shrink a hole past the
        // stream count; bsdtar reads the other two.
        let command = tar_command("tar");
        for name in ["TAR_OPTIONS", "TAR_READER_OPTIONS", "TAR_WRITER_OPTIONS"] {
            assert!(
                command
                    .get_envs()
                    .any(|(key, value)| key == name && value.is_none()),
                "{name} is passed through"
            );
        }
    }

    #[test]
    fn only_bsdtar_is_told_to_write_holes_out() {
        assert_eq!(
            dense_args("bsdtar 3.5.3 - libarchive 3.5.3 zlib/1.2.12 liblzma/5.0.5 bz2lib/1.0.8"),
            ["--no-read-sparse"]
        );
        assert!(dense_args("tar (GNU tar) 1.35\nCopyright (C) 2023").is_empty());
    }

    #[test]
    fn a_read_error_from_tar_is_not_the_end_of_the_stream() {
        struct Fails(bool);
        impl std::io::Read for Fails {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                if std::mem::replace(&mut self.0, true) {
                    return Err(std::io::Error::other("pipe read failed"));
                }
                buffer[..4].copy_from_slice(b"tar!");
                Ok(4)
            }
        }
        let mut sink = Vec::new();
        assert!(pump(&mut Fails(false), &mut sink, 1024).is_err());
        assert_eq!(sink, b"tar!");
        let mut sink = Vec::new();
        assert!(!pump(&mut &b"tar!"[..], &mut sink, 1024).unwrap());
        assert!(pump(&mut &b"tar!"[..], &mut Vec::new(), 3).unwrap());
    }

    // GNU stat, as on the guest.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_pull_pack_stops_one_byte_over_its_limit() {
        let base =
            std::env::temp_dir().join(format!("cmux-vm-run-pull-cap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let work = base.join("work");
        std::fs::create_dir_all(work.join("dist")).unwrap();
        std::fs::write(work.join("dist/big.bin"), noise(256 * 1024)).unwrap();
        let archive = base.join("pull.tgz");
        let archive = archive.to_str().unwrap();
        let run = |paths: &[&str], limit: u64| {
            let paths: Vec<String> = paths.iter().map(|p| (*p).to_owned()).collect();
            let script = pull_pack_script(&paths, archive, limit);
            let out = std::process::Command::new("sh")
                .arg("-c")
                .arg(&script)
                .env(WORKDIR_ENV, &work)
                .output()
                .unwrap();
            String::from_utf8(out.stdout).unwrap().trim().to_owned()
        };
        // Over the limit: the file stops at limit + 1 bytes.
        let answer = run(&["dist"], 4096);
        let size: u64 = answer.split_whitespace().next().unwrap().parse().unwrap();
        assert_eq!(size, 4097, "{answer}");
        assert_eq!(std::fs::metadata(archive).unwrap().len(), 4097);
        // Within it: the whole archive and tar's success.
        let answer = run(&["dist"], 1024 * 1024);
        let mut words = answer.split_whitespace();
        let size: u64 = words.next().unwrap().parse().unwrap();
        assert!(size > 0 && size <= 1024 * 1024, "{answer}");
        assert_eq!(words.next(), Some("0"), "{answer}");
        // A missing path: tar's failure is reported.
        let answer = run(&["missing"], 1024 * 1024);
        assert_ne!(answer.split_whitespace().nth(1), Some("0"), "{answer}");
        let _ = std::fs::remove_dir_all(&base);
    }

    // /proc, as on the guest.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_cleanup_stops_writers_and_fences_out_late_ones() {
        let base = std::env::temp_dir().join(format!("cmux-vm-run-cleanup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let path = |name: &str| base.join(name).to_str().unwrap().to_owned();
        let (upload, pulled, guard) = (path("run.tgz"), path("pull.tgz"), path("guard"));
        let sh = |script: &str| {
            std::process::Command::new("sh")
                .arg("-c")
                .arg(script)
                .stdin(Stdio::null())
                .output()
                .unwrap()
        };
        let cleanup = || {
            let out = sh(&remove_archives_script(&[&upload, &pulled], &guard));
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
        };
        let writers =
            || std::fs::read_dir(format!("{guard}.writers")).map_or(0, |entries| entries.count());
        // An upload whose client was interrupted: it holds its archive open
        // and is still writing (its stdin never closes).
        let mut writer = std::process::Command::new("sh")
            .arg("-c")
            .arg(fenced(&guard, &format!("cat > {upload}")))
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = writer.stdin.take().unwrap();
        stdin.write_all(b"the user's files").unwrap();
        stdin.flush().unwrap();
        while std::fs::metadata(&upload).map_or(0, |meta| meta.len()) == 0 {
            std::thread::sleep(Duration::from_millis(10));
        }
        // A pull that is past its fence check but has not opened its
        // archive yet.
        let mut late_opener = std::process::Command::new("sh")
            .arg("-c")
            .arg(fenced(&guard, &format!("sleep 1; echo pulled > {pulled}")))
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        while writers() < 2 {
            std::thread::sleep(Duration::from_millis(10));
        }
        cleanup();
        // Both are stopped, their archives are gone and none comes back.
        assert!(
            !writer.wait().unwrap().success(),
            "the upload was not stopped"
        );
        assert!(
            !late_opener.wait().unwrap().success(),
            "the pull was not stopped"
        );
        drop(stdin);
        std::thread::sleep(Duration::from_millis(1500));
        assert!(!Path::new(&upload).exists());
        assert!(!Path::new(&pulled).exists());
        assert_eq!(writers(), 0);
        // An upload or pull whose exec arrives after the cleanup writes nothing.
        let late = sh(&fenced(&guard, &format!("echo late > {upload}")));
        assert_eq!(late.status.code(), Some(4));
        assert!(!Path::new(&upload).exists());
        // With nothing to stop, the cleanup still succeeds.
        cleanup();
        let _ = std::fs::remove_dir_all(&base);
    }

    #[cfg(unix)]
    #[test]
    fn a_pull_never_leaves_the_work_directory_through_a_link() {
        let base =
            std::env::temp_dir().join(format!("cmux-vm-run-pull-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let work = base.join("work");
        std::fs::create_dir_all(work.join("dist")).unwrap();
        std::fs::write(work.join("dist/report.txt"), "report").unwrap();
        std::fs::create_dir_all(base.join("outside")).unwrap();
        std::fs::write(base.join("outside/secret"), "secret").unwrap();
        // What the command left behind: a link out, and a link that stays in.
        std::os::unix::fs::symlink(base.join("outside"), work.join("leak")).unwrap();
        std::os::unix::fs::symlink(work.join("dist"), work.join("alias")).unwrap();
        let archive = base.join("pull.tgz");
        let archive = archive.to_str().unwrap();
        let run = |path: &str| {
            let script = pull_pack_script(&[path.to_owned()], archive, 1 << 20);
            let out = std::process::Command::new("sh")
                .arg("-c")
                .arg(&script)
                .env(WORKDIR_ENV, &work)
                .output()
                .unwrap();
            let ok = out.status.success()
                && String::from_utf8_lossy(&out.stdout)
                    .split_whitespace()
                    .nth(1)
                    == Some("0");
            (ok, String::from_utf8_lossy(&out.stderr).into_owned())
        };
        let (ok, stderr) = run("leak/secret");
        assert!(!ok, "a pull through a link out of the work directory ran");
        assert!(stderr.contains("leak/secret"), "{stderr}");
        // The link itself is archived as a link, never followed.
        assert!(run("leak").0);
        // A link that stays inside the work directory is fine.
        assert!(run("alias/report.txt").0);
        assert!(run("dist/report.txt").0);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_worktree_git_cannot_list_is_refused_not_walked() {
        let dir =
            std::env::temp_dir().join(format!("cmux-vm-run-bad-index-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .unwrap()
        };
        assert!(git(&["init", "-q"]).status.success());
        std::fs::write(dir.join(".gitignore"), "secret.txt\n").unwrap();
        std::fs::write(dir.join("secret.txt"), "s").unwrap();
        std::fs::write(dir.join("a.txt"), "a").unwrap();
        assert!(git(&["add", "a.txt", ".gitignore"]).status.success());
        let listed = sync_list(&dir).unwrap();
        assert!(!listed.files.contains(&PathBuf::from("secret.txt")));
        // A corrupt index: git fails, and the ignored file is never walked into the sync.
        std::fs::write(dir.join(".git/index"), "not an index").unwrap();
        let error = sync_list(&dir).unwrap_err();
        assert!(error.message().contains("git"), "{}", error.message());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_dot_git_above_marks_a_repository() {
        let base = std::env::temp_dir().join(format!("cmux-vm-run-dotgit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("repo/.git")).unwrap();
        std::fs::create_dir_all(base.join("repo/src")).unwrap();
        std::fs::create_dir_all(base.join("plain")).unwrap();
        assert!(in_a_repository(&base.join("repo/src")));
        assert!(in_a_repository(&base.join("repo")));
        // A `.git` file (a linked worktree) counts too.
        std::fs::create_dir_all(base.join("linked")).unwrap();
        std::fs::write(base.join("linked/.git"), "gitdir: /elsewhere").unwrap();
        assert!(in_a_repository(&base.join("linked")));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn skipped_directories_match_in_any_case() {
        for name in [
            "node_modules",
            "Node_Modules",
            ".GIT",
            "Target",
            "deriveddata",
        ] {
            assert!(skipped_dir(std::ffi::OsStr::new(name)), "{name}");
        }
        assert!(!skipped_dir(std::ffi::OsStr::new("src")));
    }

    #[test]
    fn syncing_a_credential_directory_itself_sends_none_of_it() {
        // `--sync --dir ~/.codex` or `--dir ~/.config/gh`: the files are
        // credentials by where the synced directory is, not their own path.
        let base =
            std::env::temp_dir().join(format!("cmux-vm-run-cred-root-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        for (dir, file) in [
            (".codex", "auth.json"),
            (".config/gh", "hosts.yml"),
            (".aws", "config"),
        ] {
            std::fs::create_dir_all(base.join(dir)).unwrap();
            std::fs::write(base.join(dir).join(file), "secret").unwrap();
            let list = sync_list(&base.join(dir)).unwrap();
            assert!(list.files.is_empty(), "{dir}: {:?}", list.files);
            assert_eq!(list.credentials, vec![PathBuf::from(file)], "{dir}");
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn agent_credentials_never_sync() {
        // The coding agents' auth stores (acpmux hub/pool/auth.rs), in a
        // project-local agent home or a synced home directory.
        for path in [
            ".claude/.credentials.json",
            "home/.claude.json",
            ".codex/auth.json",
            "agents/.CODEX/auth.json",
            ".local/share/opencode/auth.json",
            ".gemini/oauth_creds.json",
        ] {
            assert!(credential_path(Path::new(path)), "{path}");
        }
        // An auth.json that is not an agent's store still syncs.
        assert!(!credential_path(Path::new("src/fixtures/auth.json")));
        assert!(!credential_path(Path::new(".claude/settings.json")));
    }

    #[test]
    fn credential_directories_match_in_any_case() {
        // macOS volumes are case-insensitive by default: `.AWS/config` is
        // the AWS CLI's `.aws/config` there.
        for path in [
            ".AWS/config",
            ".Ssh/id_custom",
            "src/.KUBE/config",
            ".CONFIG/GH/hosts.yml",
            ".config/Gh/hosts.yml",
        ] {
            assert!(credential_path(Path::new(path)), "{path}");
        }
        assert!(!credential_path(Path::new("src/Config/gh.rs")));
    }

    #[cfg(unix)]
    #[test]
    fn the_kill_script_reports_a_command_it_cannot_find_or_kill() {
        use std::os::unix::process::CommandExt;
        let dir = std::env::temp_dir().join(format!("cmux-vm-run-kill-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let run = |dir: &Path| {
            std::process::Command::new("sh")
                .arg("-c")
                .arg(kill_script(&dir.display().to_string()))
                .status()
                .unwrap()
                .success()
        };
        // No pid file and no exit status: nothing was killed.
        assert!(!run(&dir));
        // A pid file that does not name a process group (never `kill -- -1`).
        for pid in ["", "1", "0", "x1"] {
            std::fs::write(dir.join("pid"), pid).unwrap();
            assert!(!run(&dir), "{pid:?}");
        }
        // A command that already ended is not a failure.
        std::fs::write(dir.join("rc"), "0").unwrap();
        assert!(run(&dir));
        std::fs::remove_file(dir.join("rc")).unwrap();
        // A running command group is ended. It is reaped as it ends (on the
        // VM, init reaps it), so the script sees it gone, not a zombie.
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();
        std::fs::write(dir.join("pid"), child.id().to_string()).unwrap();
        let reaped = std::thread::spawn(move || child.wait().unwrap());
        assert!(run(&dir));
        assert!(!reaped.join().unwrap().success());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn credential_names_that_are_not_utf8_never_sync() {
        use std::os::unix::ffi::OsStrExt;
        for name in [
            &b".env.\xff"[..],
            b"private-\xff.pem",
            b"id_rsa\xff",
            b"\xff.key",
        ] {
            let path = Path::new(std::ffi::OsStr::from_bytes(name));
            assert!(credential_path(path), "{path:?}");
            assert!(credential_path(&Path::new("src").join(path)), "{path:?}");
        }
        let plain = Path::new(std::ffi::OsStr::from_bytes(b"caf\xe9.txt"));
        assert!(!credential_path(plain));
    }

    #[cfg(unix)]
    #[test]
    fn git_names_that_are_not_utf8_still_sync() {
        use std::os::unix::ffi::OsStrExt;
        let name = b"caf\xe9.txt";
        let path = git_path(name).expect("kept");
        assert_eq!(path.as_os_str().as_bytes(), name);
    }

    #[cfg(unix)]
    #[test]
    fn a_hard_link_to_a_credential_never_syncs() {
        let dir = std::env::temp_dir().join(format!("cmux-vm-run-hardlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join(".env"), "SECRET=1").unwrap();
        std::fs::hard_link(dir.join(".env"), dir.join("src/config.txt")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "fn main() {}").unwrap();
        let list = sync_list(&dir).unwrap();
        assert_eq!(list.files, vec![PathBuf::from("src/main.rs")]);
        assert_eq!(list.hard_linked, vec![PathBuf::from("src/config.txt")]);
        assert_eq!(list.credentials, vec![PathBuf::from(".env")]);
        let _ = std::fs::remove_dir_all(&dir);
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
