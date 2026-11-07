//! `cmux carrier serve --machine <vm_id> --socket <path> [dial flags]`: the
//! carrier dial behind a Unix socket, for callers that hand a daemon socket
//! path to the bundled CLI (uploads, a chat start's copy, moves and bring
//! back, access asks, machine update, the phone's link socket).
//!
//! Contract:
//! - The flags and environment are `dial`'s (`--deadline-ms`, `--cloud-api`
//!   or `CMUX_CLOUD_API_URL`, `--cloud-token-file` or
//!   `CMUX_CLOUD_ACCESS_TOKEN`, `--team` or `CMUX_CLOUD_TEAM`), plus
//!   `--socket`: an absolute path that fits a Unix socket address, in a
//!   directory only this user can write.
//! - The socket is claimed like a daemon's: a live socket or any other file
//!   at the path is refused, a stale socket (nothing accepts on it) is
//!   replaced, and the new one is 0600. A `<path>.lock` sibling leases the
//!   path while it serves.
//! - Once listening, stderr gets one JSON line,
//!   `{"ok":true,"socket":PATH,"route":"carrier"}`. A failure before that
//!   writes `dial`'s failure line instead and exits: 64 bad usage or a path
//!   that cannot be claimed (a live listener, a file that is not a socket),
//!   2 no API or credential, 5 no device key.
//! - After the ready line, stderr gets one JSON line per accepted
//!   connection, written before any of its bytes flow:
//!   `{"ok":true,"route":"carrier","vmk"?:"owner"|"team"}` when its dial
//!   connected (`vmk` from the grant's claim, left out when it has none), or
//!   `dial`'s failure line
//!   (`{"ok":false,"error_code":…,"error_detail"?:…,"route":"carrier"}`, with
//!   `dial`'s codes `ticket`, `relay`, `parked_timeout`, `handshake`) when it
//!   did not. Besides those, only one `bad_request` line per stdin line it
//!   could not use, and one `socket` line if the listener fails for good.
//!   No line holds the text `cloud.connect`.
//! - stdin carries JSON lines: `{"access_token":"…"}` replaces the
//!   credential for every later dial (and ticket refresh); sessions already
//!   up stay up. `{"carrier_answer":{relay, slot, ticket, expires_at, grant,
//!   daemon_key?}}` (a create's or spare claim's `carrier`) is used by the
//!   next accepted connection's first attempt instead of asking the platform
//!   (see `dial --answer-fd`); a later one replaces one no connection took.
//!   Blank lines are skipped; any other line is refused with one
//!   `bad_request` line and changes nothing.
//! - Each accepted connection gets its own dial, exactly `dial`'s: a fresh
//!   grant, the required daemon key pin, its own deadline (default 180 s)
//!   from the accept, its own session. Connected, the connection carries
//!   what a local daemon socket does: `cmux.protocol/2` lines on the
//!   session's mux control service. A failed dial closes that connection
//!   having written nothing; the listener keeps serving. At most
//!   [`MAX_CONNECTIONS`] are served at once; one past that is closed.
//! - Route lines go only to `<workspace state dir>/carrier/connect.log`, in
//!   `dial`'s format: stderr gets none.
//! - It exits 0 when stdin ends (whoever spawned it holds the other end)
//!   or on SIGTERM or SIGINT, and 6 if accepting fails for good. Every exit
//!   after the bind removes the socket; open sessions are closed on the way
//!   out.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::crypto::StaticIdentity;
use cmux_remote::unix_socket::{OwnedUnixListener, UnixAcceptBackoff};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _};
use tokio::net::UnixStream;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};
use tokio::task::JoinSet;
use tokio::time::Instant;
use zeroize::Zeroizing;

use super::answer::{CarrierSource, HttpSource, Prefetched};
use super::contract::{self, BAD_REQUEST, MAX_STDIN_LINE, SOCKET, SOCKET_EXIT, StdinLine};
use super::{STDIO_SHUTDOWN_TIMEOUT, ServeArgs, client, reply, route_log};

/// Connections served at once.
pub(super) const MAX_CONNECTIONS: usize = 64;
/// How long open sessions get to close once the listener stops.
const DRAIN_TIMEOUT: Duration = Duration::from_secs(2);
const USAGE: &str = "usage: cmux carrier serve --machine vm_… --socket /absolute/path [--deadline-ms N] [--cloud-api URL] [--cloud-token-file PATH] [--team team_…]";

/// What every connection's dial shares.
struct Shared {
    machine: String,
    deadline: Duration,
    source: Arc<dyn CarrierSource>,
    /// The same source, for stdin's credential lines.
    http: Arc<HttpSource>,
    identity: StaticIdentity,
    /// stdin's last `carrier_answer`, for the next connection's first attempt.
    prefetched: Arc<Prefetched>,
    log: Arc<dyn Fn(String) + Send + Sync>,
}

/// `cmux carrier serve …`: the exit code.
pub(super) fn run(args: &[String]) -> i32 {
    let Some(ServeArgs { dial, socket }) = super::parse_serve(args) else {
        return super::usage(USAGE);
    };
    let (dial, source, identity) = match super::prepare(dial) {
        Ok(prepared) => prepared,
        Err(code) => return code,
    };
    let runtime = match super::runtime() {
        Ok(runtime) => runtime,
        Err(code) => return code,
    };
    let connect_log = route_log::default_path();
    let shared = Arc::new(Shared {
        machine: dial.machine,
        deadline: dial.deadline,
        source: source.clone(),
        http: source,
        identity,
        prefetched: Arc::new(Prefetched::default()),
        log: Arc::new(move |line| {
            if let Some(path) = &connect_log {
                route_log::append(path, &line);
            }
        }),
    });
    let code = runtime.block_on(serve(socket, shared));
    runtime.shutdown_timeout(STDIO_SHUTDOWN_TIMEOUT);
    code
}

