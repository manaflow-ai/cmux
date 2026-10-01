//! mux-link: connects this machine to a mux server so its muxes can drive local acpmux agents.
//!
//! The link dials out (the server never reaches in), serves a fixed allowlist of
//! agent methods, and reports turn endings and permission requests as events.

mod acpmux;
mod protocol;

use acpmux::Acpmux;
use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use futures_util::{SinkExt, StreamExt};
use protocol::{Down, Event, MachineInfo, Up};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

#[derive(Parser)]
#[command(name = "mux-link", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Save the server URL and link token (from the mux web app) to the config file.
    Login {
        #[arg(long)]
        server: String,
        #[arg(long)]
        token: String,
        /// Machine id shown to muxes; defaults to the host name.
        #[arg(long)]
        machine: Option<String>,
    },
    /// Connect and serve until stopped (the default).
    Run,
}

#[derive(Serialize, Deserialize, Default)]
struct Config {
    server: String,
    token: String,
    machine: Option<String>,
}

fn config_path() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config/mux/link.json")
}

fn load_config() -> Result<Config> {
    let path = config_path();
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("read {} (run `mux-link login` first)", path.display()))?;
    Ok(serde_json::from_str(&text)?)
}

#[tokio::main]
async fn main() -> Result<()> {
    // One TLS crypto provider for wss:// servers.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let cli = Cli::parse();
    match cli.command.unwrap_or(Command::Run) {
        Command::Login { server, token, machine } => {
            let path = config_path();
            std::fs::create_dir_all(path.parent().unwrap())?;
            std::fs::write(&path, serde_json::to_string_pretty(&Config { server, token, machine })?)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            }
            println!("saved {}", path.display());
            Ok(())
        }
        Command::Run => run(load_config()?).await,
    }
}

/// Reconnects forever with capped exponential backoff; a session that got as far as
/// `welcome` resets the backoff.
async fn run(config: Config) -> Result<()> {
    let machine = machine_info(config.machine.clone());
    let mut backoff = Duration::from_secs(1);
    loop {
        match session(&config, &machine).await {
            Ok(()) => {
                eprintln!("mux-link: disconnected");
                backoff = Duration::from_secs(1);
            }
            Err(error) => eprintln!("mux-link: {error:#}"),
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

fn machine_info(id: Option<String>) -> MachineInfo {
    let host = std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "machine".to_owned());
    MachineInfo {
        id: id.unwrap_or_else(|| host.clone()),
        name: host,
        os: std::env::consts::OS.to_owned(),
        link_version: env!("CARGO_PKG_VERSION").to_owned(),
        acpmux: true,
    }
}

fn link_url(config: &Config) -> Result<String> {
    let base = config.server.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        bail!("server must start with http:// or https://");
    };
    Ok(format!("{ws}/api/link/ws?token={}", config.token))
}

async fn session(config: &Config, machine: &MachineInfo) -> Result<()> {
    let (notify_tx, mut notify_rx) = mpsc::unbounded_channel::<Value>();
    let acp = Acpmux::connect(&acpmux::socket_path(), notify_tx).await?;
    acp.request("_acpmux/watch", json!({"enabled": true})).await?;

    let (socket, _) = tokio_tungstenite::connect_async(link_url(config)?).await.context("connect to server")?;
    let (mut sink, mut stream) = socket.split();
    let (up_tx, mut up_rx) = mpsc::unbounded_channel::<Up>();
    let writer = tokio::spawn(async move {
        while let Some(frame) = up_rx.recv().await {
            let text = serde_json::to_string(&frame).expect("frames serialize");
            if sink.send(Message::text(text)).await.is_err() {
                break;
            }
        }
    });
    up_tx.send(Up::Hello { machine: machine.clone() }).ok();

    let result = loop {
        tokio::select! {
            incoming = stream.next() => match incoming {
                Some(Ok(Message::Text(text))) => match serde_json::from_str::<Down>(&text) {
                    Ok(Down::Welcome { account_id }) => eprintln!("mux-link: connected as {} for {account_id}", machine.id),
                    Ok(Down::Call { id, method, params }) => {
                        let (acp, up) = (acp.clone(), up_tx.clone());
                        tokio::spawn(async move {
                            let frame = match handle(&acp, &up, &method, params).await {
                                Ok(value) => Up::Result { id, ok: true, value: Some(value), error: None },
                                Err(error) => Up::Result { id, ok: false, value: None, error: Some(format!("{error:#}")) },
                            };
                            up.send(frame).ok();
                        });
                    }
                    Err(error) => eprintln!("mux-link: bad frame: {error}"),
                },
                Some(Ok(Message::Close(_))) | None => break Ok(()),
                Some(Ok(_)) => {}
                Some(Err(error)) => break Err(error.into()),
            },
            notification = notify_rx.recv() => match notification {
                Some(message) => {
                    if let Some(event) = permission_event(&message) {
                        up_tx.send(Up::Event { event }).ok();
                    }
                }
                None => break Err(anyhow::anyhow!("acpmux daemon connection closed")),
            },
        }
    };
    writer.abort();
    result
}

fn permission_event(message: &Value) -> Option<Event> {
    if message.get("method")?.as_str()? != "_acpmux/permission_pending" {
        return None;
    }
    let params = message.get("params")?;
    let request = params.get("request");
    let title = request
        .and_then(|r| r.pointer("/toolCall/title").or_else(|| r.get("title")))
        .and_then(Value::as_str)
        .unwrap_or("permission requested")
        .to_owned();
    let session_id = params.get("sessionId")?.as_str()?.to_owned();
    Some(Event::Permission {
        name: session_id.clone(),
        session_id,
        permission_id: params.get("permissionId")?.as_str()?.to_owned(),
        title,
    })
}

fn str_param<'a>(params: &'a Value, key: &str) -> Result<&'a str> {
    params.get(key).and_then(Value::as_str).with_context(|| format!("missing string param {key}"))
}

