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

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

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
const CHUNK_RETRIES: u32 = 3;

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
            let exists = decode(&body)?["exists"]
                .as_bool()
                .ok_or_else(|| CliError::unexpected("the cmux VM API did not say whether the path exists"))?;
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
            let body = fetch_body(client.files_stat_file(id.as_str(), &path, None)).await?;
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
                    let bytes = download(client, id.as_str(), &path, &local).await?;
                    out.copied(id.as_str(), path.as_str(), &local, bytes, "read")
                }
                None if out.is_json() => Err(CliError::usage(
                    "file contents are not JSON: pass --out FILE with --json",
                )),
                None => {
                    let stream =
                        call(client.files_read_file(id.as_str(), &path, None, None)).await?;
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
            let bytes = upload(client, id.as_str(), &path, &args.local, options).await?;
            out.copied(id.as_str(), path.as_str(), &args.local, bytes, "wrote")
        }
    }
}

pub(crate) async fn copy(
    client: &Client,
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
            let bytes = upload(client, id.as_str(), &target_path, &local, options).await?;
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
            let bytes = download(client, id.as_str(), &remote, &target).await?;
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
    id: &str,
    path: &types::GuestPath,
    local: &Path,
    options: UploadOptions,
) -> Result<u64, CliError> {
    let mode = options.mode.map(|m| m.to_string());
    if local.as_os_str() == "-" {
        if options.resumable {
            return Err(CliError::usage(
                "--resumable needs a local file, not stdin",
            ));
        }
        let mut bytes = Vec::new();
        std::io::stdin()
            .lock()
            .read_to_end(&mut bytes)
            .map_err(|e| CliError::usage(format!("could not read stdin: {e}")))?;
        let length = bytes.len() as u64;
        let header = content_length(length)?;
        call(client.files_write_file(id, mode.as_deref(), path, Some(&header), None, bytes))
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
        return resumable_upload(client, id, path, file, length, options.mode).await;
    }
    let header = content_length(length)?;
    call(client.files_write_file(
        id,
        mode.as_deref(),
        path,
        Some(&header),
        None,
        file_body(file),
    ))
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
    id: &str,
    path: &types::GuestPath,
    mut file: std::fs::File,
    length: u64,
    mode: Option<u32>,
) -> Result<u64, CliError> {
    let digest = sha256_hex(&mut file)?;
    let size = i64::try_from(length).map_err(|_| CliError::usage("the file is too large"))?;
    let body: types::BeginFileUploadRequest = request_body(json!({
        "path": path.as_str(),
        "size": size,
        "sha256": digest,
        "mode": mode,
    }))?;
    let begun = fetch_body(client.files_begin_file_upload(id, None, &body)).await?;
    let begun = UploadState::parse(&begun)?;
    let upload_id = begun.upload_id.clone();
    let send = send_chunks(client, id, &upload_id, &mut file, length, begun);
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

async fn send_chunks(
    client: &Client,
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
        match fetch_body(client.files_upload_file_chunk(
            id,
            upload_id,
            &at,
            Some(&header),
            None,
            chunk,
        ))
        .await
        {
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
                retries += 1;
                let state =
                    fetch_body(client.files_get_file_upload(id, upload_id, None)).await?;
                offset = UploadState::parse(&state)?.received;
            }
            Err(error) => return Err(error),
        }
    }
    match call(client.files_commit_file_upload(id, upload_id, None)).await {
        Ok(()) => Ok(()),
        // A commit whose answer was lost may have finished: a later "upload
        // not found" then means it did.
        Err(error) if matches!(error.exit_code(), exit::NETWORK | exit::SERVICE_UNAVAILABLE) => {
            match call(client.files_get_file_upload(id, upload_id, None)).await {
                Err(gone) if gone.exit_code() == exit::NOT_FOUND => Ok(()),
                _ => call(client.files_commit_file_upload(id, upload_id, None)).await,
            }
        }
        Err(error) => Err(error),
    }
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

/// The file as a request body read a chunk at a time.
fn file_body(file: std::fs::File) -> reqwest::Body {
    let chunks = futures::stream::unfold(Some(file), |state| async move {
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
    });
    reqwest::Body::wrap_stream(chunks)
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
        assert!(UploadState::parse(br#"{"uploadId":"../x","receivedBytes":0,"maxChunkBytes":8}"#).is_err());
        assert!(UploadState::parse(br#"{"uploadId":"u","receivedBytes":0,"maxChunkBytes":0}"#).is_err());
    }

    #[test]
    fn only_transient_chunk_failures_are_resumed() {
        assert!(chunk_retryable(&CliError::network("x")));
        assert!(!chunk_retryable(&CliError::usage("x")));
        assert!(!chunk_retryable(&CliError::answered_no()));
    }

    #[test]
    fn a_download_lands_beside_its_destination_first() {
        assert_eq!(
            partial_path(Path::new("out/a.txt")),
            Path::new("out/a.txt.cmux-vm-partial")
        );
    }
}
