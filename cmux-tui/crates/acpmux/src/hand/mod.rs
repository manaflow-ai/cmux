//! `acpmux hand`: this machine as a hand of a Cloud Chief.
//!
//! The hand dials out to the Cloud API over one WebSocket (no inbound port),
//! authenticates with its own key (registered once with a single-use pairing
//! code), and serves typed requests: agent sessions through this machine's
//! acpmux daemon, file reads and edits with hash preconditions, and (on a
//! `sandbox` hand only) program runs. Every request is checked here against
//! the hand's local policy (config.rs, policy.rs) before it runs; the Cloud's
//! own checks are a second layer, not the only one.
//!
//! It is a subcommand of acpmux, not a separate binary, because it drives
//! acpmux's daemon with acpmux's own client and ships in the acpmux release
//! files that already exist for macOS and Linux (no new crate, dependency or
//! release lane). `install.sh` names the installed file `cmux-hand`.

pub mod agent;
pub mod config;
pub mod daemon;
pub mod exec;
pub mod fsops;
pub mod gateway;
pub mod link;
pub mod pair;
pub mod patch;
pub mod policy;
mod requests;

use clap::Subcommand;
use serde_json::{Value, json};
use std::path::PathBuf;

/// A refused or failed request: `code` is stable, `message` is for people.
#[derive(Debug)]
pub struct HandError {
    pub code: String,
    pub message: String,
    pub detail: Option<Value>,
}

impl HandError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_owned(), message: message.into(), detail: None }
    }
    pub fn io(path: &std::path::Path, e: std::io::Error) -> Self {
        let code = match e.kind() {
            std::io::ErrorKind::NotFound => "fs.not_found",
            std::io::ErrorKind::PermissionDenied => "fs.permission",
            _ => "fs.io",
        };
        Self::new(code, format!("{}: {e}", path.display()))
    }
    pub fn with_detail(mut self, d: Value) -> Self {
        self.detail = Some(d);
        self
    }
    pub fn to_json(&self) -> Value {
        json!({ "code": self.code, "message": self.message, "detail": self.detail })
    }
}

#[derive(Subcommand)]
pub enum HandCmd {
    /// Register this machine with a single-use pairing code (10 minutes).
    Pair {
        code: String,
        /// API origin, for example https://cloud-api.cmux.dev.
        #[arg(long)]
        api: String,
        /// sandbox (the whole machine is the hand's) or mac (the home folder, a Cloud classifier per
        /// request, hard denies here, owner approval for anything not routine).
        #[arg(long, default_value = "sandbox")]
        profile: String,
        /// A folder the hand may touch. Repeat for more. Default: / (sandbox), the home folder (mac).
        #[arg(long = "root")]
        roots: Vec<PathBuf>,
        /// acpmux permission policy for agents: ask, approve-reads, approve-edits, deny-all.
        /// Default: approve-edits (sandbox), ask (mac).
        #[arg(long)]
        agent_policy: Option<String>,
        /// Name shown in the Cloud (default: the host name).
        #[arg(long)]
        name: Option<String>,
    },
    /// Connect and serve requests until stopped (the user service runs this).
    Run,
    /// Print this hand's id, API, profile and roots (never the key).
    Status,
}

fn pair_summary(cfg: &config::HandConfig) -> Value {
    json!({"paired": true, "hand": cfg.hand, "api": cfg.api, "profile": cfg.profile,
        "roots": cfg.roots, "agentPolicy": cfg.agent_policy, "config": config::path()})
}

pub async fn run(cmd: HandCmd, json_out: bool) -> anyhow::Result<()> {
    match cmd {
        HandCmd::Pair { code, api, profile, roots, agent_policy, name } => {
            let cfg = pair::pair(&code, &api, &profile, roots, agent_policy, name).await?;
            if json_out {
                println!("{}", pair_summary(&cfg));
            } else {
                println!("paired: {} ({:?}) -> {}", cfg.hand, cfg.profile, cfg.api);
            }
            Ok(())
        }
        HandCmd::Run => link::run(config::load()?).await,
        HandCmd::Status => {
            let cfg = config::load()?;
            let shown = json!({ "hand": cfg.hand, "api": cfg.api, "profile": cfg.profile, "roots": cfg.roots, "allow": cfg.allow, "agent_policy": cfg.agent_policy, "config": config::path() });
            if json_out {
                println!("{}", serde_json::to_string(&shown)?);
            } else {
                println!("{}", serde_json::to_string_pretty(&shown)?);
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hand::config::{HandConfig, Profile};
    use std::path::PathBuf;

    #[test]
    fn pair_json_summary_is_safe_and_machine_readable() {
        let cfg = HandConfig {
            api: "https://cloud.example".into(),
            hand: "hand_test".into(),
            key: "secret-key-must-not-leak".into(),
            profile: Profile::Sandbox,
            roots: vec![PathBuf::from("/")],
            allow: Vec::new(),
            agent_policy: "approve-edits".into(),
        };
        let summary = pair_summary(&cfg);
        assert_eq!(summary["paired"], true);
        assert_eq!(summary["hand"], "hand_test");
        assert!(summary.get("key").is_none());
        assert!(!summary.to_string().contains("secret-key"));
    }
}
