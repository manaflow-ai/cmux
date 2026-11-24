//! A route's bytes through this person's own carrier to another of their machines
//! (`cmux remote exec|cp|connect --via-machine M`): no inbound port, no ssh, no tailnet.
//!
//! The dialer connects to this machine's acpmux socket and asks, as the connection's first line,
//! for a pipe to machine M's cmux-tui remote daemon (`_acpmux/remote.pipe`, acpmux
//! `cmux_tui_service.rs`). acpmux dials M over its hub carrier, naming that service; M bridges
//! the circuit to its daemon's loopback listener only when its owner named that daemon and
//! granted control. After the one reply line the socket carries the circuit's bytes, and the
//! WebSocket upgrade and the cmux Noise handshake run above it as over TCP: the route still
//! names the daemon (`ws://127.0.0.1:PORT/...` on M), and only a device M's daemon enrolled gets
//! in.

use std::path::PathBuf;
use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt as _;
use futures_util::stream::FuturesUnordered;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;

use super::dial::{DialedStream, Dialer};
use crate::link::LinkError;

/// The acpmux method whose request, as a connection's first line, makes it a pipe.
pub const MACHINE_PIPE_METHOD: &str = "_acpmux/remote.pipe";
/// The longest reply line read before the pipe's bytes.
const MAX_REPLY_BYTES: usize = 16 * 1024;

/// How long one pipe has alone before another is asked for beside it. A pipe is a hub circuit
/// (a ticket, a relay allocation, the far machine joining, a Noise exchange): about 1 s to a
/// machine on a good uplink, 2 to 8 s to a Mac on a slow one, and now and then 12 s or a join that
/// never comes, while the next circuit to the same machine opens in the usual time.
const PIPE_STAGGER: Duration = Duration::from_secs(3);
/// Pipes asked for in one dial, at most; the caller's connect stage bounds the dial as a whole.
const PIPE_ATTEMPTS: usize = 3;

/// Dials a loopback route on `machine` through the acpmux daemon at `socket`.
#[derive(Debug, Clone)]
pub struct MachinePipeDialer {
    socket: PathBuf,
    machine: String,
    stagger: Duration,
}

impl MachinePipeDialer {
    /// `machine`: an acpmux peer name or the machine's node key (`wgPublicKey`).
    pub fn new(socket: PathBuf, machine: String) -> Self {
        Self { socket, machine, stagger: PIPE_STAGGER }
    }

    #[cfg(test)]
    fn with_stagger(mut self, stagger: Duration) -> Self {
        self.stagger = stagger;
        self
    }

    /// One pipe: the request line, the reply line, then the circuit's bytes.
    async fn open_pipe(&self, port: u16) -> Result<UnixStream, LinkError> {
        let mut stream = UnixStream::connect(&self.socket).await.map_err(|error| {
            LinkError::Transport(format!(
                "acpmux is not running at {}: {error}",
                self.socket.display()
            ))
        })?;
        stream
            .write_all(machine_pipe_request(&self.machine, port).as_bytes())
            .await
            .map_err(|error| LinkError::Transport(error.to_string()))?;
        // One byte at a time: nothing past the newline may be read, it is the daemon's.
        let mut line = Vec::new();
        loop {
            let byte = stream.read_u8().await.map_err(|_| {
                LinkError::Transport("acpmux closed the pipe before answering".into())
            })?;
            if byte == b'\n' {
                break;
            }
            if line.len() == MAX_REPLY_BYTES {
                return Err(LinkError::Protocol("acpmux's pipe reply is too long".into()));
            }
            line.push(byte);
        }
        machine_pipe_reply(&line)?;
        Ok(stream)
    }
}

/// Whether `host` names this machine's loopback, the only place the far end bridges to.
fn loopback_host(host: &str) -> bool {
    let bare = host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host);
    bare.eq_ignore_ascii_case("localhost")
        || bare.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// The pipe request line for `machine`'s daemon on `port`.
pub fn machine_pipe_request(machine: &str, port: u16) -> String {
    let request = json!({
        "jsonrpc": "2.0", "id": 1, "method": MACHINE_PIPE_METHOD,
        "params": {"machine": machine, "port": port},
    });
    format!("{request}\n")
}

