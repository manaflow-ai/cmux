//! The hand's one outbound socket: `wss://<api>/v1/hands/<id>/socket` with
//! `Authorization: Bearer <key>`.
//!
//! Frames are JSON text:
//!   Cloud -> hand  {"t":"req","id","action","params"}        a request
//!                  {"t":"approval","id","allow"}             the owner's answer to an `approve`
//!   hand -> Cloud  {"t":"hello", ...}                        once per connection
//!                  {"t":"res","id","ok":true,"value"} | {"t":"res","id","ok":false,"error"}
//!                  {"t":"approve","id","req","summary"}      mac profile: ask the owner
//!                  {"t":"event","session","seq","event"}     agent session events
//! Requests run at the same time; each answer names its request id.
//! A dropped socket reconnects with backoff; agent sessions keep running
//! in the acpmux daemon, and their events can be paged with agent.events.

use super::agent::{Agents, HARNESSES};
use super::config::HandConfig;
use super::requests::{Ctx, handle};
use super::{HandError, pair};
use anyhow::Result;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message as Ws;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

/// How long an owner approval may take before the request is refused.
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(600);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
const KEEPALIVE: Duration = Duration::from_secs(30);
const KEEPALIVE_DEAD: Duration = Duration::from_secs(95);
/// Close codes the Cloud uses when the key is wrong or the hand was removed.
const CLOSE_REVOKED: [u16; 2] = [4401, 4403];

type Approvals = Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>;

fn socket_url(cfg: &HandConfig) -> String {
    let ws = cfg.api.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    format!("{ws}/v1/hands/{}/socket", cfg.hand)
}

pub async fn run(cfg: HandConfig) -> Result<()> {
    // First: every acpmux path below (gateway routes, the agent daemon) is the hand's own.
    super::daemon::use_hand_home()?;
    // The hand holds a person key in memory: no same-uid agent may read it (Linux).
    #[cfg(unix)]
    if let Err(e) = crate::daemon::not_dumpable() {
        anyhow::bail!("the hand cannot protect its person key: {e}");
    }
    pair::check_api(&cfg.api)?;
    // A sandbox starts its agent daemon now, so the first agent.start does not wait for it (about 1.3 s).
    if cfg.profile == super::config::Profile::Sandbox {
        tokio::spawn(async {
            let _ = super::daemon::connect().await;
        });
    }
    // One running hand per hand home: a second copy (a service plus a manual
    // run) would take turns replacing each other's socket.
    let _lock = single_instance()?;
    // One-run gateway routes whose token expired while the hand was down.
    super::gateway::sweep().await;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let cfg = Arc::new(cfg);
    let agents = Agents::default();
    // Outbound frames survive a reconnect: events queue here while offline.
    let (out_tx, mut out_rx) = mpsc::channel::<Value>(4096);
    // Pending owner approvals outlive a reconnect: the answer may come on the next socket.
    let approvals: Approvals = Arc::default();
    // The hand's agents run on its own keyed acpmux daemon (daemon.rs), so its
    // connection is the proven person that answers their permission prompts.
    agents.set_ask(owner_ask(&out_tx, &approvals));
    // The idle stops live as long as this run: the set aborts them when `run` returns.
    let mut background = tokio::task::JoinSet::new();
    let idle = agents.clone();
    background.spawn(async move { idle.run_idle_stops().await });
    let mut backoff = Duration::from_secs(1);
    loop {
        let mut connected = false;
        let ended = serve(&cfg, &agents, &approvals, &out_tx, &mut out_rx, &mut connected).await;
        // A link that came up starts the backoff again (a long-lived hand does not drift to the maximum).
        if connected && !matches!(ended, Err(Ended::Revoked(_))) {
            backoff = Duration::from_secs(1);
        }
        match ended {
            Ok(()) => backoff = Duration::from_secs(1),
            Err(Ended::Revoked(code)) => {
                eprintln!(
                    "hand: the Cloud refused this hand (close {code}: a removed hand, a wrong key or a profile that does not match its pairing); pair it again. Retrying in 10 min."
                );
                backoff = Duration::from_secs(600);
            }
            Err(Ended::Failed(e)) => {
                eprintln!("hand: connection failed: {e}");
            }
            Err(Ended::Resumed) => {
                // The machine slept (a paused sandbox resumed): reconnect at once.
                eprintln!("hand: the machine was suspended; connecting again");
                continue;
            }
        }
        // A bounded, intentional delay between reconnects (not synchronization).
        // wakeup-allow: backoff the doubling reconnect delay (1 to 60 s, 10 min after a refusal)
        // after the socket ended
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF).max(Duration::from_secs(1));
    }
}

