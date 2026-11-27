//! The subset of Tailscale's JSON the node reads (ipnstate.Status,
//! apitype.WhoIsResponse, ipn.Notify). Unknown fields are ignored, so a
//! newer Tailscale only adds data.

use std::collections::HashMap;

use serde::Deserialize;

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Status {
    pub backend_state: String,
    #[serde(rename = "AuthURL")]
    pub auth_url: String,
    #[serde(rename = "TailscaleIPs")]
    pub tailscale_ips: Option<Vec<String>>,
    #[serde(rename = "Self")]
    pub self_status: Option<PeerStatus>,
    pub current_tailnet: Option<TailnetInfo>,
    /// Keyed by the decimal user id.
    pub user: Option<HashMap<String, UserProfile>>,
}

impl Status {
    pub fn state(&self) -> BackendState {
        BackendState::from_name(&self.backend_state)
    }

    /// The signed-in user that owns this node; None for a tagged node or before sign-in.
    pub fn owner(&self) -> Option<&UserProfile> {
        let me = self.self_status.as_ref()?;
        if me.tags.as_ref().is_some_and(|tags| !tags.is_empty()) {
            return None;
        }
        self.user.as_ref()?.get(&me.user_id.to_string())
    }

    /// This node's MagicDNS name without the trailing dot.
    pub fn dns_name(&self) -> Option<String> {
        let name = self.self_status.as_ref()?.dns_name.trim_end_matches('.');
        (!name.is_empty()).then(|| name.to_owned())
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct PeerStatus {
    #[serde(rename = "ID")]
    pub id: String,
    pub host_name: String,
    #[serde(rename = "DNSName")]
    pub dns_name: String,
    #[serde(rename = "TailscaleIPs")]
    pub tailscale_ips: Option<Vec<String>>,
    #[serde(rename = "UserID")]
    pub user_id: i64,
    pub tags: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct TailnetInfo {
    pub name: String,
    #[serde(rename = "MagicDNSSuffix")]
    pub magic_dns_suffix: String,
    #[serde(rename = "MagicDNSEnabled")]
    pub magic_dns_enabled: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct UserProfile {
    #[serde(rename = "ID")]
    pub id: i64,
    pub login_name: String,
    pub display_name: String,
}

/// Who is at a tailnet address, as the node's control plane says.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct WhoIs {
    pub node: Option<WhoIsNode>,
    pub user_profile: Option<UserProfile>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct WhoIsNode {
    #[serde(rename = "StableID")]
    pub stable_id: String,
    pub name: String,
    /// The owning user's id (meaningless for tagged nodes).
    pub user: i64,
    /// Nonzero for a node shared into the tailnet by another owner.
    pub sharer: i64,
    pub tags: Option<Vec<String>>,
}

impl WhoIs {
    pub fn tags(&self) -> &[String] {
        self.node.as_ref().and_then(|node| node.tags.as_deref()).unwrap_or(&[])
    }

    pub fn is_tagged(&self) -> bool {
        !self.tags().is_empty()
    }

    /// A principal string for logs and audit: `user:alice@example.com` or `tag:ci`.
    pub fn principal(&self) -> String {
        if let Some(tag) = self.tags().first() {
            return tag.clone();
        }
        match &self.user_profile {
            Some(user) if !user.login_name.is_empty() => format!("user:{}", user.login_name),
            _ => "unknown".into(),
        }
    }
}

/// One message from the node's IPN bus (`/localapi/v0/watch-ipn-bus`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub struct Notify {
    pub err_message: Option<String>,
    pub state: Option<i32>,
    #[serde(rename = "BrowseToURL")]
    pub browse_to_url: Option<String>,
    pub login_finished: Option<serde_json::Value>,
}

impl Notify {
    pub fn backend_state(&self) -> Option<BackendState> {
        self.state.map(BackendState::from_code)
    }
}

/// ipn.State.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendState {
    NoState,
    InUseOtherUser,
    NeedsLogin,
    NeedsMachineAuth,
    Stopped,
    Starting,
    Running,
    Unknown,
}

impl BackendState {
    pub fn from_code(code: i32) -> Self {
        match code {
            0 => Self::NoState,
            1 => Self::InUseOtherUser,
            2 => Self::NeedsLogin,
            3 => Self::NeedsMachineAuth,
            4 => Self::Stopped,
            5 => Self::Starting,
            6 => Self::Running,
            _ => Self::Unknown,
        }
    }

    pub fn from_name(name: &str) -> Self {
        match name {
            "NoState" => Self::NoState,
            "InUseOtherUser" => Self::InUseOtherUser,
            "NeedsLogin" => Self::NeedsLogin,
            "NeedsMachineAuth" => Self::NeedsMachineAuth,
            "Stopped" => Self::Stopped,
            "Starting" => Self::Starting,
            "Running" => Self::Running,
            _ => Self::Unknown,
        }
    }
}