/// The reasons a pipe is refused that no redial cures: each needs a person to act (on that
/// machine or in this command), so redialing only hides it. Anything else (`machine.unreachable`:
/// the relay or the far slot is not there yet; `service.unreachable`: the far daemon is not
/// listening, as while it restarts; `carrier.off` while this daemon's carrier starts;
/// `machine.unlisted`/`service.unknown_machine` until the far machine's book lists this one; a
/// reason this CLI does not know) is redialed.
///
/// - `consent_required`, `consent_declined`: the far machine's owner has not granted control
///   from elsewhere; only they can, there.
/// - `service.off`: the far machine serves no remote daemon to its other machines; its owner
///   names one (`acpmux config --set remote_daemon=...`).
/// - `service.misconfigured`: the far machine's configured daemon address is not loopback.
/// - `service.port`: the route names another port than the one the far machine serves.
/// - `service.unknown`, `service.bad_answer`: the far side does not speak this service (a
///   version apart).
/// - `machine.unknown`: this machine has no route to the machine named.
/// - `machine.not_joined`: the hub does not know the machine named (its 404 `machine.not_found`
///   on the connect ticket); it joins the hub there (`cmux machine add`, or signing in to the
///   app), and no redial here changes that.
/// - `machine.self`: the machine named is this one; the hub carries only between two machines.
/// - `carrier.not_serving`: the far machine's hub carrier is off (the hub has none registered for
///   it, or it never joined); its owner updates or restarts acpmux there, and a redial only waits
///   out the command's own timeout.
pub const TERMINAL_REFUSALS: &[&str] = &[
    "consent_required",
    "consent_declined",
    "service.off",
    "service.misconfigured",
    "service.port",
    "service.unknown",
    "service.bad_answer",
    "machine.unknown",
    "machine.not_joined",
    "machine.self",
    "carrier.not_serving",
];

/// The reason the local daemon gives for any failed dial; the far machine's own reason, when it
/// refused, ends the message as ` (reason)` on a daemon that does not send it apart.
const GENERIC_REASON: &str = "machine.unreachable";

/// `message`'s trailing ` (reason)`, split off, when it ends with a reason code.
fn trailing_reason(message: &str) -> Option<(&str, &str)> {
    let (text, reason) = message.strip_suffix(')')?.rsplit_once(" (")?;
    let code = !reason.is_empty()
        && reason.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._".contains(c));
    code.then_some((text, reason))
}

/// The reply line read back: Ok when the pipe is open, else the daemon's error and reason. A
/// reason in [`TERMINAL_REFUSALS`] is a [`LinkError::Refused`], which ends the dial; any other
/// failure is a transport failure, which is redialed.
pub fn machine_pipe_reply(line: &[u8]) -> Result<(), LinkError> {
    let reply: Value = serde_json::from_slice(line)
        .map_err(|_| LinkError::Protocol("acpmux sent no pipe reply".into()))?;
    if reply.get("result").is_some() {
        return Ok(());
    }
    let error = reply.get("error").cloned().unwrap_or(Value::Null);
    let message = error.get("message").and_then(Value::as_str).unwrap_or("the pipe was refused");
    let reason = error.pointer("/data/reason").and_then(Value::as_str);
    // The far machine's reason, where the local daemon folded it into its message.
    let (message, reason) = match (reason, trailing_reason(message)) {
        (None | Some(GENERIC_REASON), Some((text, far))) => (text, Some(far)),
        _ => (message, reason),
    };
    match reason {
        Some(reason) if TERMINAL_REFUSALS.contains(&reason) => {
            Err(LinkError::Refused(crate::link::Refusal {
                reason: reason.to_owned(),
                message: message.to_owned(),
            }))
        }
        Some(reason) => Err(LinkError::Transport(format!("{message} ({reason})"))),
        None => Err(LinkError::Transport(message.to_owned())),
    }
}

