//! `meshRelay` in config.json: the mesh hub over HTTPS (`mesh_http.rs`) and who may run
//! lifecycle controls through it.

use serde::{Deserialize, Serialize};

/// `meshRelay` in config.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeshRelayConfig {
    /// The hub's origin, `https://` (`http://` only for a loopback address).
    pub url: String,
    /// The program that prints a cmux access token, and its own arguments.
    #[serde(default)]
    pub token_command: Vec<String>,
    /// Team-scoped addresses and inboxes (`@member/agent`, `@team/role`). On wherever a hub is
    /// configured; `"teamMessaging": false` turns them off (Leo, 2026-10-29: "can this be a proper
    /// feat inside acpmux/the multiplayer and team situation?").
    #[serde(default = "team_messaging_on", skip_serializing_if = "is_on")]
    pub team_messaging: bool,
    /// Read the joined machine credential from the owner-only store.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
    /// Senders whose authenticated mesh messages may run lifecycle controls here. An empty
    /// list is fail-closed. `host join` writes one [`MeshControlFrom::same_user`] entry; any
    /// other sender the machine owner opts in by its daemon id.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub control_from: Vec<MeshControlFrom>,
}

/// An owner-configured control sender: one daemon by its hub-stamped id (`daemonId`), or every
/// daemon the hub stamps with this machine's own person (`sameUser`, the person recorded at
/// `host join`). Claimed session, name and host fields are never authority, and only listed ops
/// are granted.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeshControlFrom {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub daemon_id: String,
    /// Any daemon whose hub-stamped `from.user` is this machine's own person (Tailscale's
    /// `autogroup:self`): "allow access for any user that is authenticated as the same user as
    /// the source". A machine with no recorded person grants nothing through it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub same_user: bool,
    /// Omitted means all three lifecycle operations; an explicit empty list grants nothing.
    #[serde(default = "lifecycle_ops")]
    pub ops: Vec<String>,
}

impl Default for MeshRelayConfig {
    fn default() -> Self {
        Self {
            url: String::new(),
            token_command: Vec::new(),
            team_messaging: true,
            credential: None,
            control_from: Vec::new(),
        }
    }
}

fn team_messaging_on() -> bool {
    true
}

fn is_on(on: &bool) -> bool {
    *on
}

/// The control op that moves a chat here from another of the person's machines
/// (`hub/transfer_pull.rs`). Off unless an entry's `ops` lists it.
pub const MOVE_OP: &str = "move";
/// The control op that gives up a move a source's watch ended (`transfer_forget` here).
pub const MOVE_FORGET_OP: &str = "move_forget";

fn lifecycle_ops() -> Vec<String> {
    ["start", "resume", "stop"].map(str::to_owned).to_vec()
}

impl MeshControlFrom {
    /// The entry `host join` writes: the person's own other machines, for every lifecycle op.
    pub fn same_user() -> Self {
        Self { daemon_id: String::new(), same_user: true, ops: lifecycle_ops() }
    }

    /// Whether this entry lets `from` run `op` here. `from` is the hub-stamped sender (its
    /// `daemonId` and `user` come from the sender's verified credential); `own_user` is the
    /// person this machine recorded at join, if any. A `read` (one page of a session, nothing
    /// changed) is granted to a sender this entry trusts with any lifecycle op, or one that lists
    /// `read`; an explicit empty list grants nothing.
    ///
    /// A move (`move`, and `move_forget`, which ends one) is granted only by an entry that lists
    /// `move` itself, never by the lifecycle default or `read`, and only through `sameUser`: a
    /// chat moves between the person's own machines alone (`hub/transfer_pull.rs`). It also
    /// needs the sender's hub-stamped daemon id, which the target dials back for the pages.
    pub fn allows(&self, from: &crate::mesh::Sender, own_user: Option<&str>, op: &str) -> bool {
        let granted = match op {
            "start" | "resume" | "stop" => self.ops.iter().any(|allowed| allowed == op),
            "read" => self
                .ops
                .iter()
                .any(|allowed| matches!(allowed.as_str(), "start" | "resume" | "stop" | "read")),
            MOVE_OP | MOVE_FORGET_OP => self.ops.iter().any(|allowed| allowed == MOVE_OP),
            _ => false,
        };
        if !granted {
            return false;
        }
        fn present(value: Option<&str>) -> Option<&str> {
            value.filter(|value| !value.is_empty())
        }
        let by_daemon = present(Some(&self.daemon_id))
            .is_some_and(|id| present(from.daemon_id.as_deref()) == Some(id));
        let by_user = self.same_user
            && present(own_user).is_some_and(|own| present(from.user.as_deref()) == Some(own));
        if matches!(op, MOVE_OP | MOVE_FORGET_OP) {
            return by_user && present(from.daemon_id.as_deref()).is_some();
        }
        by_daemon || by_user
    }
}

impl MeshRelayConfig {
    /// The origin without a trailing slash, when it is one the relay may use.
    pub fn origin(&self) -> Result<String, String> {
        let url = reqwest::Url::parse(self.url.trim())
            .map_err(|e| format!("meshRelay.url is no URL: {e}"))?;
        let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
        if !(url.scheme() == "https" || (url.scheme() == "http" && loopback)) {
            return Err("meshRelay.url must be https (http only on a loopback address)".into());
        }
        // Nothing secret may ride in the URL: it is logged, and the token goes in a header.
        if !url.username().is_empty() || url.password().is_some() {
            return Err("meshRelay.url must carry no user or password".into());
        }
        if url.query().is_some() || url.fragment().is_some() {
            return Err("meshRelay.url must carry no query or fragment".into());
        }
        if self.credential.as_deref() != Some("join")
            && self.token_command.first().is_none_or(|p| p.trim().is_empty())
        {
            return Err("meshRelay.tokenCommand names no program".into());
        }
        let path = url.path().trim_end_matches('/');
        Ok(format!("{}{path}", url.origin().ascii_serialization()))
    }

    /// What a log may say of the hub: its scheme, host and port, never its path.
    pub fn shown(&self) -> String {
        reqwest::Url::parse(self.url.trim())
            .map(|u| u.origin().ascii_serialization())
            .unwrap_or_default()
    }
}