/// An agent's permission prompt goes to the owner as an `approve` frame (the
/// Cloud approval flow); no answer before APPROVAL_TIMEOUT is a refusal.
fn owner_ask(out: &mpsc::Sender<Value>, approvals: &Approvals) -> super::agent::Ask {
    let (out, approvals) = (out.clone(), approvals.clone());
    Arc::new(move |summary: Value| {
        let (out, approvals) = (out.clone(), approvals.clone());
        Box::pin(async move {
            let aid = uuid::Uuid::now_v7().to_string();
            let (tx, rx) = oneshot::channel();
            approvals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(aid.clone(), tx);
            let req = summary.get("session").cloned().unwrap_or(Value::Null);
            if out
                .send(json!({ "t": "approve", "id": aid, "req": req, "summary": summary }))
                .await
                .is_err()
            {
                return false;
            }
            match tokio::time::timeout(APPROVAL_TIMEOUT, rx).await {
                Ok(Ok(allow)) => allow,
                _ => {
                    approvals
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .remove(&aid);
                    // The Cloud closes the row: a later answer would change nothing here.
                    let _ = out.send(json!({ "t": "approval-expired", "id": aid })).await;
                    false
                }
            }
        })
    })
}

/// An exclusive lock on `<hand home>/hand.lock`, held for the process life.
fn single_instance() -> Result<std::fs::File> {
    let path = super::config::home().join("hand.lock");
    let file = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(&path)?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            anyhow::bail!(
                "another cmux-hand already runs for {} (lock {})",
                super::config::home().display(),
                path.display()
            );
        }
    }
    Ok(file)
}

enum Ended {
    Revoked(u16),
    Failed(String),
    /// The wall clock jumped while the process did not run (the machine was paused): the socket
    /// is gone even when the network did not say so.
    Resumed,
}

/// How far the wall clock may run ahead of the monotonic clock between two wakes of the link
/// before it counts as a suspend.
const SUSPEND_JUMP: Duration = Duration::from_secs(10);

/// Tells a suspend from the two clocks: the monotonic clock stops while a VM is paused, the
/// wall clock does not. Read at each wake the link has anyway (a keepalive, a frame in or
/// out), so it costs no wake of its own; a resumed machine is seen at the next of them.
struct SuspendWatch {
    wall: std::time::SystemTime,
    mono: tokio::time::Instant,
}

impl SuspendWatch {
    fn new(wall: std::time::SystemTime, mono: tokio::time::Instant) -> Self {
        Self { wall, mono }
    }

    /// Whether the wall clock ran more than `SUSPEND_JUMP` ahead of the monotonic clock
    /// since the last read. A wall clock set back counts as no suspend.
    fn resumed(&mut self, wall: std::time::SystemTime, mono: tokio::time::Instant) -> bool {
        let wall_gap = wall.duration_since(self.wall).unwrap_or_default();
        let mono_gap = mono.saturating_duration_since(self.mono);
        (self.wall, self.mono) = (wall, mono);
        wall_gap.saturating_sub(mono_gap) > SUSPEND_JUMP
    }

    fn resumed_now(&mut self) -> bool {
        self.resumed(std::time::SystemTime::now(), tokio::time::Instant::now())
    }
}

