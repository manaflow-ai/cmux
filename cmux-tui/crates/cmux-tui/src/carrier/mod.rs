//! `cmux carrier dial --machine <vm_id> [--deadline-ms N]`: a stdio bridge to
//! a Cloud machine's session daemon over its carrier (design/cloud-carrier.md):
//! a cmux-remote session through the machine's relay slot, admitted by a
//! carrier grant, with the daemon's key pinned.
//!
//! The pin is required. An answer without `daemon_key`, or with one that is
//! not 32 canonical base64url bytes, fails at `ticket` ("the machine has no
//! daemon key", exit 2) before any handshake; a daemon whose static key
//! differs from it fails at `handshake` (exit 5). No key is ever learned
//! from a handshake.
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
//!   The same line is appended to `<workspace state dir>/carrier/connect.log`
//!   (macOS `~/Library/Application Support/cmux-tui/sessions/carrier/connect.log`,
//!   `CMUX_TUI_STATE_DIR` overrides the state dir), a file only the dial
//!   writes and nothing empties ([`route_log`]). A resume happens inside the
//!   same process, so its lines follow the connect's.
//! - Exit codes: 0 ok, 2 ticket, 3 relay, 4 parked_timeout, 5 handshake, 64 bad usage.
//!
//! One deadline (default 180 s) covers the ticket, the relay, the park and
//! the handshake. The ticket and grant come from cmux-platform
//! (`POST /v1/cloud/machines/{id}/carrier`) with the person's credential:
//! `--cloud-api URL` (or `CMUX_CLOUD_API_URL`) and `--cloud-token-file PATH`
//! (or `CMUX_CLOUD_ACCESS_TOKEN`). Nothing here prints a credential.
//!
//! `--team team_…` (or `CMUX_CLOUD_TEAM`) names the machine's team: it goes
//! out as the `x-cmux-team` header, without which the platform resolves the
//! credential to the person's own team and refuses a machine of a shared
//! one. It is `team_` and 20 lowercase hex digits; any other value is
//! `bad_request`. Unset, no header is sent.

mod answer;
mod client;
mod contract;
mod noise_key;
mod route_log;
mod secrets;

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
const TEAM_ENV: &str = "CMUX_CLOUD_TEAM";

/// One `cmux carrier dial` invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DialArgs {
    pub machine: String,
    pub deadline: Duration,
    pub api: Option<String>,
    pub token_file: Option<PathBuf>,
    pub team: Option<String>,
}

/// `dial --machine vm_… [--deadline-ms N] [--cloud-api URL] [--cloud-token-file PATH]
/// [--team team_…]`, each once, nothing else.
pub(crate) fn parse(args: &[String]) -> Option<DialArgs> {
    let (verb, rest) = args.split_first()?;
    if verb != "dial" {
        return None;
    }
    let (mut machine, mut deadline, mut api, mut token_file, mut team) =
        (None, None, None, None, None);
    let mut words = rest.iter();
    while let Some(flag) = words.next() {
        let value = words.next()?.clone();
        let slot = match flag.as_str() {
            "--machine" => &mut machine,
            "--deadline-ms" => &mut deadline,
            "--cloud-api" => &mut api,
            "--cloud-token-file" => &mut token_file,
            "--team" => &mut team,
            _ => return None,
        };
        if slot.replace(value).is_some() {
            return None;
        }
    }
    let machine = machine.filter(|m| contract::valid_machine(m))?;
    let deadline = match deadline {
        Some(text) => contract::parse_deadline(&text)?,
        None => DEFAULT_DEADLINE,
    };
    if team.as_deref().is_some_and(|t| !contract::valid_team(t)) {
        return None;
    }
    Some(DialArgs { machine, deadline, api, token_file: token_file.map(PathBuf::from), team })
}

/// `--team`, else a non-empty `CMUX_CLOUD_TEAM` (`env`), checked; `None`
/// when the environment's value is not a team id.
pub(crate) fn with_team_env(mut args: DialArgs, env: Option<String>) -> Option<DialArgs> {
    if args.team.is_none() {
        let env = env.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());
        if env.as_deref().is_some_and(|t| !contract::valid_team(t)) {
            return None;
        }
        args.team = env;
    }
    Some(args)
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
    answer::HttpSource::new(api, credential, args.team.clone()).map_err(ticket)
}

/// `cmux carrier …` from `main`: the exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    if args.first().is_some_and(|verb| verb == "secrets") {
        return secrets::run(args);
    }
    let Some(args) = parse(args) else {
        return usage(
            "usage: cmux carrier dial --machine vm_… [--deadline-ms N] [--cloud-api URL] [--cloud-token-file PATH] [--team team_…]",
        );
    };
    let Some(args) = with_team_env(args, std::env::var(TEAM_ENV).ok()) else {
        return usage(&format!("{TEAM_ENV} is not team_ and 20 lowercase hex digits"));
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
        let connect_log = route_log::default_path();
        let plan = client::DialPlan {
            machine: args.machine.clone(),
            source,
            identity,
            deadline: tokio::time::Instant::now() + args.deadline,
            log: Arc::new(move |line| {
                if let Some(path) = &connect_log {
                    route_log::append(path, &line);
                }
                let _ = lines.send(line);
            }),
        };
        let dialed = client::dial(&plan, |ceiling| {
            cmux_remote::connection::ReconnectPolicy::default().retry_delay(ceiling)
        })
        .await;
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
        let client::Dialed { connection, multiplexer, mux } = dialed;
        let _ = mux.bridge(tokio::io::stdin(), tokio::io::stdout()).await;
        multiplexer.shutdown().await;
        let _ = connection.close().await;
        writer.abort();
        0
    });
    runtime.shutdown_timeout(STDIO_SHUTDOWN_TIMEOUT);
    code
}

#[cfg(test)]
mod tests;