async fn serve(socket: PathBuf, shared: Arc<Shared>) -> i32 {
    let listener = match OwnedUnixListener::bind(socket.clone()).await {
        Ok(listener) => listener,
        Err(error) => return super::usage(&error.to_string()),
    };
    reply(&contract::serving_line(&socket.to_string_lossy()));
    let (stop, stopped) = watch::channel(false);
    let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    let mut tasks = JoinSet::new();
    let mut backoff = UnixAcceptBackoff::new();
    let ended = ended(shared.clone());
    tokio::pin!(ended);
    let code = loop {
        tokio::select! {
            () = &mut ended => break 0,
            Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
            accepted = listener.listener().accept() => match accepted {
                Ok((stream, _)) => {
                    backoff.reset();
                    // One past the cap is closed at once.
                    if let Ok(permit) = permits.clone().try_acquire_owned() {
                        tasks.spawn(connection(stream, shared.clone(), stopped.clone(), permit));
                    }
                }
                Err(error) => match backoff.retry_delay(&error) {
                    Some(delay) => tokio::time::sleep(delay).await,
                    None => {
                        reply(&contract::failure_line(SOCKET, Some(&error.to_string())));
                        break SOCKET_EXIT;
                    }
                },
            },
        }
    };
    let _ = listener.cleanup().unlink();
    let _ = stop.send(true);
    let _ =
        tokio::time::timeout(DRAIN_TIMEOUT, async { while tasks.join_next().await.is_some() {} })
            .await;
    tasks.abort_all();
    code
}

/// Ends when stdin ends or fails, or on SIGTERM or SIGINT. Until then each
/// stdin line is read as a credential or a carrier answer for later dials.
async fn ended(shared: Arc<Shared>) {
    use tokio::signal::unix::{SignalKind, signal};
    async fn on(kind: SignalKind) {
        match signal(kind) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_) => std::future::pending().await,
        }
    }
    tokio::select! {
        () = read_stdin(&shared) => {}
        () = on(SignalKind::terminate()) => {}
        () = on(SignalKind::interrupt()) => {}
    }
}

/// Applies stdin's lines until it ends or fails: `{"access_token":"…"}`
/// replaces the credential of later dials (sessions already up keep
/// theirs); `{"carrier_answer":{…}}` is the next connection's first attempt
/// (in place of an earlier one no connection took); anything else gets one
/// `bad_request` line on stderr. A line past [`MAX_STDIN_LINE`] bytes is
/// skipped to its end and refused.
async fn read_stdin(shared: &Shared) {
    let mut stdin = tokio::io::BufReader::new(tokio::io::stdin());
    let mut line = Zeroizing::new(Vec::new());
    loop {
        line.clear();
        let limit = (MAX_STDIN_LINE + 1) as u64;
        match (&mut stdin).take(limit).read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let complete = line.last() == Some(&b'\n');
        if !complete && line.len() > MAX_STDIN_LINE {
            // The rest of an overlong line, up to its newline.
            loop {
                line.clear();
                match (&mut stdin).take(limit).read_until(b'\n', &mut line).await {
                    Ok(0) | Err(_) => return,
                    Ok(_) if line.last() == Some(&b'\n') => break,
                    Ok(_) => {}
                }
            }
            reply(&contract::failure_line(BAD_REQUEST, Some("a stdin line is too long")));
            continue;
        }
        let text = line.strip_suffix(b"\n").unwrap_or(&line[..]);
        match contract::stdin_line(text) {
            StdinLine::Blank => {}
            StdinLine::Token(token) => shared.http.replace_credential(token),
            StdinLine::Answer(answer) => shared.prefetched.put(*answer),
            StdinLine::Invalid(why) => reply(&contract::failure_line(BAD_REQUEST, Some(why))),
        }
    }
}

/// One accepted connection: its own dial, then its bytes bridged to the
/// session's mux control stream until either side ends or serve stops. A
/// connected dial writes its ok line on stderr first; a failed one writes
/// its failure line and drops the stream, so the caller reads end of
/// stream.
async fn connection(
    stream: UnixStream,
    shared: Arc<Shared>,
    mut stopped: watch::Receiver<bool>,
    _permit: OwnedSemaphorePermit,
) {
    let plan = client::DialPlan {
        machine: shared.machine.clone(),
        source: shared.source.clone(),
        identity: shared.identity.clone(),
        deadline: Instant::now() + shared.deadline,
        prefetched: shared.prefetched.clone(),
        log: shared.log.clone(),
    };
    let dialed = tokio::select! {
        dialed = client::dial(&plan, super::jitter) => dialed,
        _ = stopped.wait_for(|stopped| *stopped) => return,
    };
    let client::Dialed { connection, multiplexer, mux, vmk } = match dialed {
        Ok(dialed) => dialed,
        Err(failure) => {
            reply(&contract::failure_line(failure.step.error_code(), Some(&failure.detail)));
            return;
        }
    };
    reply(&contract::served_line(vmk));
    let (reader, writer) = stream.into_split();
    tokio::select! {
        _ = mux.bridge(reader, writer) => {}
        _ = stopped.wait_for(|stopped| *stopped) => {}
    }
    multiplexer.shutdown().await;
    let _ = connection.close().await;
}
