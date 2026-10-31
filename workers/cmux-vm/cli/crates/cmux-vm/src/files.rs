//! Guest files: `file ls|read|write|stat` (also spelled `fs`), and the
//! scp-style copies `push LOCAL VM:PATH`, `pull VM:PATH LOCAL` and
//! `scp SOURCE DESTINATION` over the same file routes.
//!
//! Uploads stream the local file with its length, so a large file is never
//! held in memory; a file over [`RESUMABLE_THRESHOLD`] (or any file with
//! `--resumable`) goes through the resumable upload routes in chunks, with its
//! sha256, resuming from the server's received byte count after a failed
//! chunk and abandoning the upload on Ctrl-C or failure. Downloads stream to
//! stdout or to a temporary file that is renamed into place only after the
//! whole body arrived.
//!
//! Transfers have no total deadline ([`TransferClients`]): a download fails
//! only when the API goes silent for longer than the read-idle timeout, an
//! upload only when its body stops moving ([`UPLOAD_IDLE`]) or the answer
//! after the last byte does not come ([`cmux_vm_client::TRANSFER_READ_IDLE`]).

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use clap::{Args, Subcommand};
use cmux_vm_client::raw::{Client, types};
use futures::StreamExt;
use serde_json::{Value, json};

use crate::error::CliError;
use crate::output::Printer;
use crate::prompt::Prompt;
use crate::{Destroy, call, confirm, exit, fetch_body, request_body};

/// Files larger than this upload in resumable chunks without `--resumable`.
pub(crate) const RESUMABLE_THRESHOLD: u64 = 64 * 1024 * 1024;
/// The largest chunk sent, below the server's own `maxChunkBytes` when that is
/// larger, so one chunk finishes well inside the request timeout.
const MAX_CHUNK: u64 = 8 * 1024 * 1024;
/// Failed chunks retried (each resuming at the server's count) before giving up.
const CHUNK_RETRIES: u32 = 5;
/// The first retry waits about this long; each later one doubles it.
const RETRY_BASE: Duration = Duration::from_millis(500);
/// No computed retry wait is longer than this.
const RETRY_CAP: Duration = Duration::from_secs(16);
/// A server asking for a longer wait than this is not retried: the CLI fails
/// with its answer instead of hanging.
const MAX_RETRY_AFTER: Duration = Duration::from_secs(60);
/// An upload whose body has not moved for this long has stalled.
pub(crate) const UPLOAD_IDLE: Duration = Duration::from_secs(120);
/// Status reads while a commit settles (each after a backoff wait), about
/// ten minutes in all with [`RETRY_CAP`].
const COMMIT_SETTLE_POLLS: u32 = 40;

/// The clients a transfer uses besides the ordinary one: `stream` (no total
/// deadline, a read-idle bound) reads files and commits uploads, `upload` (no
/// deadline; [`with_upload_progress`] bounds it) sends file bodies.
pub(crate) struct TransferClients {
    pub stream: Client,
    pub upload: Client,
}

#[derive(Subcommand, Debug)]
pub(crate) enum FileCommand {
    /// List a directory in a VM
    Ls(FilePathArgs),
    /// Print a guest file to stdout, or save it with --out
    Read(FileReadArgs),
    /// Write a local file (`-` for stdin) into a VM, replacing the guest file atomically
    Write(FileWriteArgs),
    /// Show file metadata on a running, paused, stopped or retired VM
    Stat(FilePathArgs),
    /// Create a directory and any missing parents (like mkdir -p); an existing directory is success
    Mkdir(FilePathArgs),
    /// Delete a file, or a directory together with everything in it: the API
    /// has no non-recursive form (asks to type the path, or needs --yes)
    #[command(alias = "remove")]
    Rm(FileRmArgs),
    /// Exit 0 when a guest path exists, 1 when it does not; --json prints {"exists": ...}
    Exists(FilePathArgs),
}

#[derive(Args, Debug)]
pub(crate) struct FileRmArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Absolute guest path, without parent segments
    path: String,
    /// Delete without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Args, Debug)]
pub(crate) struct FilePathArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Absolute guest path, without parent segments
    path: String,
}

#[derive(Args, Debug)]
pub(crate) struct FileReadArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Absolute guest path, without parent segments
    path: String,
    /// Save to this local file instead of printing to stdout
    #[arg(long, value_name = "FILE")]
    out: Option<PathBuf>,
}

#[derive(Args, Debug)]
pub(crate) struct FileWriteArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Absolute guest path, without parent segments
    path: String,
    /// Local file to upload; `-` reads stdin
    local: PathBuf,
    /// Permission bits in octal, such as 0644 or 755
    #[arg(long, value_name = "OCTAL", value_parser = parse_mode)]
    mode: Option<u32>,
    /// Upload in resumable chunks even below 64 MiB (larger files always do)
    #[arg(long)]
    resumable: bool,
}

#[derive(Args, Debug)]
pub(crate) struct PushArgs {
    /// Local file to upload
    local: PathBuf,
    /// Destination as VM_ID:/absolute/path; an existing guest directory (or a trailing /) takes the file under its own name
    remote: String,
    /// Permission bits in octal, such as 0644 or 755
    #[arg(long, value_name = "OCTAL", value_parser = parse_mode)]
    mode: Option<u32>,
    /// Upload in resumable chunks even below 64 MiB (larger files always do)
    #[arg(long)]
    resumable: bool,
}

#[derive(Args, Debug)]
pub(crate) struct PullArgs {
    /// Source as VM_ID:/absolute/path
    remote: String,
    /// Local destination; an existing directory takes the file under its own name
    local: PathBuf,
}

#[derive(Args, Debug)]
pub(crate) struct ScpArgs {
    /// Source: a local file, or VM_ID:/absolute/path
    source: String,
    /// Destination: a local path, or VM_ID:/absolute/path (exactly one side is a VM)
    destination: String,
    /// Permission bits in octal for an upload, such as 0644 or 755
    #[arg(long, value_name = "OCTAL", value_parser = parse_mode)]
    mode: Option<u32>,
    /// Upload in resumable chunks even below 64 MiB (larger files always do)
    #[arg(long)]
    resumable: bool,
}

