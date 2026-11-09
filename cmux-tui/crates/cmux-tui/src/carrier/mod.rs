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
//!   `cloud.connect route=carrier machine=<vm_id> phase=<connect|reconnect|resume> outcome=<ok|error_code> ms=<n>`,
//!   and for a failed attempt ` detail=<code>` after `ms` (a short
//!   `[a-z0-9_]` code, [`contract::detail_code`]).
//!   The same line is appended to `<workspace state dir>/carrier/connect.log`
//!   (macOS `~/Library/Application Support/cmux-tui/sessions/carrier/connect.log`,
//!   `CMUX_TUI_STATE_DIR` overrides the state dir), a file only the dial
//!   writes and nothing empties ([`route_log`]). A resume happens inside the
//!   same process, so its lines follow the connect's.
//! - Each connect attempt also appends one `carrier.phases` line to that
//!   file (never to stderr): how long the attempt spent on the ticket, the
//!   relay, the park, the handshake and the mux open
//!   ([`contract::phases_line`]).
//! - `--service desktop` carries the machine's desktop instead: raw
//!   `cmux.rd/1` bytes on stdin and stdout, through cmux-remote's
//!   `local-socket` to `/run/cmux-rd/desktop.sock`. The daemon opens it only
//!   for the machine owner's grant (`vmk: "owner"`); its refusal is
//!   `error_code` `service_refused`.
//! - Exit codes: 0 ok, 2 ticket, 3 relay, 4 parked_timeout, 5 handshake,
//!   6 service_refused, 64 bad usage.
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
//!
//! The ok reply line also carries `"vmk":"owner"` or `"vmk":"team"`, the
//! person's role on the machine as the carrier grant's `vmk` claim says
//! it; a grant without one leaves the field out.
//!
//! `--answer-fd N` hands over the first attempt's answer: the descriptor's
//! first line is `{"carrier_answer":{relay, slot, ticket, expires_at, grant,
//! daemon_key?}}`, the `carrier` a create or spare claim answered with
//! (cmux-platform #946). With 0 it is stdin's first line, and the stream
//! follows it. The first attempt then dials at once without asking the
//! platform. If the answer has no `daemon_key` (a fresh create, whose bind
//! stores the key later), the dial asks the platform for the key while the
//! relay holds the connect, and asks once more when the daemon registers if
//! the first ask came too early. The handshake waits for the key and never
//! runs unpinned. An answer whose ticket is about to expire is dropped and
//! the attempt asks as usual; later attempts always ask. A line that is
//! not such an answer (or no line) is `bad_request`, exit 64.
//!
//! `cmux carrier key --public` prints this device's carrier Noise static
//! public key on stdout as one line of unpadded base64url (32 bytes, 43
//! characters), the `carrier.noise_key` a create request carries, and exits
//! 0. The key is the one dial and serve use: on a Mac the login Keychain
//! item `com.cmuxterm.app.next.carrier-noise-key` (account `device`), made
//! the same way when it does not exist yet. Nothing private is printed.
//! Elsewhere no key lasts past one dial, so it prints nothing on stdout and
//! writes dial's failure line (`handshake`, exit 5), as it does when the
//! Keychain refuses. Any other arguments are `bad_request`, exit 64.
//!
//! `cmux carrier serve --machine <vm_id> --socket <path>` takes the same
//! flags and environment and serves the same stream on a Unix socket: one
//! session per machine, dialed by the first accepted connection, and a mux
//! control stream on it for each connection ([`serve`]).
//!
//! `cmux carrier capabilities [--json]` prints one JSON object on stdout and
//! exits 0: the routes this build can carry a Cloud session over
//! (`routes`), the faults a probe can inject (`faults`), and per carrier
//! (`carriers.relay`, `carriers.ssh`) whether it is available (with a
//! `reason` when not), can be probed, and which faults it takes
//! ([`fault::capabilities`]). It needs no network, sign-in or app. The probe
//! account's fault switch, `cmux cloud start-chat --carrier-fault`, is
//! [`fault`]'s.
//!
//! `cmux carrier tunnel --machine-id machine_… --name NAME --socket PATH`
//! keeps this Mac's tunnel into the team's provider Cloud mesh up (attach,
//! a `wg hub` on PATH, refresh, re-attach) so the ssh carrier reaches a
//! machine's mesh address through `cmux wg dial --hub PATH %h %p`
//! ([`tunnel`], [`tunnel_cli`]).
//!
//! The dial's routes are the relay, then that ssh carrier ([`ssh`]) when the
//! answer has an `ssh` candidate, this device has a carrier key and the
//! tunnel's hub answers: `--wg-hub PATH` names its socket (absolute, a Unix
//! socket path), else `<workspace state dir>/carrier/tunnel.sock`. Each
//! attempt and resume appends a `carrier.routes` line to the connect log
//! after its phases line, naming the ssh route's state and the carrier that
//! carried it ([`contract::routes_line`]).

