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
//!   `{"ok":true,"socket":PATH,"route":"carrier"}`, and nothing after it. A
//!   failure before that writes `dial`'s failure line instead and exits:
//!   64 bad usage, 2 no API or credential, 5 no device key, 6 `socket` (the
//!   path could not be claimed).
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
//!   or on SIGTERM or SIGINT, removing the socket. It exits 6 if accepting
//!   fails for good. Open sessions are closed on the way out.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::crypto::StaticIdentity;
use cmux_remote::unix_socket::{OwnedUnixListener, UnixAcceptBackoff};
use tokio::io::AsyncReadExt as _;
use tokio::net::UnixStream;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};
use tokio::task::JoinSet;
use tokio::time::Instant;

use super::answer::CarrierSource;
use super::contract::{self, SOCKET, SOCKET_EXIT};
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
    identity: StaticIdentity,
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
        source,
        identity,
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
        Err(error) => {
            reply(&contract::failure_line(SOCKET, Some(&error.to_string())));
            return SOCKET_EXIT;
        }
    };
    reply(&contract::serving_line(&socket.to_string_lossy()));
    let (stop, stopped) = watch::channel(false);
    let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    let mut tasks = JoinSet::new();
    let mut backoff = UnixAcceptBackoff::new();
    let ended = ended();
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
                    None => break SOCKET_EXIT,
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

/// Ends when stdin ends or fails, or on SIGTERM or SIGINT.
async fn ended() {
    use tokio::signal::unix::{SignalKind, signal};
    async fn on(kind: SignalKind) {
        match signal(kind) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_) => std::future::pending().await,
        }
    }
    let stdin = async {
        let mut stdin = tokio::io::stdin();
        let mut sink = [0_u8; 512];
        while let Ok(1..) = stdin.read(&mut sink).await {}
    };
    tokio::select! {
        () = stdin => {}
        () = on(SignalKind::terminate()) => {}
        () = on(SignalKind::interrupt()) => {}
    }
}

/// One accepted connection: its own dial, then its bytes bridged to the
/// session's mux control stream until either side ends or serve stops. A
/// failed dial drops the stream, so the caller reads end of stream.
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
        log: shared.log.clone(),
    };
    let dialed = tokio::select! {
        dialed = client::dial(&plan, super::jitter) => dialed,
        _ = stopped.wait_for(|stopped| *stopped) => return,
    };
    let Ok(client::Dialed { connection, multiplexer, mux, .. }) = dialed else { return };
    let (reader, writer) = stream.into_split();
    tokio::select! {
        _ = mux.bridge(reader, writer) => {}
        _ = stopped.wait_for(|stopped| *stopped) => {}
    }
    multiplexer.shutdown().await;
    let _ = connection.close().await;
}