/// How an upload is sent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct UploadOptions {
    pub mode: Option<u32>,
    pub resumable: bool,
}

/// One single-file copy, after deciding which side is the VM.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Transfer {
    Push {
        local: PathBuf,
        vm_id: String,
        path: String,
    },
    Pull {
        vm_id: String,
        path: String,
        local: PathBuf,
    },
}

impl Transfer {
    pub(crate) fn push(args: PushArgs) -> Result<(Transfer, UploadOptions), CliError> {
        let Some((vm_id, path)) = parse_remote(&args.remote) else {
            return Err(CliError::usage(
                "push needs a destination such as vm_…:/root/file",
            ));
        };
        Ok((
            Transfer::Push {
                local: args.local,
                vm_id,
                path,
            },
            UploadOptions {
                mode: args.mode,
                resumable: args.resumable,
            },
        ))
    }

    pub(crate) fn pull(args: PullArgs) -> Result<Transfer, CliError> {
        let Some((vm_id, path)) = parse_remote(&args.remote) else {
            return Err(CliError::usage(
                "pull needs a source such as vm_…:/root/file",
            ));
        };
        Ok(Transfer::Pull {
            vm_id,
            path,
            local: args.local,
        })
    }

    pub(crate) fn scp(args: ScpArgs) -> Result<(Transfer, UploadOptions), CliError> {
        Ok((
            plan_scp(&args.source, &args.destination)?,
            UploadOptions {
                mode: args.mode,
                resumable: args.resumable,
            },
        ))
    }
}

/// `vm_…:/path` as `(vm_id, path)`. Anything else, including a local path
/// that happens to contain a colon, is local.
pub(crate) fn parse_remote(spec: &str) -> Option<(String, String)> {
    let (vm, path) = spec.split_once(':')?;
    if !vm.starts_with("vm_") || vm.contains('/') {
        return None;
    }
    Some((vm.to_owned(), path.to_owned()))
}

/// Which way an `scp SOURCE DESTINATION` copies.
pub(crate) fn plan_scp(source: &str, destination: &str) -> Result<Transfer, CliError> {
    match (parse_remote(source), parse_remote(destination)) {
        (Some(_), Some(_)) => Err(CliError::usage(
            "only one side of scp may be a VM path; copy VM to VM through a local file",
        )),
        (None, None) => Err(CliError::usage(
            "one side of scp must be a VM path such as vm_…:/root/file",
        )),
        (None, Some((vm_id, path))) => Ok(Transfer::Push {
            local: PathBuf::from(source),
            vm_id,
            path,
        }),
        (Some((vm_id, path)), None) => Ok(Transfer::Pull {
            vm_id,
            path,
            local: PathBuf::from(destination),
        }),
    }
}

/// The guest path an upload lands at: a directory takes the file under its
/// own name, as scp does.
pub(crate) fn push_target(remote: &str, remote_is_directory: bool, local: &Path) -> String {
    let name = local
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    if remote.ends_with('/') {
        format!("{remote}{name}")
    } else if remote_is_directory {
        format!("{remote}/{name}")
    } else {
        remote.to_owned()
    }
}

/// The local path a download lands at: an existing directory takes the file
/// under the guest file's name.
pub(crate) fn pull_target(local: &Path, local_is_directory: bool, remote: &str) -> PathBuf {
    if !local_is_directory {
        return local.to_path_buf();
    }
    let name = remote
        .rsplit('/')
        .find(|segment| !segment.is_empty())
        .unwrap_or("download");
    local.join(name)
}

/// Octal permission bits, `0644`, `644` or `0o644`.
pub(crate) fn parse_mode(text: &str) -> Result<u32, String> {
    let digits = text.strip_prefix("0o").unwrap_or(text);
    match u32::from_str_radix(digits, 8) {
        Ok(mode) if mode <= 0o7777 => Ok(mode),
        _ => Err(format!("{text:?} is not octal permission bits (0000-7777)")),
    }
}

pub(crate) fn vm_id(text: &str) -> Result<types::VmId, CliError> {
    text.parse::<types::VmId>()
        .map_err(|_| CliError::usage("invalid VM id"))
}

pub(crate) fn guest_path(path: &str) -> Result<types::GuestPath, CliError> {
    if !path.starts_with('/')
        || path.contains('\0')
        || path.split('/').any(|part| part == "..")
        || path.encode_utf16().count() > 4096
    {
        return Err(CliError::usage(
            "guest path must be absolute, at most 4096 characters, without parent segments or NUL",
        ));
    }
    path.parse::<types::GuestPath>()
        .map_err(|_| CliError::usage("invalid guest path"))
}

