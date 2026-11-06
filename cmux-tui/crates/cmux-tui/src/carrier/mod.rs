//! `cmux carrier dial --machine <vm_id> [--deadline-ms N]`: a stdio bridge to
//! a Cloud machine's session daemon over its carrier (design/cloud-carrier.md):
//! a cmux-remote session through the machine's relay slot, admitted by a
//! carrier grant, with the daemon's key pinned.
//!
//! Contract (the same one `cmux link dial` kept for the Cloud app server):
//! - stderr gets exactly one JSON reply line first: `{"ok":true,
//!   "path_state":"relay","route":"carrier"}` when connected, else
//!   `{"ok":false,"error_code":...,"error_detail"?:...,"route":"carrier"}`.
//!   `error_code` names the step the dial did not get past: `ticket`,
//!   `relay`, `parked_timeout` or `handshake` (`bad_request` for bad usage).
//! - On `ok`, stdin and stdout carry the daemon stream: `cmux.protocol/2`
//!   lines, on the session's mux control service (what the Mac's own remote
//!   client bridges to its local socket). The process exits 0 when it ends.
//! - Every connect attempt, and every resume attempt of the session after it,
//!   writes one route line on stderr after the reply line:
//!   `cloud.connect route=carrier machine=<vm_id> phase=<connect|reconnect|resume> outcome=<ok|error_code> ms=<n>`.
//! - `--service desktop` carries the machine's desktop instead: raw
//!   `cmux.rd/1` bytes on stdin and stdout, through cmux-remote's
//!   `local-socket` to `/run/cmux-rd/desktop.sock`. The daemon opens it only
//!   for the machine owner's grant (`vmk: "owner"`); a refusal is
//!   `error_code` `service_refused`.
//! - Exit codes: 0 ok, 2 ticket, 3 relay, 4 parked_timeout, 5 handshake,
//!   6 service_refused, 64 bad usage.
//!
//! One deadline (default 180 s) covers the ticket, the relay, the park and
//! the handshake. The ticket and grant come from cmux-platform
//! (`POST /v1/cloud/machines/{id}/carrier`) with the person's credential:
//! `--cloud-api URL` (or `CMUX_CLOUD_API_URL`) and `--cloud-token-file PATH`
//! (or `CMUX_CLOUD_ACCESS_TOKEN`). Nothing here prints a credential.

mod answer;
mod client;
mod contract;
mod noise_key;

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use contract::{BAD_REQUEST, DEFAULT_DEADLINE, Failure};
use zeroize::Zeroizing;

/// Stdin reads cannot be cancelled: the runtime gives them this long once
/// the stream ended.
const STDIO_SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(100);
const API_ENV: &str = "CMUX_CLOUD_API_URL";
const TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";

/// One `cmux carrier dial` invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DialArgs {
    pub machine: String,
    pub service: DialService,
    pub deadline: Duration,
    pub api: Option<String>,
    pub token_file: Option<PathBuf>,
}

/// What the dial's stdio carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DialService {
    /// `cmux.protocol/2` lines on the session's mux control service.
    Mux,
    /// The machine's desktop (`cmux.rd/1` bytes): cmux-remote's
    /// `local-socket` to [`cmux_remote::bridge::CLOUD_DESKTOP_SOCKET`],
    /// which the daemon opens only for the machine owner's grant.
    Desktop,
}

/// `dial --machine vm_… [--service mux|desktop] [--deadline-ms N] [--cloud-api URL]
/// [--cloud-token-file PATH]`, each once, nothing else.
pub(crate) fn parse(args: &[String]) -> Option<DialArgs> {
    let (verb, rest) = args.split_first()?;
    if verb != "dial" {
        return None;
    }
    let (mut machine, mut service, mut deadline, mut api, mut token_file) =
        (None, None, None, None, None);
    let mut words = rest.iter();
    while let Some(flag) = words.next() {
        let value = words.next()?.clone();
        let slot = match flag.as_str() {
            "--machine" => &mut machine,
            "--service" => &mut service,
            "--deadline-ms" => &mut deadline,
            "--cloud-api" => &mut api,
            "--cloud-token-file" => &mut token_file,
            _ => return None,
        };
        if slot.replace(value).is_some() {
            return None;
        }
    }
    let machine = machine.filter(|m| contract::valid_machine(m))?;
    let service = match service.as_deref() {
        None | Some("mux") => DialService::Mux,
        Some("desktop") => DialService::Desktop,
        Some(_) => return None,
    };
    let deadline = match deadline {
        Some(text) => contract::parse_deadline(&text)?,
        None => DEFAULT_DEADLINE,
    };
    Some(DialArgs { machine, service, deadline, api, token_file: token_file.map(PathBuf::from) })
}

fn reply(line: &str) {
    let mut stderr = std::io::stderr().lock();
    let _ = stderr.write_all(line.as_bytes());
    let _ = stderr.flush();
}

fn fail(failure: &Failure) -> i32 {
    reply(&contract::failure_line(failure.step.error_code(), Some(&failure.detail)));
    failure.step.exit_code()
}

fn usage(detail: &str) -> i32 {
    reply(&contract::failure_line(BAD_REQUEST, Some(detail)));
    64
}