#[async_trait]
impl Dialer for MachinePipeDialer {
    fn name(&self) -> &'static str {
        "machine"
    }

    /// One link for every lane: each dial is a hub circuit of its own (a ticket, a relay
    /// allocation, the far machine joining, a Noise exchange, then the route's WebSocket and
    /// Noise), all through the same relay and the same far uplink, so links of their own buy no
    /// separate path. Measured to a Mac on a slow uplink, 2 to 8 s each: the first connect's three
    /// circuits (the second and third after the first) outran the 15 s attempt and started over,
    /// and a slow join on any one of them ended the whole connect.
    fn parallel_links(&self) -> bool {
        false
    }

    async fn dial(&self, host: &str, port: u16) -> Result<DialedStream, LinkError> {
        if !loopback_host(host) {
            // Not redialed: no redial makes this route reachable this way.
            return Err(LinkError::Protocol(format!(
                "a route through another machine names that machine's loopback daemon \
                 (ws://127.0.0.1:PORT), not {host}"
            )));
        }
        // A slow circuit is not a sign of the next one: ask for another beside it every
        // `stagger` while none has answered, and keep the first that opens. The ones still
        // pending are dropped, which closes their sockets and the circuits behind them. A failure
        // ends the dial only once nothing else is in flight; a transport failure with nothing in
        // flight asks again at once, and a refusal (one no redial cures) is the answer.
        let mut pending = FuturesUnordered::new();
        let mut asked = 0_usize;
        let mut next = tokio::time::Instant::now();
        loop {
            if asked < PIPE_ATTEMPTS && tokio::time::Instant::now() >= next {
                pending.push(self.open_pipe(port));
                asked += 1;
                next = tokio::time::Instant::now() + self.stagger;
            }
            let may_ask = asked < PIPE_ATTEMPTS;
            tokio::select! {
                biased;
                Some(result) = pending.next() => match result {
                    Ok(stream) => return Ok(Box::new(stream)),
                    Err(error) if !pending.is_empty() => drop(error),
                    Err(error) if error.refusal().is_some() || !may_ask => return Err(error),
                    Err(_) => next = tokio::time::Instant::now(),
                },
                () = tokio::time::sleep_until(next), if may_ask => {}
                else => {
                    return Err(LinkError::Transport("acpmux opened no pipe".into()));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncBufReadExt as _;

    #[test]
    fn only_loopback_routes_go_through_a_machine() {
        for host in ["127.0.0.1", "[::1]", "::1", "localhost", "127.0.0.2"] {
            assert!(loopback_host(host), "{host}");
        }
        for host in ["10.0.0.1", "example.com", "[fd7a::10]"] {
            assert!(!loopback_host(host), "{host}");
        }
    }

    #[test]
    fn a_refusal_says_why() {
        let refused = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"this machine's owner has not granted control from elsewhere (consent_required)","data":{"reason":"machine.unreachable"}}}"#;
        let refusal = crate::link::Refusal {
            reason: "consent_required".into(),
            message: "this machine's owner has not granted control from elsewhere".into(),
        };
        let error = machine_pipe_reply(refused).unwrap_err();
        assert_eq!(error.refusal(), Some(&refusal), "{error}");
        // A daemon that sends the far reason apart reads the same.
        let apart = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"this machine's owner has not granted control from elsewhere","data":{"reason":"consent_required"}}}"#;
        assert_eq!(machine_pipe_reply(apart).unwrap_err().refusal(), Some(&refusal));
        assert!(machine_pipe_reply(br#"{"jsonrpc":"2.0","id":1,"result":{"via":"hub"}}"#).is_ok());
        assert!(machine_pipe_reply(b"not json").is_err());
    }

    /// Only a reason no redial cures ends the dial; a transient one stays a transport failure,
    /// which the caller redials.
    #[test]
    fn only_a_terminal_reason_ends_the_dial() {
        let reply = |message: &str, reason: &str| {
            json!({"jsonrpc": "2.0", "id": 1, "error": {
                "code": -32000, "message": message, "data": {"reason": reason},
            }})
            .to_string()
        };
        for (message, reason) in [
            (
                "the cmux-tui remote daemon at 127.0.0.1:7781 is not listening",
                "service.unreachable",
            ),
            ("relay connect failed: the relay did not answer", "machine.unreachable"),
            ("connect failed: connection refused (os error 111)", "machine.unreachable"),
            ("the hub carrier is off", "carrier.off"),
            ("not listed yet (machine.unlisted)", "machine.unreachable"),
            ("something new", "some.future_reason"),
        ] {
            let error = machine_pipe_reply(reply(message, reason).as_bytes()).unwrap_err();
            assert!(matches!(error, LinkError::Transport(_)), "{message}: {error:?}");
        }
        for reason in TERMINAL_REFUSALS {
            let error = machine_pipe_reply(reply("no", reason).as_bytes()).unwrap_err();
            assert_eq!(error.refusal().map(|r| r.reason.as_str()), Some(*reason));
            let folded = format!("no ({reason})");
            let error =
                machine_pipe_reply(reply(&folded, "machine.unreachable").as_bytes()).unwrap_err();
            assert_eq!(error.refusal().map(|r| r.message.as_str()), Some("no"), "{reason}");
        }
    }

    /// A fake acpmux at a fresh socket: connection `n` (from 0) reads its request line, waits
    /// `plan(n).0`, then answers `plan(n).1` (None: holds the connection without answering).
    /// Answers the socket and how many pipes were asked for.
    fn fake_acpmux(
        plan: fn(usize) -> (Duration, Option<&'static str>),
    ) -> (tempfile::TempDir, PathBuf, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("acpmux.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let asked = std::sync::Arc::new(AtomicUsize::new(0));
        let count = asked.clone();
        tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let n = count.fetch_add(1, Ordering::SeqCst);
                tokio::spawn(async move {
                    let mut stream = tokio::io::BufReader::new(stream);
                    let mut request = String::new();
                    stream.read_line(&mut request).await.unwrap();
                    let (wait, answer) = plan(n);
                    tokio::time::sleep(wait).await;
                    let mut stream = stream.into_inner();
                    match answer {
                        Some(line) => {
                            let _ = stream.write_all(format!("{line}\n").as_bytes()).await;
                            let _ = stream.read(&mut [0u8; 1]).await;
                        }
                        None => std::future::pending::<()>().await,
                    }
                });
            }
        });
        (dir, socket, asked)
    }

    const OPENED: &str = r#"{"jsonrpc":"2.0","id":1,"result":{"via":"hub"}}"#;
    const NOT_SERVING: &str = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"that machine's hub carrier is off (it did not answer on the relay within 6s)","data":{"reason":"carrier.not_serving"}}}"#;
    const NO_CONSENT: &str = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"no","data":{"reason":"consent_required"}}}"#;

    /// A pipe whose circuit is slow does not hold the dial: another one asked for beside it
    /// opens in the usual time (to a Mac on a slow uplink one circuit in a few took 12 s, the
    /// dial's whole connect stage, while the next opened in 5 s).
    #[tokio::test]
    async fn a_slow_pipe_does_not_hold_the_dial() {
        use std::sync::atomic::Ordering;
        let (_dir, socket, asked) = fake_acpmux(|n| {
            if n == 0 { (Duration::ZERO, None) } else { (Duration::ZERO, Some(OPENED)) }
        });
        let dialer =
            MachinePipeDialer::new(socket, "mac".into()).with_stagger(Duration::from_millis(50));
        tokio::time::timeout(Duration::from_secs(5), dialer.dial("127.0.0.1", 7781))
            .await
            .expect("the dial waited on the slow pipe")
            .unwrap();
        assert_eq!(asked.load(Ordering::SeqCst), 2);
    }

    /// One circuit's slow join (`carrier.not_serving`) does not end the dial while another pipe
    /// may still open; it was a refusal no redial cures, which ended the whole first connect.
    #[tokio::test]
    async fn one_pipe_refused_while_another_is_in_flight_is_not_the_answer() {
        let (_dir, socket, _) = fake_acpmux(|n| match n {
            0 => (Duration::from_millis(100), Some(NOT_SERVING)),
            _ => (Duration::from_millis(200), Some(OPENED)),
        });
        let dialer =
            MachinePipeDialer::new(socket, "mac".into()).with_stagger(Duration::from_millis(50));
        tokio::time::timeout(Duration::from_secs(5), dialer.dial("127.0.0.1", 7781))
            .await
            .expect("the dial hung")
            .unwrap();
    }

    /// A refusal with nothing else in flight is the answer at once, with its reason: it asks
    /// no more pipes, and does not wait for the next stagger.
    #[tokio::test]
    async fn a_refusal_with_nothing_in_flight_ends_the_dial() {
        use std::sync::atomic::Ordering;
        let (_dir, socket, asked) = fake_acpmux(|_| (Duration::ZERO, Some(NO_CONSENT)));
        let dialer =
            MachinePipeDialer::new(socket, "mac".into()).with_stagger(Duration::from_secs(60));
        let error = tokio::time::timeout(Duration::from_secs(5), dialer.dial("127.0.0.1", 7781))
            .await
            .expect("the refusal waited for the next stagger")
            .err()
            .expect("a refused pipe opened");
        assert_eq!(error.refusal().map(|r| r.reason.as_str()), Some("consent_required"));
        assert_eq!(asked.load(Ordering::SeqCst), 1);
    }

    /// A route through another machine makes one link for every lane: each link is a hub
    /// circuit of its own, and the first connect waited on three of them (cmux `remote exec
    /// --via-machine` to a Mac on a slow uplink: 7 to 52 s, 2 in 10 timed out at 60 s).
    #[tokio::test]
    async fn a_route_through_a_machine_dials_one_link_for_every_lane() {
        use crate::provider::{
            ConnectRequest, DirectWebSocketProvider, OsTcpDialer, TransportProvider, lane_bindings,
        };
        use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
        use std::sync::Arc;

        let bindings = |dialer: Arc<dyn Dialer>| async move {
            let request = ConnectRequest {
                endpoint: url::Url::parse("ws://127.0.0.1:7781/v1/link").unwrap(),
                session: SessionId([7; 16]),
                lane_policy: LanePolicy::Auto,
                routing: Default::default(),
            };
            let group = DirectWebSocketProvider::with_dialer(1 << 20, dialer)
                .connect(request)
                .await
                .unwrap();
            lane_bindings(LanePolicy::Auto, group.capabilities())
        };
        let machine = MachinePipeDialer::new("/nonexistent/acpmux.sock".into(), "mac".into());
        assert_eq!(bindings(Arc::new(machine)).await, vec![Lane::ALL.to_vec()]);
        // A direct WebSocket keeps a link per lane group.
        assert_eq!(bindings(Arc::new(OsTcpDialer)).await.len(), 3);
    }

    /// The dialer asks once, reads exactly the reply line, and hands back the rest of the
    /// connection: the first byte after the reply is the pipe's.
    #[tokio::test]
    async fn the_dial_returns_the_connection_after_the_reply_line() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("acpmux.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = tokio::io::BufReader::new(stream);
            let mut request = String::new();
            stream.read_line(&mut request).await.unwrap();
            let mut stream = stream.into_inner();
            stream
                .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"via\":\"hub\"}}\nX")
                .await
                .unwrap();
            let mut echo = [0u8; 4];
            stream.read_exact(&mut echo).await.unwrap();
            stream.write_all(&echo).await.unwrap();
            request
        });
        let dialer = MachinePipeDialer::new(socket, "mac".into());
        let mut stream = dialer.dial("127.0.0.1", 7781).await.unwrap();
        let mut first = [0u8; 1];
        stream.read_exact(&mut first).await.unwrap();
        assert_eq!(&first, b"X");
        stream.write_all(b"ping").await.unwrap();
        let mut echo = [0u8; 4];
        stream.read_exact(&mut echo).await.unwrap();
        assert_eq!(&echo, b"ping");
        let request: Value = serde_json::from_str(&server.await.unwrap()).unwrap();
        assert_eq!(request["method"], MACHINE_PIPE_METHOD);
        assert_eq!(request["params"], json!({"machine": "mac", "port": 7781}));
        assert!(dialer.dial("10.0.0.1", 7781).await.is_err());
    }
}