mod answer;
mod client;
mod contract;
pub(crate) mod drill;
pub(crate) mod fault;
mod held;
mod noise_key;
mod rd_link;
mod route_log;
mod secrets;
mod serve;
mod source;
mod ssh;
pub(crate) mod tunnel;
mod tunnel_cli;

use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::crypto::StaticIdentity;
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
    pub service: DialService,
    pub deadline: Duration,
    pub api: Option<String>,
    pub token_file: Option<PathBuf>,
    pub team: Option<String>,
    /// `dial --answer-fd N`: the file descriptor whose first line is a
    /// handed-over carrier answer (0: stdin, before the stream).
    pub answer_fd: Option<i32>,
    /// `--wg-hub PATH`: the tunnel hub's socket the ssh backup carrier
    /// dials through (`carrier tunnel --socket`); else the default one.
    pub wg_hub: Option<PathBuf>,
}

/// One `cmux carrier serve` invocation: a dial per connection to `socket`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ServeArgs {
    pub dial: DialArgs,
    pub socket: PathBuf,
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
/// [--cloud-token-file PATH] [--team team_…] [--answer-fd N] [--wg-hub PATH]`, each once,
/// nothing else.
pub(crate) fn parse(args: &[String]) -> Option<DialArgs> {
    let (verb, rest) = args.split_first()?;
    if verb != "dial" {
        return None;
    }
    flags(rest, false).map(|(dial, _)| dial)
}

/// `serve --machine vm_… --socket PATH` and the dial's other flags but
/// `--service`, each once: serve carries the mux stream only. The path is
/// absolute and fits a Unix socket address.
pub(crate) fn parse_serve(args: &[String]) -> Option<ServeArgs> {
    let (verb, rest) = args.split_first()?;
    if verb != "serve" {
        return None;
    }
    let (dial, socket) = flags(rest, true)?;
    let socket = PathBuf::from(socket?);
    (socket.is_absolute() && cmux_unix_socket::fits(&socket)).then_some(ServeArgs { dial, socket })
}