async fn serve(
    cfg: &Arc<HandConfig>,
    agents: &Agents,
    approvals: &Approvals,
    out_tx: &mpsc::Sender<Value>,
    out_rx: &mut mpsc::Receiver<Value>,
    connected: &mut bool,
) -> Result<(), Ended> {
    let mut req =
        socket_url(cfg).into_client_request().map_err(|e| Ended::Failed(e.to_string()))?;
    req.headers_mut().insert(
        "authorization",
        format!("Bearer {}", cfg.key).parse().map_err(|_| Ended::Failed("bad key".into()))?,
    );
    let (ws, _) =
        match tokio::time::timeout(Duration::from_secs(20), tokio_tungstenite::connect_async(req))
            .await
        {
            Err(_) => return Err(Ended::Failed("connect timed out".into())),
            Ok(Err(e)) => {
                if let tokio_tungstenite::tungstenite::Error::Http(r) = &e {
                    let status = r.status().as_u16();
                    if matches!(status, 401 | 403) {
                        return Err(Ended::Revoked(status + 4000));
                    }
                }
                return Err(Ended::Failed(e.to_string()));
            }
            Ok(Ok(c)) => c,
        };
    eprintln!("hand: connected as {}", cfg.hand);
    let (mut sink, mut source) = ws.split();
    let hello = json!({
        "t": "hello",
        "version": crate::hub::VERSION,
        "profile": cfg.profile,
        "roots": cfg.roots,
        "agent_policy": cfg.agent_policy,
        "harnesses": HARNESSES,
        // This hand applies the permission level it gets with each request (policy.rs).
        "caps": ["levels"],
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "hostname": pair::hostname(),
    });
    sink.send(Ws::Text(hello.to_string().into()))
        .await
        .map_err(|e| Ended::Failed(e.to_string()))?;
    // Keepalive: the Cloud answers "ping" with "pong" without waking its object;
    // no pong for KEEPALIVE_DEAD means the path is gone, so reconnect.
    *connected = true;
    let mut keepalive = tokio::time::interval(KEEPALIVE);
    keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_pong = tokio::time::Instant::now();
    let mut suspend = SuspendWatch::new(std::time::SystemTime::now(), tokio::time::Instant::now());
    loop {
        tokio::select! {
            _ = keepalive.tick() => {
                if suspend.resumed_now() {
                    return Err(Ended::Resumed);
                }
                if last_pong.elapsed() > KEEPALIVE_DEAD {
                    return Err(Ended::Failed("no keepalive answer".into()));
                }
                if let Err(e) = sink.send(Ws::Text("ping".into())).await {
                    return Err(Ended::Failed(e.to_string()));
                }
            }
            frame = out_rx.recv() => {
                let Some(frame) = frame else { return Ok(()) };
                if suspend.resumed_now() {
                    // Kept for the next connection: this socket is gone with the suspend.
                    if frame["t"] == "res" || frame["t"] == "approve" { let _ = out_tx.try_send(frame); }
                    return Err(Ended::Resumed);
                }
                if let Err(e) = sink.send(Ws::Text(frame.to_string().into())).await {
                    // Keep the frame for the next connection when it is an answer.
                    if frame["t"] == "res" || frame["t"] == "approve" { let _ = out_tx.try_send(frame); }
                    return Err(Ended::Failed(e.to_string()));
                }
            }
            msg = source.next() => {
                // A frame read after a suspend came on a socket the other side may have dropped.
                if suspend.resumed_now() {
                    return Err(Ended::Resumed);
                }
                match msg {
                    None => return Err(Ended::Failed("socket closed".into())),
                    Some(Err(e)) => return Err(Ended::Failed(e.to_string())),
                    Some(Ok(Ws::Close(c))) => {
                        let code = c.as_ref().map(|c| u16::from(c.code)).unwrap_or(1000);
                        return if CLOSE_REVOKED.contains(&code) { Err(Ended::Revoked(code)) } else { Err(Ended::Failed(format!("closed {code}"))) };
                    }
                    Some(Ok(Ws::Ping(p))) => { let _ = sink.send(Ws::Pong(p)).await; }
                    Some(Ok(Ws::Text(t))) if t.as_str() == "pong" => last_pong = tokio::time::Instant::now(),
                    Some(Ok(Ws::Text(t))) => {
                        last_pong = tokio::time::Instant::now();
                        on_frame(cfg, agents, out_tx, approvals, t.as_str());
                    }
                    Some(Ok(_)) => {}
                }
            }
        }
    }
}

