//! Guest files: `file ls|read|write|stat` (also spelled `fs`), and the
//! scp-style copies `push LOCAL VM:PATH`, `pull VM:PATH LOCAL` and
//! `scp SOURCE DESTINATION` over the same file routes.
//!
//! Uploads stream the local file with its length, so a large file is never
//! held in memory; downloads stream to stdout or to a temporary file that is
//! renamed into place only after the whole body arrived.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use cmux_vm_client::raw::{Client, types};
use futures::StreamExt;
use serde_json::{Value, json};

use crate::error::CliError;
use crate::output::Printer;
use crate::{call, exit, fetch_body};

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
    pub(crate) fn push(args: PushArgs) -> Result<(Transfer, Option<u32>), CliError> {
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
            args.mode,
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

    pub(crate) fn scp(args: ScpArgs) -> Result<(Transfer, Option<u32>), CliError> {
        Ok((plan_scp(&args.source, &args.destination)?, args.mode))
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
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
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
            let bytes = upload(client, id.as_str(), &path, &args.local, args.mode).await?;
            out.copied(id.as_str(), path.as_str(), &args.local, bytes, "wrote")
        }
    }
}

pub(crate) async fn copy(
    client: &Client,
    copy: Transfer,
    mode: Option<u32>,
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
            let bytes = upload(client, id.as_str(), &target_path, &local, mode).await?;
            out.copied(id.as_str(), target_path.as_str(), &local, bytes, "pushed")
        }
        Transfer::Pull {
            vm_id: vm,
            path,
            local,
        } => {
            if mode.is_some() {
                return Err(CliError::usage("--mode applies to uploads only"));
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
    mode: Option<u32>,
) -> Result<u64, CliError> {
    let mode = mode.map(|m| m.to_string());
    if local.as_os_str() == "-" {
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
    fn a_download_lands_beside_its_destination_first() {
        assert_eq!(
            partial_path(Path::new("out/a.txt")),
            Path::new("out/a.txt.cmux-vm-partial")
        );
    }
}