/// The allowlist. Anything else is refused.
async fn handle(acp: &Arc<Acpmux>, up: &mpsc::UnboundedSender<Up>, method: &str, params: Value) -> Result<Value> {
    match method {
        "agents.list" => {
            let result = acp.request("_acpmux/sessions", json!({})).await?;
            let agents: Vec<Value> = result
                .get("sessions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(|s| {
                    json!({
                        "sessionId": s.get("sessionId"),
                        "name": s.get("name"),
                        "harness": s.get("harness"),
                        "cwd": s.get("cwd"),
                        "status": s.get("status"),
                        "preview": s.get("preview"),
                        "pendingPermissions": s.get("pendingPermissions"),
                        "updatedAt": s.get("updatedAt"),
                    })
                })
                .collect();
            Ok(json!({ "agents": agents }))
        }
        "agents.harnesses" => {
            let result = acp.request("_acpmux/harnesses", json!({})).await?;
            let names: Vec<String> = result
                .get("harnesses")
                .and_then(Value::as_object)
                .map(|m| m.keys().cloned().collect())
                .unwrap_or_default();
            Ok(json!({ "harnesses": names, "defaultHarness": result.get("defaultHarness") }))
        }
        "agents.spawn" => {
            let cwd = str_param(&params, "cwd")?;
            let prompt = str_param(&params, "prompt")?.to_owned();
            let mut meta = serde_json::Map::new();
            for key in ["harness", "name", "policy"] {
                if let Some(value) = params.get(key).filter(|v| v.is_string()) {
                    meta.insert(key.to_owned(), value.clone());
                }
            }
            let created = acp
                .request("session/new", json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}}))
                .await?;
            let session_id = created.get("sessionId").and_then(Value::as_str).context("session/new returned no sessionId")?.to_owned();
            let info = acp.request("_acpmux/info", json!({"sessionId": session_id})).await.unwrap_or(Value::Null);
            let name = info
                .get("name")
                .or_else(|| info.pointer("/session/name"))
                .and_then(Value::as_str)
                .unwrap_or(&session_id)
                .to_owned();
            start_turn(acp.clone(), up.clone(), session_id.clone(), name.clone(), prompt, false);
            Ok(json!({ "sessionId": session_id, "name": name }))
        }
        "agents.prompt" => {
            let session = str_param(&params, "session")?.to_owned();
            let text = str_param(&params, "text")?.to_owned();
            let steer = params.get("steer").and_then(Value::as_bool).unwrap_or(false);
            let info = acp.request("_acpmux/info", json!({"sessionId": session})).await?;
            let session_id = info
                .get("sessionId")
                .or_else(|| info.pointer("/session/sessionId"))
                .and_then(Value::as_str)
                .unwrap_or(&session)
                .to_owned();
            start_turn(acp.clone(), up.clone(), session_id.clone(), session, text, steer);
            Ok(json!({ "queued": true, "sessionId": session_id }))
        }
        "agents.last" => Ok(json!({ "text": acpmux::last_reply(str_param(&params, "session")?).await? })),
        "agents.cancel" => {
            acp.notify("session/cancel", json!({"sessionId": str_param(&params, "session")?}))?;
            Ok(json!({ "cancelled": true }))
        }
        other => bail!("method {other} is not allowed"),
    }
}

/// Sends a prompt without blocking the call; when the turn ends, reports it with the reply.
fn start_turn(acp: Arc<Acpmux>, up: mpsc::UnboundedSender<Up>, session: String, name: String, text: String, steer: bool) {
    tokio::spawn(async move {
        let mut params = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        if steer {
            params["_meta"] = json!({"acpmux": {"steer": true}});
        }
        let (status, stop_reason) = match acp.request("session/prompt", params).await {
            Ok(result) => {
                let stop = result.get("stopReason").and_then(Value::as_str).map(str::to_owned);
                let status = if stop.as_deref() == Some("cancelled") { "cancelled" } else { "completed" };
                (status.to_owned(), stop)
            }
            Err(error) => ("failed".to_owned(), Some(format!("{error:#}"))),
        };
        let reply = acpmux::last_reply(&session).await.unwrap_or_default();
        up.send(Up::Event { event: Event::TurnEnd { session_id: session, name, status, stop_reason, reply } }).ok();
    });
}