fn on_frame(
    cfg: &Arc<HandConfig>,
    agents: &Agents,
    out: &mpsc::Sender<Value>,
    approvals: &Approvals,
    text: &str,
) {
    let Ok(frame) = serde_json::from_str::<Value>(text) else { return };
    match frame.get("t").and_then(Value::as_str) {
        Some("approval") => {
            let id = frame.get("id").and_then(Value::as_str).unwrap_or_default();
            let allow = frame.get("allow") == Some(&Value::Bool(true));
            if let Some(tx) =
                approvals.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(id)
            {
                let _ = tx.send(allow);
            }
        }
        Some("req") => {
            let id = frame.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
            let action = frame.get("action").and_then(Value::as_str).unwrap_or_default().to_owned();
            let params = frame.get("params").cloned().unwrap_or(json!({}));
            let (cfg, agents, out, approvals) =
                (cfg.clone(), agents.clone(), out.clone(), approvals.clone());
            tokio::spawn(async move {
                let ctx = Ctx { cfg: &cfg, agents: &agents, sink: out.clone() };
                let ask_out = out.clone();
                let req_id = id.clone();
                let approve = move |summary: Value| async move {
                    let aid = uuid::Uuid::now_v7().to_string();
                    let (tx, rx) = oneshot::channel();
                    approvals
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .insert(aid.clone(), tx);
                    let q = json!({ "t": "approve", "id": aid, "req": req_id, "summary": summary });
                    if ask_out.send(q).await.is_err() {
                        return Err(HandError::new(
                            "policy.approval_unavailable",
                            "the hand is shutting down",
                        ));
                    }
                    match tokio::time::timeout(APPROVAL_TIMEOUT, rx).await {
                        Ok(Ok(allow)) => Ok(allow),
                        _ => {
                            approvals
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .remove(&aid);
                            Ok(false)
                        }
                    }
                };
                let reply = match handle(&ctx, &action, &params, approve).await {
                    Ok(value) => json!({ "t": "res", "id": id, "ok": true, "value": value }),
                    Err(e) => json!({ "t": "res", "id": id, "ok": false, "error": e.to_json() }),
                };
                let _ = out.send(reply).await;
            });
        }
        _ => {}
    }
}

#[cfg(test)]
mod suspend_tests {
    use super::{SUSPEND_JUMP, SuspendWatch};
    use std::time::{Duration, SystemTime};
    use tokio::time::Instant;

    #[test]
    fn running_clocks_are_no_suspend() {
        let (wall, mono) = (SystemTime::now(), Instant::now());
        let mut watch = SuspendWatch::new(wall, mono);
        // A keepalive 30 s later: both clocks moved alike.
        let gap = Duration::from_secs(30);
        assert!(!watch.resumed(wall + gap, mono + gap));
        // A wall clock set back is no suspend either.
        assert!(!watch.resumed(wall, mono + gap * 2));
    }

    #[test]
    fn a_wall_clock_jump_past_the_monotonic_one_ends_the_link() {
        let (wall, mono) = (SystemTime::now(), Instant::now());
        let mut watch = SuspendWatch::new(wall, mono);
        // The VM was paused for an hour: the monotonic clock moved 1 s, the wall clock an hour.
        let mono = mono + Duration::from_secs(1);
        let wall = wall + Duration::from_secs(3600);
        assert!(watch.resumed(wall, mono));
        // The next read compares from there: no second suspend.
        assert!(!watch.resumed(wall + Duration::from_secs(5), mono + Duration::from_secs(5)));
    }

    #[test]
    fn a_jump_within_the_slack_is_no_suspend() {
        let (wall, mono) = (SystemTime::now(), Instant::now());
        let mut watch = SuspendWatch::new(wall, mono);
        assert!(!watch.resumed(wall + SUSPEND_JUMP, mono));
        let mut watch = SuspendWatch::new(wall, mono);
        assert!(watch.resumed(wall + SUSPEND_JUMP + Duration::from_millis(1), mono));
    }
}