/// The cmux-platform source from the flags or the environment.
fn source(args: &DialArgs) -> Result<answer::HttpSource, Failure> {
    let ticket = |why: String| Failure::fatal(contract::Step::Ticket, why);
    let api = args
        .api
        .clone()
        .or_else(|| std::env::var(API_ENV).ok())
        .filter(|a| !a.trim().is_empty())
        .ok_or_else(|| ticket(format!("name the cmux API with --cloud-api URL or {API_ENV}")))?;
    let api = crate::cli::secure_cloud_origin(api.trim()).map_err(ticket)?;
    let credential = match (&args.token_file, std::env::var(TOKEN_ENV).ok()) {
        (Some(path), _) => answer::Credential::File(path.clone()),
        (None, Some(value)) => answer::Credential::Value(Zeroizing::new(value)),
        (None, None) => {
            return Err(ticket(format!(
                "give the cmux credential with --cloud-token-file PATH or {TOKEN_ENV}"
            )));
        }
    };
    answer::HttpSource::new(api, credential).map_err(ticket)
}

/// Opens the machine's desktop stream on the dialed session by `deadline`.
/// The daemon's refusal is [`contract::Step::Service`] (exit 6); a session
/// that drops or stalls before the daemon answers is the carrier's
/// ([`contract::Step::Relay`]), never a refusal.
async fn open_desktop(
    multiplexer: &Arc<cmux_remote::service::ServiceMultiplexer>,
    deadline: tokio::time::Instant,
) -> Result<Arc<cmux_remote::service::ServiceStream>, Failure> {
    use cmux_remote::bridge::{BridgeError, CLOUD_DESKTOP_SOCKET, open_local_socket};
    match tokio::time::timeout_at(deadline, open_local_socket(multiplexer, CLOUD_DESKTOP_SOCKET))
        .await
    {
        Ok(Ok(stream)) => Ok(stream),
        Ok(Err(BridgeError::Rejected(why))) => Err(Failure::fatal(contract::Step::Service, why)),
        Ok(Err(error)) => Err(Failure::fatal(
            contract::Step::Relay,
            format!("the session ended before the desktop opened: {error}"),
        )),
        Err(_) => Err(Failure::fatal(
            contract::Step::Relay,
            "the desktop did not open before the deadline",
        )),
    }
}

/// `cmux carrier …` from `main`: the exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    let Some(args) = parse(args) else {
        return usage(
            "usage: cmux carrier dial --machine vm_… [--service mux|desktop] [--deadline-ms N] [--cloud-api URL] [--cloud-token-file PATH]",
        );
    };
    let source = match source(&args) {
        Ok(source) => Arc::new(source),
        Err(failure) => return fail(&failure),
    };
    let identity = match noise_key::device_identity() {
        Ok(identity) => identity,
        Err(why) => return fail(&Failure::fatal(contract::Step::Handshake, why)),
    };
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread().enable_all().build() else {
        return fail(&Failure::fatal(contract::Step::Relay, "no async runtime"));
    };
    let code = runtime.block_on(async {
        // Route lines wait until the reply line is out, so it stays first.
        let (lines, mut queued) = tokio::sync::mpsc::unbounded_channel::<String>();
        let plan = client::DialPlan {
            machine: args.machine.clone(),
            source,
            identity,
            deadline: tokio::time::Instant::now() + args.deadline,
            log: Arc::new(move |line| {
                let _ = lines.send(line);
            }),
        };
        let dialed = client::dial(&plan, |ceiling| {
            cmux_remote::connection::ReconnectPolicy::default().retry_delay(ceiling)
        })
        .await;
        // The desktop opens its stream before the reply, so a refusal (not
        // the owner, no desktop on the machine) is the dial's answer. The
        // open stays inside the dial's one deadline.
        let (dialed, desktop) = match (dialed, args.service) {
            (Ok(dialed), DialService::Desktop) => {
                match open_desktop(&dialed.multiplexer, plan.deadline).await {
                    Ok(stream) => (Ok(dialed), Some(stream)),
                    Err(failure) => {
                        dialed.multiplexer.shutdown().await;
                        let _ = dialed.connection.close().await;
                        (Err(failure), None)
                    }
                }
            }
            (dialed, _) => (dialed, None),
        };
        let code = match &dialed {
            Ok(_) => {
                reply(&contract::connected_line());
                0
            }
            Err(failure) => fail(failure),
        };
        while let Ok(line) = queued.try_recv() {
            reply(&line);
        }
        let Ok(dialed) = dialed else { return code };
        // Later route lines (resumes) go out as they come.
        let writer = tokio::spawn(async move {
            while let Some(line) = queued.recv().await {
                reply(&line);
            }
        });
        let _ = match desktop {
            Some(stream) => {
                cmux_remote::bridge::bridge_raw_stream(
                    stream,
                    tokio::io::stdin(),
                    tokio::io::stdout(),
                )
                .await
            }
            None => {
                cmux_remote::bridge::bridge_mux_control(
                    &dialed.multiplexer,
                    tokio::io::stdin(),
                    tokio::io::stdout(),
                )
                .await
            }
        };
        dialed.multiplexer.shutdown().await;
        let _ = dialed.connection.close().await;
        writer.abort();
        0
    });
    runtime.shutdown_timeout(STDIO_SHUTDOWN_TIMEOUT);
    code
}

#[cfg(test)]
mod tests;