/// The dial's flags; for `serve`, `--socket` in place of `--service`.
fn flags(rest: &[String], serve: bool) -> Option<(DialArgs, Option<String>)> {
    let (mut machine, mut service, mut deadline, mut api, mut token_file, mut team, mut socket) =
        (None, None, None, None, None, None, None);
    let (mut answer_fd, mut wg_hub) = (None, None);
    let mut words = rest.iter();
    while let Some(flag) = words.next() {
        let value = words.next()?.clone();
        let slot = match flag.as_str() {
            "--machine" => &mut machine,
            "--service" if !serve => &mut service,
            "--deadline-ms" => &mut deadline,
            "--cloud-api" => &mut api,
            "--cloud-token-file" => &mut token_file,
            "--team" => &mut team,
            "--socket" if serve => &mut socket,
            "--answer-fd" if !serve => &mut answer_fd,
            "--wg-hub" => &mut wg_hub,
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
    if team.as_deref().is_some_and(|t| !contract::valid_team(t)) {
        return None;
    }
    let answer_fd = match answer_fd {
        Some(text) => Some(contract::parse_answer_fd(&text)?),
        None => None,
    };
    let wg_hub = match wg_hub.map(PathBuf::from) {
        Some(hub) if !hub.is_absolute() || !cmux_unix_socket::fits(&hub) => return None,
        hub => hub,
    };
    let dial = DialArgs {
        machine,
        service,
        deadline,
        api,
        token_file: token_file.map(PathBuf::from),
        team,
        answer_fd,
        wg_hub,
    };
    Some((dial, socket))
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

/// `team`, else a non-empty `CMUX_CLOUD_TEAM`, checked: `None` when the
/// value is not a team id, `Some(None)` when neither names one.
fn with_team_env_value(team: Option<String>) -> Option<Option<String>> {
    if team.is_some() {
        return Some(team);
    }
    let env = std::env::var(TEAM_ENV).ok().map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());
    if env.as_deref().is_some_and(|t| !contract::valid_team(t)) {
        return None;
    }
    Some(env)
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

/// What every dial of one invocation shares: the platform source and this
/// device's Noise identity. `Err` is the exit code, its line written.
fn prepare(args: DialArgs) -> Result<(DialArgs, Arc<answer::HttpSource>, StaticIdentity), i32> {
    let Some(args) = with_team_env(args, std::env::var(TEAM_ENV).ok()) else {
        return Err(usage(&format!("{TEAM_ENV} is not team_ and 20 lowercase hex digits")));
    };
    let source = match source(&args) {
        Ok(source) => Arc::new(source),
        Err(failure) => return Err(fail(&failure)),
    };
    let identity = match noise_key::device_identity() {
        Ok(identity) => identity,
        Err(why) => return Err(fail(&Failure::fatal(contract::Step::Handshake, why))),
    };
    Ok((args, source, identity))
}

fn runtime() -> Result<tokio::runtime::Runtime, i32> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|_| fail(&Failure::fatal(contract::Step::Relay, "no async runtime")))
}

/// The full-jitter draw of the session's own reconnect policy (the
/// tunnel's retry waits, [`tunnel_cli`]).
fn jitter(ceiling: Duration) -> Duration {
    cmux_remote::connection::ReconnectPolicy::default().retry_delay(ceiling)
}

/// Opens the machine's desktop stream on the dialed session by `deadline`.
/// The daemon's refusal is [`contract::Step::Service`] (exit 6); a session
/// that drops or stalls before the daemon answers is the carrier's
/// ([`contract::Step::Relay`]), never a refusal.
async fn open_desktop(
    multiplexer: &Arc<cmux_remote::service::ServiceMultiplexer>,
    deadline: tokio::time::Instant,
) -> Result<Arc<cmux_remote::service::ServiceStream>, Failure> {
    use cmux_remote::bridge::{CLOUD_DESKTOP_SOCKET, open_local_socket};
    match tokio::time::timeout_at(deadline, open_local_socket(multiplexer, CLOUD_DESKTOP_SOCKET))
        .await
    {
        Ok(Ok(stream)) => Ok(stream),
        Ok(Err(error)) => Err(desktop_failure(error, multiplexer.session_unavailable())),
        Err(_) => Err(Failure::fatal(
            contract::Step::Relay,
            "the desktop did not open before the deadline",
        )),
    }
}

/// Why the desktop stream did not open: the daemon's refusal is the
/// service's; a session the daemon no longer has (`session_unavailable`:
/// the multiplexer's reader saw it, or the error itself says so) is dialed
/// fresh; anything else ended
/// the session, which is the carrier's.
fn desktop_failure(error: cmux_remote::bridge::BridgeError, session_unavailable: bool) -> Failure {
    use cmux_remote::bridge::BridgeError;
    if let BridgeError::Rejected(why) = error {
        return Failure::fatal(contract::Step::Service, why);
    }
    // The reader may not have marked the session yet when the open's own
    // send (or a heartbeat) met its typed end first.
    let gone = session_unavailable
        || matches!(&error, BridgeError::Service(service) if service.is_session_unavailable());
    let detail = format!("the session ended before the desktop opened: {error}");
    // The session host restarted after the session's first stream opened
    // and no longer has it: the dial opens a fresh one.
    if gone {
        Failure::session_gone(contract::Step::Relay, detail)
    } else {
        Failure::fatal(contract::Step::Relay, detail)
    }
}

/// The handed-over answer on `fd`: its first line, at most
/// [`contract::MAX_STDIN_LINE`] bytes. Stdin (0) is read through the
/// process's shared stdin buffer, so the stream after the line stays for the
/// bridge; any other descriptor is this process's to read and close.
fn read_answer(fd: i32) -> Result<answer::CarrierAnswer, &'static str> {
    use std::io::{BufRead as _, Read as _};
    let mut line = Zeroizing::new(Vec::new());
    let limit = (contract::MAX_STDIN_LINE + 1) as u64;
    let read = if fd == 0 {
        std::io::stdin().lock().take(limit).read_until(b'\n', &mut line)
    } else {
        use std::os::fd::FromRawFd as _;
        // SAFETY: `--answer-fd` hands this descriptor to this process, which
        // reads its one line and closes it here; nothing else uses it.
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        std::io::BufReader::new(file).take(limit).read_until(b'\n', &mut line)
    };
    match read {
        Ok(0) | Err(_) => return Err("--answer-fd gave no answer line"),
        Ok(_) => {}
    }
    if line.last() != Some(&b'\n') && line.len() > contract::MAX_STDIN_LINE {
        return Err("the answer line is too long");
    }
    contract::answer_line(line.strip_suffix(b"\n").unwrap_or(line.as_slice()))
}

