//! `cmux link dial --host ID [--service daemon|ssh]`: a stdio bridge to a
//! service of a paired install or a Cloud host, for callers that cannot use
//! the link socket themselves (cmux-cloud's carrier, an ssh ProxyCommand).
//!
//! Contract (cmux-tui/spec/cli.md, "cmux link dial"):
//! - stderr always gets exactly one JSON line first:
//!   `{"ok":true,"path_state":...,"relay_available":false}` when connected,
//!   `{"ok":false,"error_code":...,"path_state":"unreachable","relay_available":false}`
//!   otherwise. Key order is not part of the contract.
//! - On `ok` the stream's bytes use stdin and stdout; the process exits 0
//!   when the stream ends.
//! - Exit codes: 0 ok, 2 unknown_host, 3 not_authorized, 4 host_paused,
//!   5 unreachable, 6 link_unavailable, 64 bad usage or bad_request.

use std::path::{Path, PathBuf};

use cmux_link::dial::{DialError, PathState, Service, line};
use cmux_remote::provider::overlay::{OverlayDialError, OverlayStream, dial_link};
use serde_json::json;
use tokio::io::AsyncWriteExt;

/// The `error_code` when no link answers on its socket.
pub(super) const LINK_UNAVAILABLE: &str = "link_unavailable";

/// Why a dial did not connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Failure {
    /// The link answered with this error (None: it gave no code).
    Refused(Option<DialError>),
    /// No link runs, or it did not answer the dial protocol.
    LinkUnavailable,
    /// The arguments are not a valid dial.
    BadUsage,
}

impl Failure {
    pub(super) fn exit_code(self) -> i32 {
        match self {
            Self::Refused(Some(DialError::UnknownHost)) => 2,
            Self::Refused(Some(DialError::NotAuthorized)) => 3,
            Self::Refused(Some(DialError::HostPaused)) => 4,
            Self::Refused(Some(DialError::Unreachable) | None) => 5,
            Self::LinkUnavailable => 6,
            Self::Refused(Some(DialError::BadRequest)) | Self::BadUsage => 64,
        }
    }

    fn error_code(self) -> serde_json::Value {
        match self {
            Self::Refused(Some(error)) => json!(error),
            Self::Refused(None) => json!(DialError::Unreachable),
            Self::LinkUnavailable => json!(LINK_UNAVAILABLE),
            Self::BadUsage => json!(DialError::BadRequest),
        }
    }

    /// The stderr JSON line for this failure.
    pub(super) fn line(self) -> String {
        line(&json!({
            "ok": false,
            "error_code": self.error_code(),
            "path_state": PathState::Unreachable,
            "relay_available": cmux_link::dial::RELAY_AVAILABLE,
        }))
    }
}

/// The stderr JSON line for a connected stream.
pub(super) fn connected_line(stream: &OverlayStream) -> String {
    line(&json!({
        "ok": true,
        "path_state": stream.path_state,
        "relay_available": stream.relay_available,
    }))
}

/// `--host ID [--service daemon|ssh]`, each once, nothing else.
pub(super) fn parse(args: &[String]) -> Result<(String, Service), Failure> {
    let (mut host, mut service) = (None, None);
    let mut index = 0;
    while index < args.len() {
        let value = args.get(index + 1).ok_or(Failure::BadUsage)?;
        let slot = match args[index].as_str() {
            "--host" => &mut host,
            "--service" => &mut service,
            _ => return Err(Failure::BadUsage),
        };
        if slot.replace(value.clone()).is_some() {
            return Err(Failure::BadUsage);
        }
        index += 2;
    }
    let host = host.filter(|host| cmux_link::stamp::valid_id(host)).ok_or(Failure::BadUsage)?;
    let service = match service.as_deref() {
        None | Some("daemon") => Service::Daemon,
        Some("ssh") => Service::Ssh,
        Some(_) => return Err(Failure::BadUsage),
    };
    Ok((host, service))
}

/// Dial through the link at `socket`.
pub(super) async fn connect(
    socket: &Path,
    host: &str,
    service: Service,
) -> Result<OverlayStream, Failure> {
    match dial_link(socket, host, service).await {
        Ok(stream) => Ok(stream),
        Err(OverlayDialError::Refused { error, .. }) => Err(Failure::Refused(error)),
        Err(OverlayDialError::LinkUnavailable(_) | OverlayDialError::Protocol) => {
            Err(Failure::LinkUnavailable)
        }
    }
}

/// The running link's socket: from its registration, else the default path.
fn link_socket() -> PathBuf {
    cmux_tui_core::platform::workspace_state_dir()
        .and_then(|dir| cmux_link::registration::read_live(&dir))
        .map_or_else(super::state::socket_path, |live| live.socket)
}

/// `cmux link dial ...`: the exit code.
pub(super) fn run(args: &[String]) -> i32 {
    let (host, service) = match parse(args) {
        Ok(parsed) => parsed,
        Err(failure) => return report(failure),
    };
    let Ok(runtime) = super::tokio_runtime() else { return report(Failure::LinkUnavailable) };
    runtime.block_on(async {
        let stream = match connect(&link_socket(), &host, service).await {
            Ok(stream) => stream,
            Err(failure) => return report(failure),
        };
        eprint!("{}", connected_line(&stream));
        bridge(stream).await;
        0
    })
}

fn report(failure: Failure) -> i32 {
    eprint!("{}", failure.line());
    failure.exit_code()
}

/// Carry stdin to the stream and the stream to stdout until the stream ends.
async fn bridge(stream: OverlayStream) {
    let (mut reader, mut writer) = stream.stream.into_split();
    let upload = async {
        let _ = tokio::io::copy(&mut tokio::io::stdin(), &mut writer).await;
        let _ = writer.shutdown().await;
    };
    let download = async {
        let mut stdout = tokio::io::stdout();
        let _ = tokio::io::copy(&mut reader, &mut stdout).await;
        let _ = stdout.flush().await;
    };
    tokio::select! {
        () = download => {}
        () = async { upload.await; std::future::pending::<()>().await } => {}
    }
}

#[cfg(test)]
#[path = "dial_cli_tests.rs"]
mod tests;