pub(crate) async fn file(
    client: &Client,
    transfer: &TransferClients,
    command: FileCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        FileCommand::Mkdir(args) => {
            let id = vm_id(&args.vm_id)?;
            let path = guest_path(&args.path)?;
            let body: types::MakeDirectoryRequest = request_body(json!({ "path": path.as_str() }))?;
            call(client.files_make_directory(id.as_str(), None, &body)).await?;
            if out.is_json() {
                return out.json_value(
                    &json!({ "vmId": id.as_str(), "path": path.as_str(), "created": true }),
                );
            }
            out.line(&format!(
                "created directory {}:{}",
                id.as_str(),
                path.as_str().escape_debug()
            ))
        }
        FileCommand::Rm(args) => {
            let id = vm_id(&args.vm_id)?;
            let path = guest_path(&args.path)?;
            if !args.yes {
                confirm(prompt, Destroy::RemovePath, path.as_str())?;
            }
            call(client.files_remove_path(id.as_str(), &path, None)).await?;
            if out.is_json() {
                return out.json_value(
                    &json!({ "vmId": id.as_str(), "path": path.as_str(), "removed": true }),
                );
            }
            out.line(&format!(
                "removed {}:{}",
                id.as_str(),
                path.as_str().escape_debug()
            ))
        }
        FileCommand::Exists(args) => {
            let id = vm_id(&args.vm_id)?;
            let path = guest_path(&args.path)?;
            let body = fetch_body(client.files_path_exists(id.as_str(), &path, None)).await?;
            let exists = decode(&body)?["exists"].as_bool().ok_or_else(|| {
                CliError::unexpected("the cmux VM API did not say whether the path exists")
            })?;
            if out.is_json() {
                out.raw_json(&body)?;
            } else {
                out.line(if exists { "exists" } else { "does not exist" })?;
            }
            if exists {
                Ok(())
            } else {
                Err(CliError::answered_no())
            }
        }
        FileCommand::Stat(args) => {
            let id = vm_id(&args.vm_id)?;
            let path = guest_path(&args.path)?;
            let body = fetch_body(client.files_stat_file(id.as_str(), &path, None))
                .await
                .map_err(|e| e.for_vm(id.as_str(), "file stat"))?;
            out.file_stat(&body)
        }
        FileCommand::Ls(args) => {
            let id = vm_id(&args.vm_id)?;
            let path = guest_path(&args.path)?;
            let body = fetch_body(client.files_list_files(id.as_str(), &path, None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let list: Value = decode(&body)?;
            let entries = list["entries"].as_array().cloned().unwrap_or_default();
            if entries.is_empty() {
                return out.line("empty directory");
            }
            for entry in entries {
                let kind = entry["kind"].as_str().unwrap_or("unknown");
                let name = entry["name"].as_str().unwrap_or("");
                let suffix = if kind == "directory" { "/" } else { "" };
                out.line(&format!("{:<10} {}{suffix}", kind, name.escape_debug()))?;
            }
            Ok(())
        }
        FileCommand::Read(args) => {
            let id = vm_id(&args.vm_id)?;
            let path = guest_path(&args.path)?;
            match args.out {
                Some(local) => {
                    let bytes = download(&transfer.stream, id.as_str(), &path, &local).await?;
                    out.copied(id.as_str(), path.as_str(), &local, bytes, "read")
                }
                None if out.is_json() => Err(CliError::usage(
                    "file contents are not JSON: pass --out FILE with --json",
                )),
                None => {
                    let stream = call(transfer.stream.files_read_file(
                        id.as_str(),
                        &path,
                        None,
                        None,
                    ))
                    .await?;
                    let mut stream = stream.into_inner();
                    while let Some(chunk) = stream.next().await {
                        let chunk = chunk.map_err(cut_off)?;
                        out.bytes(&chunk)?;
                    }
                    Ok(())
                }
            }
        }
        FileCommand::Write(args) => {
            let id = vm_id(&args.vm_id)?;
            let path = guest_path(&args.path)?;
            let options = UploadOptions {
                mode: args.mode,
                resumable: args.resumable,
            };
            let bytes = upload(client, transfer, id.as_str(), &path, &args.local, options).await?;
            out.copied(id.as_str(), path.as_str(), &args.local, bytes, "wrote")
        }
    }
}

pub(crate) async fn copy(
    client: &Client,
    transfer: &TransferClients,
    copy: Transfer,
    options: UploadOptions,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match copy {
        Transfer::Push {
            local,
            vm_id: vm,
            path,
        } => {
            let id = vm_id(&vm)?;
            // The final target is validated below; a stat first needs a valid path too.
            let is_directory =
                !path.ends_with('/') && remote_is_directory(client, &id, &path).await?;
            let target = push_target(&path, is_directory, &local);
            let target_path = guest_path(&target)?;
            let bytes =
                upload(client, transfer, id.as_str(), &target_path, &local, options).await?;
            out.copied(id.as_str(), target_path.as_str(), &local, bytes, "pushed")
        }
        Transfer::Pull {
            vm_id: vm,
            path,
            local,
        } => {
            if options.mode.is_some() || options.resumable {
                return Err(CliError::usage(
                    "--mode and --resumable apply to uploads only",
                ));
            }
            let id = vm_id(&vm)?;
            let remote = guest_path(&path)?;
            let target = pull_target(&local, local.is_dir(), &path);
            let bytes = download(&transfer.stream, id.as_str(), &remote, &target).await?;
            out.copied(id.as_str(), remote.as_str(), &target, bytes, "pulled")
        }
    }
}

/// Whether a guest path is a directory; a path that is not there is not one.
async fn remote_is_directory(
    client: &Client,
    id: &types::VmId,
    path: &str,
) -> Result<bool, CliError> {
    let path = guest_path(path)?;
    match fetch_body(client.files_stat_file(id.as_str(), &path, None)).await {
        Ok(body) => {
            let stat: Value = decode(&body)?;
            Ok(stat["kind"].as_str() == Some("directory"))
        }
        Err(error) if error.exit_code() == exit::NOT_FOUND => Ok(false),
        Err(error) => Err(error),
    }
}

async fn upload(
    client: &Client,
    transfer: &TransferClients,
    id: &str,
    path: &types::GuestPath,
    local: &Path,
    options: UploadOptions,
) -> Result<u64, CliError> {
    let mode = options.mode.map(|m| m.to_string());
    if local.as_os_str() == "-" {
        if options.resumable {
            return Err(CliError::usage("--resumable needs a local file, not stdin"));
        }
        let mut bytes = Vec::new();
        std::io::stdin()
            .lock()
            .read_to_end(&mut bytes)
            .map_err(|e| CliError::usage(format!("could not read stdin: {e}")))?;
        let length = bytes.len() as u64;
        let header = content_length(length)?;
        let progress = Progress::new(length);
        let body = progress.body(bytes_chunks(bytes));
        with_upload_progress(
            call(transfer.upload.files_write_file(
                id,
                mode.as_deref(),
                path,
                Some(&header),
                None,
                body,
            )),
            &progress,
            UPLOAD_IDLE,
            cmux_vm_client::TRANSFER_READ_IDLE,
        )
        .await?;
        return Ok(length);
    }
    let file = std::fs::File::open(local)
        .map_err(|e| CliError::usage(format!("could not open {}: {e}", local.display())))?;
    let metadata = file
        .metadata()
        .map_err(|e| CliError::usage(format!("could not read {}: {e}", local.display())))?;
    if metadata.is_dir() {
        return Err(CliError::usage(format!(
            "{} is a directory; this copies one file at a time",
            local.display()
        )));
    }
    let length = metadata.len();
    if options.resumable || length > RESUMABLE_THRESHOLD {
        return resumable_upload(client, transfer, id, path, file, length, options.mode).await;
    }
    let header = content_length(length)?;
    let progress = Progress::new(length);
    let body = progress.body(file_chunks(file));
    with_upload_progress(
        call(transfer.upload.files_write_file(
            id,
            mode.as_deref(),
            path,
            Some(&header),
            None,
            body,
        )),
        &progress,
        UPLOAD_IDLE,
        cmux_vm_client::TRANSFER_READ_IDLE,
    )
    .await?;
    Ok(length)
}

fn content_length(length: u64) -> Result<types::FilesWriteFileContentLength, CliError> {
    length
        .to_string()
        .parse()
        .map_err(|_| CliError::usage("invalid upload length"))
}

/// Uploads `file` through the resumable routes: begin with its size and
/// sha256, send chunks in order, resume at the server's `receivedBytes` after
/// a failed chunk, then commit. The upload is abandoned on Ctrl-C or on any
/// failure, so no stored chunks are left behind.
async fn resumable_upload(
    client: &Client,
    transfer: &TransferClients,
    id: &str,
    path: &types::GuestPath,
    mut file: std::fs::File,
    length: u64,
    mode: Option<u32>,
) -> Result<u64, CliError> {
    let digest = sha256_hex(&mut file)?;
    let size = i64::try_from(length).map_err(|_| CliError::usage("the file is too large"))?;
    // Before begin: a commit of this upload cannot have happened earlier.
    let begun_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX));
    let expected = Uploaded {
        length,
        sha256: digest.clone(),
        begun_at,
    };
    let body: types::BeginFileUploadRequest = request_body(json!({
        "path": path.as_str(),
        "size": size,
        "sha256": digest,
        "mode": mode,
    }))?;
    let begun = fetch_body(client.files_begin_file_upload(id, None, &body)).await?;
    let begun = UploadState::parse(&begun)?;
    let upload_id = begun.upload_id.clone();
    let send = async {
        send_chunks(client, transfer, id, &upload_id, &mut file, length, begun).await?;
        commit_upload(client, &transfer.stream, id, path, &upload_id, &expected).await
    };
    let result = tokio::select! {
        result = send => result,
        _ = tokio::signal::ctrl_c() => Err(CliError::cancelled(
            "upload interrupted; the partial upload was abandoned",
        )),
    };
    match result {
        Ok(()) => Ok(length),
        Err(error) => {
            // Best effort: an upload the server already committed or expired is gone anyway.
            let _ = call(client.files_abort_file_upload(id, &upload_id, None)).await;
            Err(error)
        }
    }
}

