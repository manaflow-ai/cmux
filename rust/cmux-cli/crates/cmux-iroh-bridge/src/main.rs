#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

use std::path::PathBuf;
use std::process::Command;

use anyhow::{Context, Result, bail};
use clap::{Parser, ValueEnum};
use cmux_iroh_bridge::{
    BridgeNodeInfo, BridgeOptions, BridgePairingOptions, BridgeRelayMode, serve,
};

#[derive(Parser, Debug)]
#[command(name = "cmux-iroh-bridge", about = "Expose a cmx socket over iroh")]
struct Cli {
    #[arg(long, env = "CMX_SOCKET_PATH")]
    socket: PathBuf,
    #[arg(long, value_enum, default_value_t = RelayArg::Default)]
    relay: RelayArg,
    #[arg(long, env = "CMUX_PAIRING_ID")]
    pairing_id: Option<String>,
    #[arg(long, env = "CMUX_PAIRING_SECRET")]
    pairing_secret: Option<String>,
    #[arg(long, env = "CMUX_RIVET_ENDPOINT")]
    rivet_endpoint: Option<String>,
    #[arg(long, env = "CMUX_STACK_PROJECT_ID")]
    stack_project_id: Option<String>,
    #[arg(long, env = "CMUX_PAIRING_EXPIRES_AT_UNIX")]
    expires_at_unix: Option<u64>,
    #[arg(long, env = "CMUX_NODE_ID")]
    node_id: Option<String>,
    #[arg(long, env = "CMUX_NODE_NAME")]
    node_name: Option<String>,
    #[arg(long, env = "CMUX_NODE_SUBTITLE")]
    node_subtitle: Option<String>,
    #[arg(long, env = "CMUX_NODE_KIND")]
    node_kind: Option<String>,
    #[arg(long)]
    allow_insecure_direct: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum RelayArg {
    Default,
    Disabled,
}

impl From<RelayArg> for BridgeRelayMode {
    fn from(value: RelayArg) -> Self {
        match value {
            RelayArg::Default => Self::Default,
            RelayArg::Disabled => Self::Disabled,
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let cli = Cli::parse();
    let pairing = pairing_options(&cli)?;
    let node = node_info(&cli)?;
    serve(BridgeOptions {
        cmx_socket_path: cli.socket,
        relay_mode: cli.relay.into(),
        pairing,
        node,
    })
    .await
}

fn node_info(cli: &Cli) -> Result<Option<BridgeNodeInfo>> {
    let detected = autodetected_node_info();

    let node = BridgeNodeInfo {
        id: cli.node_id.clone().or(detected.id),
        name: cli.node_name.clone().unwrap_or(detected.name),
        subtitle: cli.node_subtitle.clone().or(detected.subtitle),
        kind: cli.node_kind.clone().or(detected.kind),
    };
    node.validate()?;
    Ok(Some(node))
}

fn autodetected_node_info() -> BridgeNodeInfo {
    let host_name = host_name();
    let kind = default_node_kind().to_owned();
    BridgeNodeInfo {
        id: host_name.as_ref().map(|name| format!("{}:{}", kind, name)),
        name: platform_display_name()
            .or_else(|| host_name.clone())
            .unwrap_or_else(|| "cmux node".to_owned()),
        subtitle: Some(format!(
            "{} {}",
            default_node_label(),
            std::env::consts::ARCH
        )),
        kind: Some(kind),
    }
}

#[cfg(target_os = "macos")]
fn default_node_kind() -> &'static str {
    "macos"
}

#[cfg(target_os = "linux")]
fn default_node_kind() -> &'static str {
    "linux"
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn default_node_kind() -> &'static str {
    std::env::consts::OS
}

#[cfg(target_os = "macos")]
fn default_node_label() -> &'static str {
    "macOS"
}

#[cfg(target_os = "linux")]
fn default_node_label() -> &'static str {
    "Linux"
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn default_node_label() -> &'static str {
    std::env::consts::OS
}

#[cfg(target_os = "macos")]
fn platform_display_name() -> Option<String> {
    command_stdout("scutil", &["--get", "ComputerName"])
}

#[cfg(not(target_os = "macos"))]
fn platform_display_name() -> Option<String> {
    None
}

fn host_name() -> Option<String> {
    std::env::var("HOSTNAME")
        .ok()
        .and_then(non_empty)
        .or_else(|| command_stdout("hostname", &[]))
}

fn command_stdout(command: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(command).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    non_empty(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn non_empty(value: String) -> Option<String> {
    let trimmed = value.trim().to_owned();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn pairing_options(cli: &Cli) -> Result<Option<BridgePairingOptions>> {
    let has_pairing = cli.pairing_id.is_some()
        || cli.pairing_secret.is_some()
        || cli.rivet_endpoint.is_some()
        || cli.stack_project_id.is_some()
        || cli.expires_at_unix.is_some();
    if !has_pairing {
        if cli.allow_insecure_direct {
            return Ok(None);
        }
        bail!(
            "pairing auth is required; provide CMUX_PAIRING_* and CMUX_RIVET_ENDPOINT/CMUX_STACK_PROJECT_ID or pass --allow-insecure-direct for local development"
        );
    }

    Ok(Some(BridgePairingOptions {
        pairing_id: cli
            .pairing_id
            .clone()
            .context("missing --pairing-id / CMUX_PAIRING_ID")?,
        secret: cli
            .pairing_secret
            .clone()
            .context("missing --pairing-secret / CMUX_PAIRING_SECRET")?,
        rivet_endpoint: cli
            .rivet_endpoint
            .clone()
            .context("missing --rivet-endpoint / CMUX_RIVET_ENDPOINT")?,
        stack_project_id: cli
            .stack_project_id
            .clone()
            .context("missing --stack-project-id / CMUX_STACK_PROJECT_ID")?,
        expires_at_unix: cli
            .expires_at_unix
            .context("missing --expires-at-unix / CMUX_PAIRING_EXPIRES_AT_UNIX")?,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cli() -> Cli {
        Cli {
            socket: PathBuf::from("/tmp/cmx.sock"),
            relay: RelayArg::Default,
            pairing_id: None,
            pairing_secret: None,
            rivet_endpoint: None,
            stack_project_id: None,
            expires_at_unix: None,
            node_id: None,
            node_name: None,
            node_subtitle: None,
            node_kind: None,
            allow_insecure_direct: true,
        }
    }

    #[test]
    fn node_info_defaults_to_detected_platform_metadata() {
        let node = node_info(&cli()).expect("node info").expect("node");

        assert!(!node.name.trim().is_empty());
        assert!(
            node.subtitle
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
        );
        assert_eq!(node.kind.as_deref(), Some(default_node_kind()));
    }

    #[test]
    fn node_info_allows_cli_metadata_overrides() {
        let mut cli = cli();
        cli.node_id = Some("manual-id".into());
        cli.node_name = Some("Linux Builder".into());
        cli.node_subtitle = Some("remote".into());
        cli.node_kind = Some("linux".into());

        let node = node_info(&cli).expect("node info").expect("node");

        assert_eq!(node.id.as_deref(), Some("manual-id"));
        assert_eq!(node.name, "Linux Builder");
        assert_eq!(node.subtitle.as_deref(), Some("remote"));
        assert_eq!(node.kind.as_deref(), Some("linux"));
    }
}
