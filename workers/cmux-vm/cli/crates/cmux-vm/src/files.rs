//! Saved-disk reads use only file GETs. They never execute a guest command,
//! create a client session, or start/resume the VM, including on errors.

use std::io::Write;

use clap::{Args, Subcommand};
use cmux_vm_client::raw::{Client, Error, ResponseValue, types};
use futures::StreamExt;

use crate::{error::CliError, fetch_body, output::Printer};

#[derive(Subcommand, Debug)]
pub(crate) enum FileCommand {
    /// Show file metadata on a running, paused, stopped or retired VM
    Stat(PathArgs),
    /// List a directory without starting the VM
    Ls(PathArgs),
    /// Stream a file's raw bytes to stdout without starting the VM (no --json)
    Read(ReadArgs),
}

#[derive(Args, Debug)]
pub(crate) struct PathArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Absolute guest path, without parent segments
    path: String,
}

impl PathArgs {
    fn validate(&self) -> Result<(types::VmId, types::GuestPath), CliError> {
        let id = self
            .vm_id
            .parse()
            .map_err(|_| CliError::usage("invalid VM id"))?;
        if !self.path.starts_with('/')
            || self.path.contains('\0')
            || self.path.split('/').any(|part| part == "..")
            || self.path.encode_utf16().count() > 4096
        {
            return Err(CliError::usage(
                "guest path must be absolute, at most 4096 characters, without parent segments or NUL",
            ));
        }
        let path = self
            .path
            .parse()
            .map_err(|_| CliError::usage("invalid guest path"))?;
        Ok((id, path))
    }
}

#[derive(Args, Debug)]
pub(crate) struct ReadArgs {
    #[command(flatten)]
    file: PathArgs,
    /// One byte range, e.g. bytes=0-4095 or bytes=4096-
    #[arg(long)]
    range: Option<String>,
}

fn parse_range(value: &str) -> Result<types::FilesReadFileRange, CliError> {
    let invalid =
        || CliError::usage("--range must be bytes=START-END or bytes=START-, with END >= START");
    let range = value.parse().map_err(|_| invalid())?;
    let (start, end) = value
        .strip_prefix("bytes=")
        .and_then(|s| s.split_once('-'))
        .ok_or_else(invalid)?;
    let start = start.parse::<u64>().map_err(|_| invalid())?;
    if !end.is_empty() && end.parse::<u64>().map_err(|_| invalid())? < start {
        return Err(invalid());
    }
    Ok(range)
}

pub(crate) async fn run(
    client: &Client,
    command: FileCommand,
    json: bool,
    stdout: &mut dyn Write,
) -> Result<(), CliError> {
    match command {
        FileCommand::Stat(args) => {
            let (id, path) = args.validate()?;
            let body = fetch_body(client.files_stat_file(id.as_str(), &path, None))
                .await
                .map_err(|e| e.for_vm(id.as_str(), "file stat"))?;
            Printer::new(json, stdout).file_stat(&body)
        }
        FileCommand::Ls(args) => {
            let (id, path) = args.validate()?;
            let body = fetch_body(client.files_list_files(id.as_str(), &path, None))
                .await
                .map_err(|e| e.for_vm(id.as_str(), "file ls"))?;
            Printer::new(json, stdout).file_list(&body)
        }
        FileCommand::Read(args) => {
            let (id, path) = args.file.validate()?;
            let range = args.range.as_deref().map(parse_range).transpose()?;
            if json {
                return Err(CliError::usage(
                    "file read streams raw bytes; omit --json and redirect stdout to save the file",
                ));
            }
            let response = client
                .files_read_file(id.as_str(), &path, range.as_ref(), None)
                .await;
            let body = match response {
                Ok(response)
                    if (response.status().as_u16() == 200 && range.is_none())
                        || (response.status().as_u16() == 206 && range.is_some()) =>
                {
                    response.into_inner()
                }
                Ok(_) => {
                    return Err(CliError::unexpected(
                        "the VM API ignored the requested byte range; no file bytes were written",
                    ));
                }
                // The API documents and serves 206, but the generated client's
                // success schema currently lists only 200. Preserve its stream.
                Err(Error::UnexpectedResponse(response))
                    if response.status().as_u16() == 206 && range.is_some() =>
                {
                    ResponseValue::stream(response).into_inner()
                }
                Err(error) => {
                    return Err(CliError::from_api(error)
                        .await
                        .for_vm(id.as_str(), "file read"));
                }
            };
            let mut stream = body.into_inner();
            while let Some(chunk) = stream.next().await {
                let chunk = chunk.map_err(|e| {
                    CliError::network(format!(
                        "file read was interrupted; stdout may contain partial bytes: {e}"
                    ))
                })?;
                stdout
                    .write_all(&chunk)
                    .map_err(|e| CliError::unexpected(format!("write file output: {e}")))?;
            }
            stdout
                .flush()
                .map_err(|e| CliError::unexpected(format!("flush file output: {e}")))
        }
    }
}
