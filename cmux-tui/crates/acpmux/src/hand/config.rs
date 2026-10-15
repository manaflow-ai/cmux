//! The hand's own file: who it is, its key, and its local policy.
//!
//! Everything that decides what the hand may do (profile, roots, allow rules,
//! the agent permission policy) is set on this machine at pair time and lives
//! only here. Nothing the Cloud sends changes it.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// `sandbox`: the whole machine is the hand's (a Freestyle sandbox). `mac`:
/// a person's computer: no exec, approved folders only, and every request
/// outside an allow rule waits for the owner.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Profile {
    Sandbox,
    Mac,
}

impl Profile {
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "sandbox" => Ok(Self::Sandbox),
            "mac" => Ok(Self::Mac),
            other => bail!("unknown profile {other:?} (sandbox or mac)"),
        }
    }
}

/// One allow rule of the `mac` profile: these actions run without asking
/// when every path of the request is inside `path`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AllowRule {
    pub path: PathBuf,
    /// Action names (`fs.read`, `agent.start`, ...) or `*`.
    pub actions: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HandConfig {
    /// API origin, for example `https://cloud-api.cmux.dev`.
    pub api: String,
    /// `hand_<id>`, assigned by the Cloud at pairing.
    pub hand: String,
    /// The hand's secret. The Cloud stores only its SHA-256.
    pub key: String,
    pub profile: Profile,
    /// Folders the hand may touch at all. A path outside every root is refused.
    pub roots: Vec<PathBuf>,
    #[serde(default)]
    pub allow: Vec<AllowRule>,
    /// acpmux permission policy for agent sessions this hand starts
    /// (`ask`, `approve-reads`, `approve-edits`, `deny-all`). Never `approve-all`.
    pub agent_policy: String,
}

/// `$CMUX_HAND_HOME`, else `~/.cmux-hand`.
pub fn home() -> PathBuf {
    if let Some(h) = std::env::var_os("CMUX_HAND_HOME").filter(|h| !h.is_empty()) {
        return PathBuf::from(h);
    }
    dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join(".cmux-hand")
}

pub fn path() -> PathBuf {
    home().join("hand.json")
}

pub fn load() -> Result<HandConfig> {
    let p = path();
    let text = std::fs::read_to_string(&p)
        .with_context(|| format!("read {} (pair first: acpmux hand pair <code>)", p.display()))?;
    let cfg: HandConfig =
        serde_json::from_str(&text).with_context(|| format!("parse {}", p.display()))?;
    validate(&cfg)?;
    Ok(cfg)
}

pub fn validate(cfg: &HandConfig) -> Result<()> {
    if cfg.roots.is_empty() {
        bail!("a hand needs at least one root");
    }
    for r in cfg.roots.iter().chain(cfg.allow.iter().map(|a| &a.path)) {
        if !r.is_absolute() {
            bail!("root {} is not absolute", r.display());
        }
    }
    if !matches!(cfg.agent_policy.as_str(), "ask" | "approve-reads" | "approve-edits" | "deny-all")
    {
        bail!("agent policy {:?} is not allowed for a hand", cfg.agent_policy);
    }
    // An agent's own reads and edits are not limited to the hand's roots, so
    // on a person's Mac nothing is approved on its own.
    if cfg.profile == Profile::Mac && !matches!(cfg.agent_policy.as_str(), "ask" | "deny-all") {
        bail!("a mac hand runs agents with ask or deny-all only");
    }
    Ok(())
}

/// Writes the file owner-only (it holds the key).
pub fn save(cfg: &HandConfig) -> Result<PathBuf> {
    validate(cfg)?;
    let dir = home();
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let p = path();
    let tmp = dir.join(".hand.json.tmp");
    write_private(&tmp, serde_json::to_vec_pretty(cfg)?.as_slice())?;
    std::fs::rename(&tmp, &p)?;
    Ok(p)
}

fn write_private(p: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    let mut f = o.open(p).with_context(|| format!("open {}", p.display()))?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(())
}