/// `key --public`, exactly.
pub(crate) fn parse_key(args: &[String]) -> bool {
    matches!(args, [verb, flag] if verb == "key" && flag == "--public")
}

/// The line `cmux carrier key --public` prints for `key`: unpadded
/// base64url and a newline.
pub(crate) fn public_key_line(key: &[u8; 32]) -> String {
    format!("{}\n", answer::key_text(key))
}

/// `cmux carrier key --public`: the device's public key on stdout.
fn key(args: &[String]) -> i32 {
    if !parse_key(args) {
        return usage("usage: cmux carrier key --public");
    }
    match noise_key::lasting_identity() {
        Ok(identity) => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(public_key_line(&identity.public_key()).as_bytes());
            let _ = stdout.flush();
            0
        }
        Err(why) => fail(&Failure::fatal(contract::Step::Handshake, why)),
    }
}

/// `capabilities` or `capabilities --json`, exactly (the answer is JSON either way).
pub(crate) fn parse_capabilities(args: &[String]) -> bool {
    match args {
        [verb] => verb == "capabilities",
        [verb, flag] => verb == "capabilities" && flag == "--json",
        _ => false,
    }
}

/// `cmux carrier capabilities [--json]`: this build's carriers on stdout.
fn capabilities(args: &[String]) -> i32 {
    if !parse_capabilities(args) {
        return usage("usage: cmux carrier capabilities [--json]");
    }
    let line = format!("{}\n", fault::capabilities(&fault::this_build()));
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(line.as_bytes());
    let _ = stdout.flush();
    0
}

