//! Connected state: hello negotiation, heartbeats, trust sync, reconnect
//! with jittered exponential backoff. Behavior port of `stayOnline` /
//! `relaySession` in `packages/relay/bin/cmux-relay.mjs`.

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::Value;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::config::{Config, save_config};
use crate::error::RelayError;
use crate::pairing::websocket_url;
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
/// else rides a jittered exponential backoff with a 30s ceiling, riding out
/// Worker deploys and network loss without user action.
pub async fn stay_online(mut config: Config, config_path: &Path, mut state: SessionState) -> ! {
    let mut attempt: u32 = 0;
    // Outlives every socket: preview proxies (and their console ring) keep
    // serving across reconnects because the tunnel points at their ports.
    let workspace_runtime =
        std::sync::Arc::new(crate::workspace::SharedRuntime::new(config.allowed_roots.clone()));
    loop {
        match relay_session(&mut config, config_path, &mut state, &workspace_runtime).await {
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

async fn relay_session(
    config: &mut Config,
    config_path: &Path,
    state: &mut SessionState,
    workspace_runtime: &std::sync::Arc<crate::workspace::SharedRuntime>,
) -> Result<bool, RelayError> {
    if config.backend.is_empty() {
        return Err(RelayError::fatal(
            "The relay config has no backend URL. Re-pair with: npx cmux-relay --pair",
        ));
    }
    let socket_url =
        websocket_url(&format!("{}/v2/relays/{}/socket", config.backend, config.device_id));
    let (mut socket, _response) = connect_async(socket_url.as_str())
        .await
        .map_err(|error| RelayError::transient(error.to_string()))?;

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
        .send(Message::Text(hello_text.into()))
        .await
        .map_err(|error| RelayError::transient(error.to_string()))?;

    let mut connected = false;
    let mut negotiated_version: u64 = 0;
    let mut unknown_types: HashSet<String> = HashSet::new();
    let mut heartbeat: Option<tokio::time::Interval> = None;

    // v6 workspace verbs answer through this queue so a slow op never
    // blocks heartbeats; watches die with this connection (the Worker
    // re-opens them on the next socket).
    let (outbound_tx, mut outbound_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let workspace =
        crate::workspace::Connection::new(std::sync::Arc::clone(workspace_runtime), outbound_tx);

    loop {
        let incoming = tokio::select! {
            _ = async {
                match heartbeat.as_mut() {
                    Some(interval) => interval.tick().await,
                    None => std::future::pending().await,
                }
            }, if heartbeat.is_some() => {
                let frame = heartbeat_frame(now_ms()).to_string();
                if socket.send(Message::Text(frame.into())).await.is_err() {
                    return Ok(connected);
                }
                continue;
            }
            outgoing = outbound_rx.recv() => {
                if let Some(text) = outgoing
                    && socket.send(Message::Text(text.into())).await.is_err()
                {
                    return Ok(connected);
                }
                continue;
            }
            incoming = socket.next() => incoming,
        };
        let message = match incoming {
            Some(Ok(message)) => message,
            Some(Err(error)) => return Err(RelayError::transient(error.to_string())),
            None => return Ok(connected),
        };
        let text = match message {
            Message::Text(text) => text,
            Message::Ping(payload) => {
                let _ = socket.send(Message::Pong(payload)).await;
                continue;
            }
            Message::Close(_) => return Ok(connected),
            _ => continue,
        };
        // Unreadable frames are ignored; the socket stays open.
        let Some(frame) = parse_server_frame(&text) else { continue };
        match frame {
            ServerFrame::HelloAccepted(hello) => {
                connected = true;
                negotiated_version = hello.relay_protocol_version;
                clear_invalid_yolo_confirmation(config);
                let configured =
                    relay_trust(config.pending_trust.as_deref().or(config.trust.as_deref()));
                let local_trust =
                    if state.managed { DEFAULT_RELAY_TRUST } else { effective_local_trust(config) };
                if !state.managed && configured != local_trust {
                    config.pending_trust = Some(local_trust.as_str().to_owned());
                    save(config, config_path);
                }
                // v4+ servers name the paired owner so PTY opens can be
                // re-checked locally. Persisted for --status.
                if let Some(owner) = hello.owner_user_id {
                    config.owner_user_id = Some(owner);
                }
                if state.managed {
                    match hello.managed_session_token.as_deref().filter(|token| token.len() >= 32) {
                        Some(token) => {
                            // Runtime memory only. The enrollment file was
                            // already shredded; managed mode never saves.
                            config.token = token.to_owned();
                        }
                        None => {
                            if !config.enrollment_claimed {
                                return Err(RelayError::fatal(
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
                // Machine-side gate for the mutating workspace ops: the
                // LOCAL effective trust decides, not the server row.
                workspace.set_local_observe(shown_trust == Trust::Observe.as_str());
                println!(
                    "Connected as {display_name} (protocol v{}, trust {shown_trust}, scope {}).",
                    hello.relay_protocol_version, hello.scope,
                );
                if state.first_connect {
                    state.first_connect = false;
                    println!(
                        "{}",
                        if state.first_run {
                            "Leave this terminal running, or rely on autostart to keep this \
                             machine reachable."
                        } else {
                            "Leave this running; chatmux can now reach this machine."
                        }
                    );
                }
                // The relay's local config is the owner-at-the-keyboard
                // authority. A phone approval can never raise trust by
                // itself: when the server row is more permissive than this
                // local setting, send the local value back through the
                // authenticated set_trust frame. Older or missing config
                // defaults to supervised, so reconnects fail closed.
                if !state.managed
                    && (local_trust.as_str() != hello.trust || local_trust == Trust::Autonomous)
                {
                    let frame = set_trust_frame(local_trust.as_str()).to_string();
                    if socket.send(Message::Text(frame.into())).await.is_err() {
                        return Ok(connected);
                    }
                } else if !state.managed {
                    config.trust = Some(local_trust.as_str().to_owned());
                    config.pending_trust = None;
                    save(config, config_path);
                } else {
                    config.trust = Some(hello.trust.clone());
                }
                let mut interval =
                    tokio::time::interval(Duration::from_millis(hello.heartbeat_interval_ms));
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                // The first tick of a tokio interval fires immediately;
                // consume it so heartbeats start one interval from now,
                // like the JS setInterval.
                interval.reset();
                heartbeat = Some(interval);
            }
            ServerFrame::UpgradeRequired { min_version, message } => {
                let advertised = advertised_protocol();
                return Err(RelayError::fatal(format!(
                    "This cmux-relay speaks relay protocol v{advertised}, but the server \
                     requires v{min_version} or newer.\n{message}\n\nUpgrade:\n  npx \
                     cmux-relay@latest        # npx fetches the latest release each run\n  npm \
                     i -g cmux-relay@latest   # if you installed it globally"
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
                    let _ = socket.send(Message::Text(frame.into())).await;
                    eprintln!(
                        "Refused an autonomous trust acknowledgement without this machine's \
                         local YOLO receipt."
                    );
                    continue;
                }
                config.trust = Some(ack.as_str().to_owned());
                config.pending_trust = None;
                workspace.set_local_observe(ack == Trust::Observe);
                if ack != Trust::Autonomous {
                    config.yolo_confirmed_at = None;
                }
                if !state.managed {
                    save(config, config_path);
                }
                println!("Trust level set to {ack}.");
            }
            ServerFrame::ActionRequest { action_id, verb } => {
                // Remote execution verbs land in a later slice
                // (README: port plan). Below the exec dialect the server
                // never sends these; a typed refusal keeps callers unblocked
                // if one arrives anyway.
                if negotiated_version < EXEC_PROTOCOL_VERSION || state.managed {
                    continue;
                }
                let refusal = serde_json::json!({
                    "version": FRAME_VERSION,
                    "type": "action_result",
                    "actionId": action_id,
                    "ok": false,
                    "code": "unsupported_verb",
                    "message": "This relay build does not run verbs yet (Rust port slice 1).",
                });
                println!("Refused {verb} (unsupported_verb) for chatmux.");
                if socket.send(Message::Text(refusal.to_string().into())).await.is_err() {
                    return Ok(connected);
                }
            }
            ServerFrame::Pty { frame_type, pty_id, request_id } => {
                // PTY attach lands in a later slice (README: port plan).
                if negotiated_version < PTY_PROTOCOL_VERSION {
                    continue;
                }
                let reply: Option<Value> = match frame_type.as_str() {
                    "pty_open" => pty_id.map(|pty_id| {
                        serde_json::json!({
                            "version": FRAME_VERSION,
                            "type": "pty_error",
                            "ptyId": pty_id,
                            "code": "failed",
                            "message":
                                "This relay build does not attach terminals yet (Rust port slice 1).",
                        })
                    }),
                    "surface_list" => request_id.map(|request_id| {
                        serde_json::json!({
                            "version": FRAME_VERSION,
                            "type": "surface_list_result",
                            "requestId": request_id,
                            "surfaces": [],
                        })
                    }),
                    _ => None,
                };
                if let Some(reply) = reply
                    && socket.send(Message::Text(reply.to_string().into())).await.is_err()
                {
                    return Ok(connected);
                }
            }
            ServerFrame::Workspace { frame } => {
                workspace.handle_frame(frame);
            }
            ServerFrame::Error { code, message } => {
                if code == "unauthorized" || code == "machine_mismatch" {
                    return Err(RelayError::fatal(format!(
                        "The server refused this machine's credential ({code}). The pairing \
                         may have been replaced or revoked. Re-pair with: npx cmux-relay --pair"
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