/// A resumable upload's progress as the server reports it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct UploadState {
    pub upload_id: String,
    pub received: u64,
    pub max_chunk: u64,
}

impl UploadState {
    pub(crate) fn parse(body: &[u8]) -> Result<Self, CliError> {
        let value = decode(body)?;
        let upload_id = value["uploadId"].as_str().map(str::to_owned);
        let received = value["receivedBytes"].as_u64();
        let max_chunk = value["maxChunkBytes"].as_u64();
        match (upload_id, received, max_chunk) {
            (Some(upload_id), Some(received), Some(max_chunk))
                if max_chunk > 0
                    && !upload_id.is_empty()
                    && upload_id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') =>
            {
                Ok(Self {
                    upload_id,
                    received,
                    max_chunk,
                })
            }
            _ => Err(CliError::unexpected(
                "the cmux VM API sent an unreadable upload state",
            )),
        }
    }
}

/// Whether a failed chunk is worth resuming: the connection, a conflict
/// (a gap after a lost answer), or a temporary server state.
pub(crate) fn chunk_retryable(error: &CliError) -> bool {
    matches!(
        error.exit_code(),
        exit::NETWORK | exit::CONFLICT | exit::SERVICE_UNAVAILABLE | exit::QUOTA_EXCEEDED
    )
}

/// The wait before retry number `attempt` (0 for the first): exponential from
/// [`RETRY_BASE`] up to [`RETRY_CAP`], with jitter (`jitter` in 0..1 picks a
/// point in the upper half, so clients that failed together spread out). A
/// server's `retry_after` is a floor; `None` when it asks for longer than
/// [`MAX_RETRY_AFTER`], which is not worth waiting for here.
pub(crate) fn retry_delay(
    attempt: u32,
    retry_after: Option<Duration>,
    jitter: f64,
) -> Option<Duration> {
    if retry_after.is_some_and(|wait| wait > MAX_RETRY_AFTER) {
        return None;
    }
    let ceiling = RETRY_BASE
        .saturating_mul(1_u32.checked_shl(attempt.min(16)).unwrap_or(u32::MAX))
        .min(RETRY_CAP);
    let jitter = jitter.clamp(0.0, 1.0);
    let backoff = ceiling.mul_f64(0.5 + 0.5 * jitter);
    Some(retry_after.map_or(backoff, |wait| wait.max(backoff)))
}

/// A number in 0..1 that differs between calls and processes, for jitter. Not
/// a secret, so the standard library's randomly keyed hasher is enough.
fn jitter() -> f64 {
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos()),
    );
    (hasher.finish() >> 11) as f64 / (1_u64 << 53) as f64
}

/// Waits before retry `attempt` after `error`; `Err(error)` when the server
/// asked for a wait too long to make here.
async fn back_off(attempt: u32, error: CliError) -> Result<(), CliError> {
    match retry_delay(attempt, error.retry_after(), jitter()) {
        Some(wait) => {
            tokio::time::sleep(wait).await;
            Ok(())
        }
        None => Err(error),
    }
}

