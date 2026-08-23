//! Connected state: hello negotiation, heartbeats, trust sync, reconnect
//! with jittered exponential backoff, and the exec/PTY frame dispatch.
//! Behavior port of `stayOnline` / `relaySession` in
//! `packages/relay/bin/cmux-relay.mjs`.
//!
//! Slices 2/3: `action_request` runs the exec verbs (`actions`); the
//! `pty_*` family drives the PtyManager (`pty`). Both re-check the machine's
//! own reconciled trust locally. The PtyManager is a per-process singleton
//! held across reconnects (sessions persist; only attachments detach on a
//! socket drop). Output from spawned exec/PTY tasks rides an outbound
//! channel so the socket stays single-writer; `pending_bytes` approximates
//! the server-directed backpressure the JS relay read from `ws.bufferedAmount`.

use std::collections::HashMap;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::sync::{Mutex as AsyncMutex, Semaphore};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::actions::{ActionContext, perform_action, process_env_snapshot, scrubbed_env};
use crate::config::{Config, save_config};
use crate::error::RelayError;
use crate::pairing::websocket_url;
use crate::pty::{FrameContext, PtyManager};
use crate::trust::{
    DEFAULT_RELAY_TRUST, Trust, clear_invalid_yolo_confirmation, effective_local_trust,
    has_yolo_confirmation, relay_trust,
};
use crate::wire::{
    CLI_VERSION, EXEC_PROTOCOL_VERSION, FRAME_VERSION, HelloFrame, PTY_PROTOCOL_VERSION,
    ServerFrame, advertised_protocol, heartbeat_frame, parse_server_frame, set_trust_frame,
};

pub struct SessionState {
    pub first_connect: bool,
    pub first_run: bool,
    pub managed: bool,
}

/// The machine-side authority read at each exec/PTY dispatch: reconciled
/// trust, allowed roots, and the paired owner. Updated on hello_accepted and
/// trust_ack; never the frame's echo alone.
#[derive(Clone, Default)]
struct AuthSnapshot {
    trust: String,
    roots: Option<Vec<String>>,
    owner: Option<String>,
}

/// Process-lifetime state shared across reconnects. The PtyManager singleton
/// keeps sessions alive while attachments detach with each socket.
pub struct SessionRuntime {
    home: PathBuf,
    base_env: HashMap<String, String>,
    pub(crate) workspace: Arc<crate::workspace::SharedRuntime>,
    #[cfg(unix)]
    pty: Arc<PtyManager>,
}

impl SessionRuntime {
    pub fn new() -> SessionRuntime {
        Self::with_roots(None)
    }

    pub fn with_roots(local_roots: Option<Vec<String>>) -> SessionRuntime {
        let base_env = process_env_snapshot();
        let home = base_env.get("HOME").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
        #[cfg(unix)]
        let pty = {
            let deps = Arc::new(crate::pty_deps::RealPtyDeps::new(base_env.clone()));
            Arc::new(PtyManager::new(deps, home.clone(), base_env.clone()))
        };
        SessionRuntime {
            home,
            base_env,
            workspace: Arc::new(crate::workspace::SharedRuntime::new(local_roots)),
            #[cfg(unix)]
            pty,
        }
    }
}