/// `cmux carrier …` from `main`: the exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    if args.first().is_some_and(|verb| verb == "serve") {
        return serve::run(args);
    }
    if args.first().is_some_and(|verb| verb == "secrets") {
        return secrets::run(args);
    }
    if args.first().is_some_and(|verb| verb == "key") {
        return key(args);
    }
    if args.first().is_some_and(|verb| verb == "tunnel") {
        return tunnel_cli::run(args);
    }
    if args.first().is_some_and(|verb| verb == "capabilities") {
        return capabilities(args);
    }
    let Some(args) = parse(args) else {
        return usage(
            "usage: cmux carrier dial --machine vm_… [--service mux|desktop] [--deadline-ms N] [--cloud-api URL] [--cloud-token-file PATH] [--team team_…] [--answer-fd N] [--wg-hub PATH]",
        );
    };
    let (args, source, identity) = match prepare(args) {
        Ok(prepared) => prepared,
        Err(code) => return code,
    };
    let prefetched = match args.answer_fd.map(read_answer).transpose() {
        Ok(answer) => Arc::new(answer::Prefetched::new(answer)),
        Err(why) => return usage(why),
    };
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(code) => return code,
    };
    let code = runtime.block_on(async {
        // Route lines wait until the reply line is out, so it stays first.
        let (lines, mut queued) = tokio::sync::mpsc::unbounded_channel::<String>();
        let connect_log = route_log::default_path();
        let phases_log = connect_log.clone();
        let plan = client::DialPlan {
            machine: args.machine.clone(),
            source,
            identity,
            deadline: tokio::time::Instant::now() + args.deadline,
            prefetched,
            log: Arc::new(move |line| {
                if let Some(path) = &connect_log {
                    route_log::append(path, &line);
                }
                let _ = lines.send(line);
            }),
            phases: Arc::new(move |line| {
                if let Some(path) = &phases_log {
                    route_log::append(path, &line);
                }
            }),
            fresh_sessions: contract::FreshSessions::default(),
            ssh: Arc::new(ssh::SshSetup::from_env(args.wg_hub.clone())),
        };
        // The desktop opens its stream before the reply, so a refusal (not
        // the owner, no desktop on the machine) is the dial's answer. The
        // open stays inside the dial's one deadline. A session the host lost
        // before the desktop opened is dialed fresh, from the same budget
        // as the dial's own fresh sessions (`MAX_FRESH_SESSIONS` in all).
        let (dialed, desktop) = loop {
            let dialed = client::dial(&plan).await;
            match (dialed, args.service) {
                (Ok(dialed), DialService::Desktop) => {
                    match open_desktop(&dialed.multiplexer, plan.deadline).await {
                        Ok(stream) => break (Ok(dialed), Some(stream)),
                        Err(failure) => {
                            dialed.multiplexer.shutdown().await;
                            let _ = dialed.connection.close().await;
                            if failure.fresh_session && plan.fresh_sessions.take() {
                                continue;
                            }
                            break (Err(failure), None);
                        }
                    }
                }
                (dialed, _) => break (dialed, None),
            }
        };
        let code = match &dialed {
            Ok(dialed) => {
                reply(&contract::connected_line(dialed.vmk));
                0
            }
            Err(failure) => fail(failure),
        };
        while let Ok(line) = queued.try_recv() {
            reply(&line);
        }
        let Ok(dialed) = dialed else { return code };
        // Later route lines (resumes) go out as they come.
        tokio::spawn(async { let mut n = 0u32; loop { tokio::time::sleep(std::time::Duration::from_secs(1)).await; n += 1; { use std::io::Write as _; if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open("/tmp/g4trace.log") { let _ = writeln!(f, "G4TRACE {:?} tick {n}", std::time::SystemTime::now()); } }; } });
        let writer = tokio::spawn(async move {
            while let Some(line) = queued.recv().await {
                reply(&line);
            }
        });
        let client::Dialed { connection, multiplexer, mux, rd_link, .. } = dialed;
        let _ = match desktop {
            Some(stream) => {
                mux.close().await;
                // The datagram link only when the platform turned it on and
                // `CMUX_RD_LINK=0` does not keep it off; else the plain copy.
                let killed = std::env::var(rd_link::KILL_SWITCH).is_ok_and(|v| v == "0");
                match rd_link.filter(|_| !killed) {
                    Some(link) => {
                        let machine = args.machine.clone();
                        let link_log = route_log::default_path();
                        rd_link::bridge(
                            stream,
                            tokio::io::stdin(),
                            tokio::io::stdout(),
                            link.stun,
                            link.turn,
                            move |note| {
                                if let Some(path) = &link_log {
                                    route_log::append(
                                        path,
                                        &format!("cloud.desktop_link machine={machine} {note}\n"),
                                    );
                                }
                            },
                        )
                        .await
                    }
                    None => {
                        cmux_remote::bridge::bridge_raw_stream(
                            stream,
                            tokio::io::stdin(),
                            tokio::io::stdout(),
                        )
                        .await
                    }
                }
            }
            None => mux.bridge(tokio::io::stdin(), tokio::io::stdout()).await,
        };
        multiplexer.shutdown().await;
        let _ = connection.close().await;
        writer.abort();
        0
    });
    runtime.shutdown_timeout(STDIO_SHUTDOWN_TIMEOUT);
    code
}

#[cfg(test)]
mod argv_contract_tests;
#[cfg(test)]
mod tests;