async fn send_chunks(
    client: &Client,
    transfer: &TransferClients,
    id: &str,
    upload_id: &str,
    file: &mut std::fs::File,
    length: u64,
    begun: UploadState,
) -> Result<(), CliError> {
    use std::io::Seek;
    let chunk_limit = begun.max_chunk.min(MAX_CHUNK);
    let mut offset = begun.received;
    let mut retries = 0;
    while offset < length {
        let size = chunk_limit.min(length - offset);
        file.seek(std::io::SeekFrom::Start(offset))
            .map_err(|e| CliError::unexpected(format!("could not read the local file: {e}")))?;
        let mut chunk = vec![0_u8; usize::try_from(size).unwrap_or(usize::MAX)];
        file.read_exact(&mut chunk)
            .map_err(|e| CliError::unexpected(format!("could not read the local file: {e}")))?;
        let header: types::FilesUploadFileChunkContentLength = size
            .to_string()
            .parse()
            .map_err(|_| CliError::usage("invalid chunk length"))?;
        let at = offset.to_string();
        let progress = Progress::new(size);
        let body = progress.body(bytes_chunks(chunk));
        let sent = with_upload_progress(
            fetch_body(transfer.upload.files_upload_file_chunk(
                id,
                upload_id,
                &at,
                Some(&header),
                None,
                body,
            )),
            &progress,
            UPLOAD_IDLE,
            cmux_vm_client::TRANSFER_READ_IDLE,
        )
        .await;
        match sent {
            Ok(body) => {
                let state = UploadState::parse(&body)?;
                if state.received <= offset {
                    return Err(CliError::unexpected(
                        "the cmux VM API did not accept the chunk",
                    ));
                }
                offset = state.received;
                retries = 0;
            }
            Err(error) if chunk_retryable(&error) && retries < CHUNK_RETRIES => {
                back_off(retries, error).await?;
                retries += 1;
                let state = fetch_body(client.files_get_file_upload(id, upload_id, None)).await?;
                offset = UploadState::parse(&state)?.received;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

/// Commits a fully sent upload. A commit can outlast its answer: a lost
/// answer (a network error or 503) or 409 "a commit is already running" is
/// followed by status reads with backoff until the commit settles. While the
/// upload is still there the commit is sent again (409 again while one runs;
/// 400 if bytes are missing, which fails). "Upload not found" means the commit
/// finished, or that the upload expired or was lost, so the target is checked
/// with [`verify_committed`] before that counts as success.
async fn commit_upload(
    client: &Client,
    stream: &Client,
    id: &str,
    path: &types::GuestPath,
    upload_id: &str,
    expected: &Uploaded,
) -> Result<(), CliError> {
    let mut polls = 0;
    loop {
        let error = match call(stream.files_commit_file_upload(id, upload_id, None)).await {
            Ok(()) => return Ok(()),
            Err(error)
                if matches!(
                    error.exit_code(),
                    exit::NETWORK
                        | exit::SERVICE_UNAVAILABLE
                        | exit::CONFLICT
                        | exit::QUOTA_EXCEEDED
                ) && polls < COMMIT_SETTLE_POLLS =>
            {
                error
            }
            Err(error) => return Err(error),
        };
        // Read the status until it answers: still there (send the commit
        // again) or gone (check the target).
        let mut error = error;
        loop {
            back_off(polls, error).await?;
            polls += 1;
            match call(client.files_get_file_upload(id, upload_id, None)).await {
                Ok(_) => break,
                Err(gone) if gone.exit_code() == exit::NOT_FOUND => {
                    return verify_committed(client, stream, id, path, expected).await;
                }
                Err(other)
                    if matches!(
                        other.exit_code(),
                        exit::NETWORK | exit::SERVICE_UNAVAILABLE | exit::QUOTA_EXCEEDED
                    ) && polls < COMMIT_SETTLE_POLLS =>
                {
                    error = other;
                }
                Err(other) => return Err(other),
            }
        }
    }
}

/// What a resumable upload sent, to recognise its commit afterwards.
pub(crate) struct Uploaded {
    pub(crate) length: u64,
    /// Lowercase hex SHA-256 of the whole file.
    pub(crate) sha256: String,
    /// Local clock, epoch seconds, taken before the upload began.
    pub(crate) begun_at: i64,
}

/// How far the VM's clock may run behind this machine's when a commit is
/// recognised by its modification time.
pub(crate) const COMMIT_MTIME_SKEW_SECS: i64 = 120;

/// Without a modification time, the largest target read back to compare its
/// SHA-256 with the upload's.
pub(crate) const COMMIT_READBACK_LIMIT: u64 = 64 * 1024 * 1024;

/// What a stat of the target says about a commit whose answer was lost.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum CommitEvidence {
    /// A regular file of the uploaded size, modified after the upload began.
    Committed,
    /// Missing, another kind or size, or not modified since before the upload
    /// began: an older file, so the upload expired or was lost.
    Lost,
    /// The right size but no modification time: compare the content.
    ReadBack,
    /// The right size, no modification time, and too large to read back.
    Unconfirmed,
}

/// Judges a stat of the target. Size alone cannot tell the upload from an
/// older file of the same size, so the modification time must postdate the
/// upload's begin (less [`COMMIT_MTIME_SKEW_SECS`]); without one, the content
/// decides.
pub(crate) fn commit_evidence(stat: &Value, expected: &Uploaded) -> CommitEvidence {
    if !committed_stat_matches(stat, expected.length) {
        return CommitEvidence::Lost;
    }
    match stat["mtime"].as_i64() {
        Some(mtime) if mtime >= expected.begun_at.saturating_sub(COMMIT_MTIME_SKEW_SECS) => {
            CommitEvidence::Committed
        }
        Some(_) => CommitEvidence::Lost,
        None if expected.length <= COMMIT_READBACK_LIMIT => CommitEvidence::ReadBack,
        None => CommitEvidence::Unconfirmed,
    }
}

/// After "upload not found" following a commit whose answer was lost: the
/// commit finished only if the target is now the uploaded file (the server
/// renames the whole verified file into place, never a partial one): a
/// regular file of exactly the uploaded size, modified after the upload began
/// or, when the VM reports no modification time, with the uploaded SHA-256. A
/// missing or different file means the upload expired or was lost before the
/// commit ran; a large file without a modification time cannot be confirmed.
async fn verify_committed(
    client: &Client,
    stream: &Client,
    id: &str,
    path: &types::GuestPath,
    expected: &Uploaded,
) -> Result<(), CliError> {
    let shown = path.as_str().escape_debug().to_string();
    let lost = || {
        CliError::unexpected(format!(
            "the upload to {shown} ended without a confirmed commit (it expired or was lost) and the file there is not the uploaded one; upload it again"
        ))
    };
    let stat = match fetch_body(client.files_stat_file(id, path, None)).await {
        Ok(body) => decode(&body)?,
        Err(error) if error.exit_code() == exit::NOT_FOUND => return Err(lost()),
        Err(error) => return Err(error),
    };
    match commit_evidence(&stat, expected) {
        CommitEvidence::Committed => Ok(()),
        CommitEvidence::Lost => Err(lost()),
        CommitEvidence::Unconfirmed => Err(CliError::unexpected(format!(
            "the upload to {shown} ended without a confirmed commit and the VM reports no modification time, so the file there could not be confirmed as the uploaded one; upload it again"
        ))),
        CommitEvidence::ReadBack => {
            let body = match call(stream.files_read_file(id, path, None, None)).await {
                Ok(body) => body,
                Err(error) if error.exit_code() == exit::NOT_FOUND => return Err(lost()),
                Err(error) => return Err(error),
            };
            let mut body = body.into_inner();
            let mut context = ring::digest::Context::new(&ring::digest::SHA256);
            let mut read = 0_u64;
            while let Some(chunk) = body.next().await {
                let chunk = chunk.map_err(cut_off)?;
                read += chunk.len() as u64;
                if read > expected.length {
                    return Err(lost());
                }
                context.update(&chunk);
            }
            let digest: String = context
                .finish()
                .as_ref()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            if read == expected.length && digest == expected.sha256 {
                Ok(())
            } else {
                Err(lost())
            }
        }
    }
}

/// Whether a file stat shows the committed upload's shape: a regular file of
/// exactly `length` bytes (necessary, not sufficient: see [`commit_evidence`]).
pub(crate) fn committed_stat_matches(stat: &Value, length: u64) -> bool {
    stat["kind"].as_str() == Some("file") && stat["size"].as_u64() == Some(length)
}

/// The lowercase hex SHA-256 of a whole file, read from the start; the file is
/// left at its end.
pub(crate) fn sha256_hex(file: &mut impl Read) -> Result<String, CliError> {
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = vec![0_u8; 256 * 1024];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => context.update(&buffer[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                return Err(CliError::unexpected(format!(
                    "could not read the local file: {e}"
                )));
            }
        }
    }
    Ok(context
        .finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// The file read a chunk at a time.
fn file_chunks(
    file: std::fs::File,
) -> impl futures::Stream<Item = Result<Vec<u8>, std::io::Error>> + Send + 'static {
    futures::stream::unfold(Some(file), |state| async move {
        let mut file = state?;
        let mut buffer = vec![0_u8; 256 * 1024];
        loop {
            match file.read(&mut buffer) {
                Ok(0) => return None,
                Ok(n) => {
                    buffer.truncate(n);
                    return Some((Ok::<Vec<u8>, std::io::Error>(buffer), Some(file)));
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Some((Err(e), None)),
            }
        }
    })
}

/// Bytes already in memory, in pieces small enough to show progress.
fn bytes_chunks(
    bytes: Vec<u8>,
) -> impl futures::Stream<Item = Result<Vec<u8>, std::io::Error>> + Send + 'static {
    let pieces: Vec<Result<Vec<u8>, std::io::Error>> = bytes
        .chunks(256 * 1024)
        .map(|piece| Ok(piece.to_vec()))
        .collect();
    futures::stream::iter(pieces)
}

/// How far an upload body has got: when it last moved, and whether all of it
/// has been handed to the connection.
#[derive(Clone)]
pub(crate) struct Progress {
    state: Arc<Mutex<ProgressState>>,
}

struct ProgressState {
    last: tokio::time::Instant,
    sent: u64,
    length: u64,
}

impl Progress {
    pub(crate) fn new(length: u64) -> Self {
        Self {
            state: Arc::new(Mutex::new(ProgressState {
                last: tokio::time::Instant::now(),
                sent: 0,
                length,
            })),
        }
    }

    /// Notes `bytes` more handed to the connection.
    pub(crate) fn advance(&self, bytes: u64) {
        if let Ok(mut state) = self.state.lock() {
            state.last = tokio::time::Instant::now();
            state.sent = state.sent.saturating_add(bytes);
        }
    }

    /// Whether the whole body has been handed to the connection.
    fn finished(&self) -> bool {
        match self.state.lock() {
            Ok(state) => state.sent >= state.length,
            Err(_) => true,
        }
    }

    /// When the upload counts as stalled if nothing changes: `idle` after the
    /// body last moved, or `answer` after its last byte.
    fn deadline(&self, idle: Duration, answer: Duration) -> tokio::time::Instant {
        match self.state.lock() {
            Ok(state) if state.sent >= state.length => state.last + answer,
            Ok(state) => state.last + idle,
            Err(_) => tokio::time::Instant::now(),
        }
    }

    /// `chunks` as a request body that records its progress here.
    fn body<S>(&self, chunks: S) -> reqwest::Body
    where
        S: futures::Stream<Item = Result<Vec<u8>, std::io::Error>> + Send + 'static,
    {
        let progress = self.clone();
        reqwest::Body::wrap_stream(chunks.map(move |item| {
            if let Ok(piece) = &item {
                progress.advance(piece.len() as u64);
            }
            item
        }))
    }
}

/// Runs an upload request with no total deadline, failing it only when its
/// body stops moving for `idle`, or when no answer comes within `answer`
/// after the last byte went out.
pub(crate) async fn with_upload_progress<T>(
    request: impl std::future::Future<Output = Result<T, CliError>>,
    progress: &Progress,
    idle: Duration,
    answer: Duration,
) -> Result<T, CliError> {
    tokio::pin!(request);
    loop {
        let deadline = progress.deadline(idle, answer);
        tokio::select! {
            result = &mut request => return result,
            () = tokio::time::sleep_until(deadline) => {
                if progress.deadline(idle, answer) <= tokio::time::Instant::now() {
                    return Err(CliError::network(if progress.finished() {
                        format!(
                            "the cmux VM API did not answer within {} s of the upload's last byte",
                            answer.as_secs()
                        )
                    } else {
                        format!("the upload stalled: nothing was sent for {} s", idle.as_secs())
                    }));
                }
            }
        }
    }
}

/// Streams a guest file into `local` through a temporary sibling that is
/// renamed into place once the whole body arrived.
async fn download(
    client: &Client,
    id: &str,
    path: &types::GuestPath,
    local: &Path,
) -> Result<u64, CliError> {
    let partial = partial_path(local);
    let mut file = std::fs::File::create(&partial)
        .map_err(|e| CliError::usage(format!("could not create {}: {e}", partial.display())))?;
    let result = async {
        let stream = call(client.files_read_file(id, path, None, None)).await?;
        let mut stream = stream.into_inner();
        let mut written = 0_u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(cut_off)?;
            file.write_all(&chunk).map_err(|e| {
                CliError::unexpected(format!("could not write {}: {e}", local.display()))
            })?;
            written += chunk.len() as u64;
        }
        file.flush().map_err(|e| {
            CliError::unexpected(format!("could not write {}: {e}", local.display()))
        })?;
        Ok::<u64, CliError>(written)
    }
    .await;
    match result {
        Ok(written) => {
            std::fs::rename(&partial, local).map_err(|e| {
                let _ = std::fs::remove_file(&partial);
                CliError::unexpected(format!(
                    "could not move the download to {}: {e}",
                    local.display()
                ))
            })?;
            Ok(written)
        }
        Err(error) => {
            let _ = std::fs::remove_file(&partial);
            Err(error)
        }
    }
}

pub(crate) fn partial_path(local: &Path) -> PathBuf {
    let mut name = local
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_else(|| "download".into());
    name.push(".cmux-vm-partial");
    local.with_file_name(name)
}

fn cut_off(error: impl std::fmt::Display) -> CliError {
    CliError::network(format!(
        "the response from the cmux VM API was cut off: {error}"
    ))
}

fn decode(body: &[u8]) -> Result<Value, CliError> {
    serde_json::from_slice(body).map_err(|e| {
        CliError::unexpected(format!(
            "the cmux VM API sent a response this CLI cannot read: {e}"
        ))
    })
}

impl Printer<'_> {
    /// One finished copy: JSON names both ends and the size.
    pub(crate) fn copied(
        &mut self,
        vm_id: &str,
        path: &str,
        local: &Path,
        bytes: u64,
        verb: &str,
    ) -> Result<(), CliError> {
        if self.is_json() {
            return self.json_value(&json!({
                "vmId": vm_id,
                "path": path,
                "local": local.display().to_string(),
                "bytes": bytes,
            }));
        }
        let (from, to) = if verb == "pulled" || verb == "read" {
            (format!("{vm_id}:{path}"), local.display().to_string())
        } else {
            (local.display().to_string(), format!("{vm_id}:{path}"))
        };
        self.line(&format!("{verb} {bytes} bytes {from} -> {to}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_vm_side_is_a_vm_id_before_the_colon() {
        assert_eq!(
            parse_remote("vm_abc:/root/a.txt"),
            Some(("vm_abc".to_owned(), "/root/a.txt".to_owned()))
        );
        assert_eq!(parse_remote("./notes:draft"), None);
        assert_eq!(parse_remote("C:/x"), None);
        assert_eq!(parse_remote("plain.txt"), None);
        assert_eq!(parse_remote("dir/vm_a:/x"), None);
    }

    #[test]
    fn scp_picks_the_direction_and_refuses_two_or_zero_vm_sides() {
        assert_eq!(
            plan_scp("a.txt", "vm_1:/root/").unwrap(),
            Transfer::Push {
                local: "a.txt".into(),
                vm_id: "vm_1".into(),
                path: "/root/".into()
            }
        );
        assert_eq!(
            plan_scp("vm_1:/etc/hosts", ".").unwrap(),
            Transfer::Pull {
                vm_id: "vm_1".into(),
                path: "/etc/hosts".into(),
                local: ".".into()
            }
        );
        assert_eq!(
            plan_scp("vm_1:/a", "vm_2:/b").unwrap_err().exit_code(),
            exit::USAGE
        );
        assert_eq!(plan_scp("a", "b").unwrap_err().exit_code(), exit::USAGE);
    }

    #[test]
    fn a_directory_destination_takes_the_source_name() {
        let local = Path::new("build/app.tar");
        assert_eq!(push_target("/srv/", false, local), "/srv/app.tar");
        assert_eq!(push_target("/srv", true, local), "/srv/app.tar");
        assert_eq!(push_target("/srv/new.tar", false, local), "/srv/new.tar");
        assert_eq!(
            pull_target(Path::new("out"), true, "/var/log/syslog"),
            Path::new("out/syslog")
        );
        assert_eq!(
            pull_target(Path::new("copy.log"), false, "/var/log/syslog"),
            Path::new("copy.log")
        );
    }

    #[test]
    fn modes_are_octal_and_bounded() {
        assert_eq!(parse_mode("0644"), Ok(0o644));
        assert_eq!(parse_mode("755"), Ok(0o755));
        assert_eq!(parse_mode("0o4755"), Ok(0o4755));
        assert!(parse_mode("0999").is_err());
        assert!(parse_mode("17777").is_err());
    }

    #[test]
    fn guest_paths_must_be_absolute_without_parent_segments() {
        assert!(guest_path("/root/a").is_ok());
        assert!(guest_path("root/a").is_err());
        assert!(guest_path("/root/../etc").is_err());
    }

    #[test]
    fn sha256_is_lowercase_hex_of_the_whole_input() {
        assert_eq!(
            sha256_hex(&mut &b"abc"[..]).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(&mut &b""[..]).unwrap(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn an_upload_state_needs_its_id_progress_and_chunk_size() {
        let state = UploadState::parse(
            br#"{"uploadId":"up_1","path":"/a","size":10,"receivedBytes":4,"maxChunkBytes":8}"#,
        )
        .unwrap();
        assert_eq!(
            state,
            UploadState {
                upload_id: "up_1".into(),
                received: 4,
                max_chunk: 8
            }
        );
        assert!(
            UploadState::parse(br#"{"uploadId":"../x","receivedBytes":0,"maxChunkBytes":8}"#)
                .is_err()
        );
        assert!(
            UploadState::parse(br#"{"uploadId":"u","receivedBytes":0,"maxChunkBytes":0}"#).is_err()
        );
    }

    #[test]
    fn only_transient_chunk_failures_are_resumed() {
        assert!(chunk_retryable(&CliError::network("x")));
        assert!(!chunk_retryable(&CliError::usage("x")));
        assert!(!chunk_retryable(&CliError::answered_no()));
    }

    #[test]
    fn retries_back_off_exponentially_with_jitter_and_honor_retry_after() {
        let at = |attempt, jitter| retry_delay(attempt, None, jitter).unwrap();
        assert_eq!(at(0, 0.0), Duration::from_millis(250));
        assert_eq!(at(0, 1.0), Duration::from_millis(500));
        assert_eq!(at(1, 1.0), Duration::from_secs(1));
        assert_eq!(at(3, 1.0), Duration::from_secs(4));
        // Capped, however many attempts.
        assert_eq!(at(30, 1.0), RETRY_CAP);
        assert!(at(2, 0.3) > at(2, 0.0) && at(2, 0.3) < at(2, 1.0));
        // A server's wait is a floor, and a very long one is not waited for.
        assert_eq!(
            retry_delay(0, Some(Duration::from_secs(5)), 1.0),
            Some(Duration::from_secs(5))
        );
        assert_eq!(retry_delay(0, Some(Duration::from_secs(61)), 1.0), None);
        let jittered = jitter();
        assert!((0.0..1.0).contains(&jittered));
    }

    #[test]
    fn a_same_size_file_counts_as_the_commit_only_when_modified_after_the_upload_began() {
        let expected = Uploaded {
            length: 10,
            sha256: "00".repeat(32),
            begun_at: 1_800_000_000,
        };
        let stat = |size: u64, mtime: Value| json!({"kind": "file", "size": size, "mtime": mtime});
        assert_eq!(
            commit_evidence(&stat(10, json!(1_800_000_005)), &expected),
            CommitEvidence::Committed
        );
        // A VM clock a little behind this machine's still counts.
        assert_eq!(
            commit_evidence(
                &stat(10, json!(1_800_000_000 - COMMIT_MTIME_SKEW_SECS)),
                &expected
            ),
            CommitEvidence::Committed
        );
        // An older file of the same size is not the upload.
        assert_eq!(
            commit_evidence(
                &stat(10, json!(1_800_000_000 - COMMIT_MTIME_SKEW_SECS - 1)),
                &expected
            ),
            CommitEvidence::Lost
        );
        assert_eq!(
            commit_evidence(&stat(9, json!(1_800_000_005)), &expected),
            CommitEvidence::Lost
        );
        // No modification time: the content decides, up to the read-back bound.
        assert_eq!(
            commit_evidence(&stat(10, Value::Null), &expected),
            CommitEvidence::ReadBack
        );
        let large = Uploaded {
            length: COMMIT_READBACK_LIMIT + 1,
            ..expected
        };
        assert_eq!(
            commit_evidence(&stat(COMMIT_READBACK_LIMIT + 1, Value::Null), &large),
            CommitEvidence::Unconfirmed
        );
        assert_eq!(
            commit_evidence(
                &stat(COMMIT_READBACK_LIMIT + 1, json!(1_800_000_005)),
                &large
            ),
            CommitEvidence::Committed
        );
    }

    #[test]
    fn a_commit_counts_only_with_the_uploaded_file_in_place() {
        assert!(committed_stat_matches(
            &json!({"kind": "file", "size": 10}),
            10
        ));
        assert!(!committed_stat_matches(
            &json!({"kind": "file", "size": 9}),
            10
        ));
        assert!(!committed_stat_matches(
            &json!({"kind": "directory", "size": 10}),
            10
        ));
    }

    #[tokio::test]
    async fn an_upload_fails_only_when_its_body_stops_moving() {
        let idle = Duration::from_millis(150);
        let answer = Duration::from_millis(150);
        // Moving steadily for longer than `idle` in all: not stalled.
        let progress = Progress::new(10);
        let moving = progress.clone();
        let steady = async move {
            for _ in 0..10 {
                tokio::time::sleep(Duration::from_millis(50)).await;
                moving.advance(1);
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
            Ok::<_, CliError>(())
        };
        assert!(
            with_upload_progress(steady, &progress, idle, answer)
                .await
                .is_ok()
        );
        // Nothing sent: stalled after `idle`.
        let progress = Progress::new(10);
        let stuck = std::future::pending::<Result<(), CliError>>();
        let error = with_upload_progress(stuck, &progress, idle, answer)
            .await
            .unwrap_err();
        assert_eq!(error.exit_code(), exit::NETWORK);
        // Everything sent but no answer: fails after `answer`.
        let progress = Progress::new(4);
        progress.advance(4);
        let silent = std::future::pending::<Result<(), CliError>>();
        let error = with_upload_progress(silent, &progress, idle, answer)
            .await
            .unwrap_err();
        assert_eq!(error.exit_code(), exit::NETWORK);
    }

    #[test]
    fn a_download_lands_beside_its_destination_first() {
        assert_eq!(
            partial_path(Path::new("out/a.txt")),
            Path::new("out/a.txt.cmux-vm-partial")
        );
    }
}