impl Default for SessionRuntime {
    fn default() -> SessionRuntime {
        SessionRuntime::new()
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

fn jitter() -> f64 {
    let mut byte = [0_u8; 1];
    let _ = getrandom::fill(&mut byte);
    0.5 + f64::from(byte[0]) / 512.0
}

/// Keep the machine online forever. Fatal errors end the process; anything
/// else rides a jittered exponential backoff with a 30s ceiling.
pub async fn stay_online(mut config: Config, config_path: &Path, mut state: SessionState) -> ! {
    let runtime = SessionRuntime::with_roots(config.allowed_roots.clone());
    let mut attempt: u32 = 0;
    loop {
        match relay_session(&mut config, config_path, &mut state, &runtime).await {
            Ok(was_connected) => {
                if was_connected {
                    attempt = 0;
                }
            }
            Err(RelayError::Fatal { message, exit_code }) => {
                eprintln!("{message}");
                std::process::exit(exit_code);
            }
            Err(error) => {
                eprintln!("Relay offline: {error}");
            }
        }
        let ceiling = 500_u64.saturating_mul(1_u64 << attempt.min(10)).min(30_000);
        attempt = attempt.saturating_add(1);
        let delay = (ceiling as f64 * jitter()).round().max(0.0) as u64;
        tokio::time::sleep(Duration::from_millis(delay)).await;
    }
}

fn save(config: &Config, config_path: &Path) {
    if let Err(error) = save_config(config_path, config) {
        eprintln!("Could not save the relay config: {error}");
    }
}

/// Build a per-frame FrameContext reading the current reconciled auth.
fn make_context(
    out: &mpsc::UnboundedSender<Value>,
    pending: &Arc<AtomicU64>,
    auth: &AuthSnapshot,
) -> FrameContext {
    let sender = out.clone();
    let pending_send = Arc::clone(pending);
    let pending_probe = Arc::clone(pending);
    FrameContext {
        send: Arc::new(move |frame: Value| {
            let size = serde_json::to_string(&frame).map(|text| text.len() as u64).unwrap_or(0);
            pending_send.fetch_add(size, Ordering::SeqCst);
            let _ = sender.send(frame);
        }),
        buffered_amount: Arc::new(move || pending_probe.load(Ordering::SeqCst)),
        trust: auth.trust.clone(),
        local_roots: auth.roots.clone(),
        owner_user_id: auth.owner.clone(),
    }
}

async fn relay_session(
    config: &mut Config,
    config_path: &Path,
    state: &mut SessionState,
    runtime: &SessionRuntime,
) -> Result<bool, RelayError> {
    if config.backend.is_empty() {
        return Err(RelayError::fatal(
            "The relay config has no backend URL. Re-pair with: npx cmux-relay --pair",
        ));
    }
    let socket_url =
        websocket_url(&format!("{}/v2/relays/{}/socket", config.backend, config.device_id));
    let (socket, _response) = connect_async(socket_url.as_str())
        .await
        .map_err(|error| RelayError::transient(error.to_string()))?;
    let socket = Arc::new(AsyncMutex::new(socket));

    let local_roots = config.allowed_roots.clone().filter(|roots| !roots.is_empty());
    let hello = HelloFrame {
        version: FRAME_VERSION,
        frame_type: "hello",
        relay_protocol_version: advertised_protocol(),
        cli_version: CLI_VERSION,
        machine_id: &config.device_id,
        token: &config.token,
        allowed_roots: local_roots.as_ref(),
        managed_enrollment: if state.managed { config.managed.as_ref() } else { None },
    };
    let hello_text =
        serde_json::to_string(&hello).map_err(|error| RelayError::transient(error.to_string()))?;
    socket
        .lock()
        .await
        .send(Message::Text(hello_text.into()))
        .await
        .map_err(|error| RelayError::transient(error.to_string()))?;

    // Outbound frame channel (exec/PTY tasks -> socket) + backpressure gauge.
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Value>();
    let pending = Arc::new(AtomicU64::new(0));
    let action_slots = Arc::new(Semaphore::new(8));
    let auth = Arc::new(std::sync::Mutex::new(AuthSnapshot::default()));
    let workspace_runtime = Arc::clone(&runtime.workspace);
    let (workspace_tx, mut workspace_rx) = mpsc::unbounded_channel::<String>();
    let workspace = crate::workspace::Connection::new(workspace_runtime, workspace_tx);
    let workspace_out = out_tx.clone();
    tokio::spawn(async move {
        while let Some(text) = workspace_rx.recv().await {
            if let Ok(frame) = serde_json::from_str::<Value>(&text) {
                let _ = workspace_out.send(frame);
            }
        }
    });

    // Ordered PTY frame dispatch on its own task so a slow open (daemon
    // spawn) never stalls heartbeats or other frames.
    #[cfg(unix)]
    let pty_tx = {
        let (pty_tx, mut pty_rx) = mpsc::unbounded_channel::<Value>();
        let manager = Arc::clone(&runtime.pty);
        let out = out_tx.clone();
        let pending = Arc::clone(&pending);
        let auth = Arc::clone(&auth);
        tokio::spawn(async move {
            while let Some(frame) = pty_rx.recv().await {
                let snapshot = auth.lock().expect("auth lock").clone();
                let context = make_context(&out, &pending, &snapshot);
                manager.handle_frame(&frame, &context).await;
            }
        });
        pty_tx
    };

    let mut connected = false;
    let mut negotiated_version: u64 = 0;
    let mut unknown_types: HashSet<String> = HashSet::new();
    let mut heartbeat: Option<tokio::time::Interval> = None;

    let result = loop {
        enum Wake {
            Heartbeat,
            Outbound(Option<Value>),
            Incoming(Option<Result<Message, tokio_tungstenite::tungstenite::Error>>),
        }
        let wake = {
            let mut guard = socket.lock().await;
            tokio::select! {
                _ = async {
                    match heartbeat.as_mut() {
                        Some(interval) => interval.tick().await,
                        None => std::future::pending().await,
                    }
                }, if heartbeat.is_some() => Wake::Heartbeat,
                frame = out_rx.recv() => Wake::Outbound(frame),
                incoming = guard.next() => Wake::Incoming(incoming),
            }
        };
        match wake {
            Wake::Heartbeat => {
                let frame = heartbeat_frame(now_ms()).to_string();
                if socket.lock().await.send(Message::Text(frame.into())).await.is_err() {
                    break Ok(connected);
                }
            }
            Wake::Outbound(Some(frame)) => {
                let text = frame.to_string();
                let size = text.len() as u64;
                let sent = socket.lock().await.send(Message::Text(text.into())).await;
                pending.fetch_sub(size.min(pending.load(Ordering::SeqCst)), Ordering::SeqCst);
                if sent.is_err() {
                    break Ok(connected);
                }
            }
            Wake::Outbound(None) => {}
            Wake::Incoming(incoming) => {
                let message = match incoming {
                    Some(Ok(message)) => message,
                    Some(Err(error)) => break Err(RelayError::transient(error.to_string())),
                    None => break Ok(connected),
                };
                let text = match message {
                    Message::Text(text) => text,
                    Message::Ping(payload) => {
                        let _ = socket.lock().await.send(Message::Pong(payload)).await;
                        continue;
                    }
                    Message::Close(_) => break Ok(connected),
                    _ => continue,
                };
                // Unreadable frames are ignored; the socket stays open.
                let Some(frame) = parse_server_frame(&text) else { continue };
                match frame {
                    ServerFrame::HelloAccepted(hello) => {
                        connected = true;
                        negotiated_version = hello.relay_protocol_version;
                        clear_invalid_yolo_confirmation(config);
                        let configured = relay_trust(
                            config.pending_trust.as_deref().or(config.trust.as_deref()),
                        );
                        let local_trust = if state.managed {
                            DEFAULT_RELAY_TRUST
                        } else {
                            effective_local_trust(config)
                        };
                        if !state.managed && configured != local_trust {
                            config.pending_trust = Some(local_trust.as_str().to_owned());
                            save(config, config_path);
                        }
                        if let Some(owner) = hello.owner_user_id {
                            config.owner_user_id = Some(owner);
                        }
                        if state.managed {
                            match hello
                                .managed_session_token
                                .as_deref()
                                .filter(|token| token.len() >= 32)
                            {
                                Some(token) => config.token = token.to_owned(),
                                None => {
                                    if !config.enrollment_claimed {
                                        break Err(RelayError::fatal(
                                            "Managed enrollment was not accepted.",
                                        ));
                                    }
                                }
                            }
                            config.enrollment_claimed = true;
                        }
                        let display_name = if hello.machine_name.is_empty() {
                            config.name.clone().unwrap_or_default()
                        } else {
                            hello.machine_name.clone()
                        };
                        let shown_trust = if state.managed {
                            hello.trust.clone()
                        } else {
                            local_trust.as_str().to_owned()
                        };
                        println!(
                            "Connected as {display_name} (protocol v{}, trust {shown_trust}, scope {}).",
                            hello.relay_protocol_version, hello.scope,
                        );
                        if state.first_connect {
                            state.first_connect = false;
                            println!(
                                "{}",
                                if state.first_run {
                                    "Leave this terminal running, or rely on autostart to keep \
                                     this machine reachable."
                                } else {
                                    "Leave this running; chatmux can now reach this machine."
                                }
                            );
                        }
                        if !state.managed
                            && (local_trust.as_str() != hello.trust
                                || local_trust == Trust::Autonomous)
                        {
                            let frame = set_trust_frame(local_trust.as_str()).to_string();
                            if socket.lock().await.send(Message::Text(frame.into())).await.is_err()
                            {
                                break Ok(connected);
                            }
                        } else if !state.managed {
                            config.trust = Some(local_trust.as_str().to_owned());
                            config.pending_trust = None;
                            save(config, config_path);
                        } else {
                            config.trust = Some(hello.trust.clone());
                        }
                        // Publish the reconciled auth for exec/PTY dispatch.
                        {
                            let effective_trust = if state.managed {
                                hello.trust.clone()
                            } else {
                                local_trust.as_str().to_owned()
                            };
                            let mut snapshot = auth.lock().expect("auth lock");
                            snapshot.trust = effective_trust;
                            snapshot.roots = local_roots.clone();
                            snapshot.owner = config.owner_user_id.clone();
                        }
                        let mut interval = tokio::time::interval(Duration::from_millis(
                            hello.heartbeat_interval_ms,
                        ));
                        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                        interval.reset();
                        heartbeat = Some(interval);
                    }
                    ServerFrame::UpgradeRequired { min_version, message } => {
                        let advertised = advertised_protocol();
                        break Err(RelayError::fatal(format!(
                            "This cmux-relay speaks relay protocol v{advertised}, but the server \
                             requires v{min_version} or newer.\n{message}\n\nUpgrade:\n  npx \
                             cmux-relay@latest        # npx fetches the latest release each run\n  \
                             npm i -g cmux-relay@latest   # if you installed it globally"
                        )));
                    }
                    ServerFrame::HeartbeatAck => {}
                    ServerFrame::TrustAck { trust } => {
                        let Some(ack) = Trust::parse(&trust) else { continue };
                        if ack == Trust::Autonomous && !has_yolo_confirmation(config) {
                            config.trust = Some(DEFAULT_RELAY_TRUST.as_str().to_owned());
                            config.pending_trust = Some(DEFAULT_RELAY_TRUST.as_str().to_owned());
                            clear_invalid_yolo_confirmation(config);
                            if !state.managed {
                                save(config, config_path);
                            }
                            let frame = set_trust_frame(DEFAULT_RELAY_TRUST.as_str()).to_string();
                            let _ = socket.lock().await.send(Message::Text(frame.into())).await;
                            eprintln!(
                                "Refused an autonomous trust acknowledgement without this \
                                 machine's local YOLO receipt."
                            );
                            continue;
                        }
                        config.trust = Some(ack.as_str().to_owned());
                        config.pending_trust = None;
                        if ack != Trust::Autonomous {
                            config.yolo_confirmed_at = None;
                        }
                        if !state.managed {
                            save(config, config_path);
                        }
                        auth.lock().expect("auth lock").trust = ack.as_str().to_owned();
                        println!("Trust level set to {ack}.");
                    }
                    ServerFrame::ActionRequest { action_id, verb, raw } => {
                        // Managed sandbox relays serve terminals, not verbs;
                        // below the exec dialect the server never sends these.
                        if negotiated_version < EXEC_PROTOCOL_VERSION || state.managed {
                            continue;
                        }
                        let snapshot = auth.lock().expect("auth lock").clone();
                        let action = ActionContext {
                            trust: snapshot.trust,
                            local_roots: snapshot.roots,
                            home: runtime.home.clone(),
                            env: scrubbed_env(&runtime.base_env),
                        };
                        let out = out_tx.clone();
                        let pending = Arc::clone(&pending);
                        let action_slots = Arc::clone(&action_slots);
                        let version = raw.get("version").cloned().unwrap_or(Value::from(1));
                        let actor = raw
                            .get("actorId")
                            .and_then(Value::as_str)
                            .unwrap_or("chatmux")
                            .to_owned();
                        let permit = match action_slots.try_acquire_owned() {
                            Ok(permit) => permit,
                            Err(_) => {
                                let result = serde_json::json!({
                                    "type": "action_result",
                                    "version": version,
                                    "actionId": action_id,
                                    "ok": false,
                                    "code": "busy",
                                    "message": "relay is busy; retry this action",
                                });
                                let size = serde_json::to_string(&result)
                                    .map(|text| text.len() as u64)
                                    .unwrap_or(0);
                                pending.fetch_add(size, Ordering::SeqCst);
                                let _ = out.send(result);
                                continue;
                            }
                        };
                        tokio::spawn(async move {
                            let _permit = permit;
                            let result = perform_action(&raw, &action).await;
                            let ok = result.get("ok").and_then(Value::as_bool).unwrap_or(false);
                            if ok {
                                println!(
                                    "Ran {verb} for {actor} (action {}).",
                                    action_id.chars().take(8).collect::<String>()
                                );
                            } else {
                                let code =
                                    result.get("code").and_then(Value::as_str).unwrap_or("failed");
                                println!("Refused {verb} ({code}) for {actor}.");
                            }
                            let size = serde_json::to_string(&result)
                                .map(|text| text.len() as u64)
                                .unwrap_or(0);
                            pending.fetch_add(size, Ordering::SeqCst);
                            let _ = out.send(result);
                        });
                    }
                    ServerFrame::Pty { frame_type, raw } => {
                        if negotiated_version < PTY_PROTOCOL_VERSION {
                            continue;
                        }
                        if frame_type == "pty_open" {
                            let session = raw.get("session").and_then(Value::as_str).unwrap_or("?");
                            let actor =
                                raw.get("actorId").and_then(Value::as_str).unwrap_or("chatmux");
                            println!("Terminal attach to session \"{session}\" for {actor}.");
                        }
                        #[cfg(unix)]
                        {
                            let _ = pty_tx.send(raw);
                        }
                        #[cfg(not(unix))]
                        {
                            // Non-Unix relays cannot allocate PTYs; answer typed.
                            let reply = match frame_type.as_str() {
                                "pty_open" => raw.get("ptyId").and_then(Value::as_str).map(|id| {
                                    serde_json::json!({
                                        "version": PTY_PROTOCOL_VERSION,
                                        "type": "pty_error",
                                        "ptyId": id,
                                        "code": "failed",
                                        "message": "terminals are not available on this relay platform",
                                    })
                                }),
                                "surface_list" => {
                                    raw.get("requestId").and_then(Value::as_str).map(|id| {
                                        serde_json::json!({
                                            "version": PTY_PROTOCOL_VERSION,
                                            "type": "surface_list_result",
                                            "requestId": id,
                                            "surfaces": [],
                                        })
                                    })
                                }
                                _ => None,
                            };
                            if let Some(reply) = reply {
                                let _ = out_tx.send(reply);
                            }
                        }
                    }
                    ServerFrame::Workspace { frame } => {
                        if negotiated_version >= crate::workspace::WORKSPACE_FRAME_VERSION as u64 {
                            let snapshot = auth.lock().expect("auth lock").clone();
                            workspace.set_local_observe(snapshot.trust == "observe");
                            workspace.handle_frame(frame);
                        }
                    }
                    ServerFrame::Error { code, message } => {
                        if code == "unauthorized" || code == "machine_mismatch" {
                            break Err(RelayError::fatal(format!(
                                "The server refused this machine's credential ({code}). The \
                                 pairing may have been replaced or revoked. Re-pair with: npx \
                                 cmux-relay --pair"
                            )));
                        }
                        let suffix = message.map(|text| format!(" — {text}")).unwrap_or_default();
                        eprintln!("Server error: {code}{suffix}");
                    }
                    ServerFrame::Unknown { frame_type } => {
                        if unknown_types.insert(frame_type.clone()) {
                            eprintln!(
                                "Ignoring unknown server frame type \"{frame_type}\" (a newer server?)."
                            );
                        }
                    }
                }
            }
        }
    };

    // Attachments die with the socket; sessions persist (docs/TERMINAL.md).
    #[cfg(unix)]
    runtime.pty.detach_all();
    result
}
