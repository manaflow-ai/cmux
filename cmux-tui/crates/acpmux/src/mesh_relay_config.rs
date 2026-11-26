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
    /// The widest permission policy a control through this entry runs under here. Omitted means
    /// `ask`: a start settles into asking mode as a remote start does, and one asking for more is
    /// held to this. `approve-all` makes the sender this machine's owner for the control, as the
    /// owner's own daemon over the peer token is (cmux#50026): its start runs in the policy it
    /// names. `host join` writes it on the person's own `sameUser` entry ([`Self::same_user`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_policy: Option<crate::config::PermissionPolicy>,
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
/// The control op that asks the source machine to move one of its chats elsewhere. It has the
/// same owner-only grant as [`MOVE_OP`], but is distinct so a caller cannot smuggle a source-side
/// move through the target-side transfer handler.
pub const MOVE_OUT_OP: &str = "move_out";
/// The control op that gives up a move a source's watch ended (`transfer_forget` here).
pub const MOVE_FORGET_OP: &str = "move_forget";

fn lifecycle_ops() -> Vec<String> {
    ["start", "resume", "stop"].map(str::to_owned).to_vec()
}

impl MeshControlFrom {
    /// The entry `host join` writes: the person's own other machines, for every lifecycle op.
    pub fn same_user() -> Self {
        Self {
            daemon_id: String::new(),
            same_user: true,
            ops: lifecycle_ops(),
            max_policy: Some(crate::config::PermissionPolicy::ApproveAll),
        }
    }

    /// The `sameUser` entry a join wrote before `maxPolicy` existed, untouched by its owner. A
    /// join or `host join --status` upgrades it to [`Self::same_user`]; any other entry stays as
    /// the owner left it.
    pub fn is_unmarked_join_entry(&self) -> bool {
        self.same_user
            && self.daemon_id.is_empty()
            && self.ops == lifecycle_ops()
            && self.max_policy.is_none()
    }

    /// The widest policy a control through this entry runs under: [`Self::max_policy`], else
    /// `ask`.
    pub fn policy_cap(&self) -> crate::config::PermissionPolicy {
        self.max_policy.unwrap_or(crate::config::PermissionPolicy::Ask)
    }

    /// Whether this entry lets `from` run `op` here. `from` is the hub-stamped sender (its
    /// `daemonId` and `user` come from the sender's verified credential); `own_user` is the
    /// person this machine recorded at join, if any. A `read` (one page of a session, nothing
    /// changed) is granted to a sender this entry trusts with any lifecycle op, or one that lists
    /// `read`; an explicit empty list grants nothing.
    ///
    /// A move (`move`, `move_out`, and `move_forget`, which ends one) is granted only by an entry
    /// that lists `move` itself, never by the lifecycle default or `read`, and only through
    /// `sameUser`: a chat moves between the person's own machines alone (`hub/transfer_pull.rs`). It also
    /// needs the sender's hub-stamped daemon id, which the target dials back for the pages.
    pub fn allows(&self, from: &crate::mesh::Sender, own_user: Option<&str>, op: &str) -> bool {
        let granted = match op {
            "start" | "resume" | "stop" => self.ops.iter().any(|allowed| allowed == op),
            "read" => self
                .ops
                .iter()
                .any(|allowed| matches!(allowed.as_str(), "start" | "resume" | "stop" | "read")),
            MOVE_OP | MOVE_OUT_OP | MOVE_FORGET_OP => {
                self.ops.iter().any(|allowed| allowed == MOVE_OP)
            }
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
        if matches!(op, MOVE_OP | MOVE_OUT_OP | MOVE_FORGET_OP) {
            return by_user && present(from.daemon_id.as_deref()).is_some();
        }
        by_daemon || by_user
    }
}

/// How much a policy runs without asking: nothing (`ask`, `deny-all`), reads (`approve-reads`,
/// `review`), reads and edits (`approve-edits`), everything (`approve-all`).
pub fn policy_reach(policy: crate::config::PermissionPolicy) -> u8 {
    use crate::config::PermissionPolicy as P;
    match policy {
        P::Ask | P::DenyAll => 0,
        P::ApproveReads | P::Review => 1,
        P::ApproveEdits => 2,
        P::ApproveAll => 3,
    }
}

/// The `sameUser` entry an older join wrote (no `maxPolicy`, untouched by its owner) becomes
/// the one a join writes now, so the person's own machines keep starting chats on each other in
/// the policy they name. An entry the owner changed keeps its choice. True when one changed.
pub fn upgrade_join_entries(control_from: &mut [MeshControlFrom]) -> bool {
    let mut changed = false;
    for entry in control_from.iter_mut().filter(|entry| entry.is_unmarked_join_entry()) {
        *entry = MeshControlFrom::same_user();
        changed = true;
    }
    changed
}

/// The widest cap among `entries` that grant `op` to `from` here (each entry's
/// [`MeshControlFrom::policy_cap`]), or None when none grants it.
pub fn control_cap(
    entries: &[MeshControlFrom],
    from: &crate::mesh::Sender,
    own_user: Option<&str>,
    op: &str,
) -> Option<crate::config::PermissionPolicy> {
    entries
        .iter()
        .filter(|entry| entry.allows(from, own_user, op))
        .map(MeshControlFrom::policy_cap)
        .max_by_key(|cap| policy_reach(*cap))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh::Sender;

    fn sender(user: Option<&str>, daemon: Option<&str>) -> Sender {
        Sender {
            user: user.map(str::to_owned),
            daemon_id: daemon.map(str::to_owned),
            ..Sender::default()
        }
    }

    #[test]
    fn move_out_has_the_same_owner_only_grant_as_move() {
        let entry = MeshControlFrom {
            same_user: true,
            ops: vec![MOVE_OP.to_owned()],
            ..Default::default()
        };
        let own = sender(Some("person"), Some("daemon"));
        assert!(entry.allows(&own, Some("person"), MOVE_OP));
        assert!(entry.allows(&own, Some("person"), MOVE_OUT_OP));
        assert!(!entry.allows(&own, Some("other"), MOVE_OUT_OP));
        assert!(!entry.allows(&sender(None, Some("daemon")), Some("person"), MOVE_OUT_OP));
        assert!(!entry.allows(&sender(Some("person"), None), Some("person"), MOVE_OUT_OP));
        assert!(!entry.allows(&own, None, MOVE_OUT_OP));
    }

    #[test]
    fn move_out_cannot_be_granted_by_daemon_id_or_lifecycle_defaults() {
        let by_daemon = MeshControlFrom {
            daemon_id: "daemon".into(),
            ops: vec![MOVE_OP.into()],
            ..Default::default()
        };
        let from = sender(Some("person"), Some("daemon"));
        assert!(!by_daemon.allows(&from, Some("person"), MOVE_OUT_OP));
        let default = MeshControlFrom::same_user();
        assert!(!default.allows(&from, Some("person"), MOVE_OUT_OP));
        let only_move_out = MeshControlFrom { ops: vec![MOVE_OUT_OP.into()], ..default };
        assert!(!only_move_out.allows(&from, Some("person"), MOVE_OUT_OP));
    }

    #[test]
    fn an_older_join_entry_runs_at_the_cap_a_join_writes_now_and_an_owner_choice_stays() {
        // 2026-11-25: lane VMs joined before `maxPolicy` kept `{"sameUser": true}` (cap `ask`),
        // so the coordinator's `acpmux new --machine LANE --policy approve-all` was refused.
        let own = sender(Some("person"), Some("mac"));
        let unmarked: MeshControlFrom =
            serde_json::from_value(serde_json::json!({"sameUser": true})).unwrap();
        let chosen: MeshControlFrom =
            serde_json::from_value(serde_json::json!({"sameUser": true, "maxPolicy": "ask"}))
                .unwrap();
        let mut entries = vec![unmarked.clone()];
        assert_eq!(
            control_cap(&entries, &own, Some("person"), "start"),
            Some(crate::config::PermissionPolicy::Ask)
        );
        assert!(upgrade_join_entries(&mut entries));
        assert_eq!(entries, vec![MeshControlFrom::same_user()]);
        assert_eq!(
            control_cap(&entries, &own, Some("person"), "start"),
            Some(crate::config::PermissionPolicy::ApproveAll)
        );
        let mut kept = vec![chosen.clone()];
        assert!(!upgrade_join_entries(&mut kept));
        assert_eq!(kept, vec![chosen]);
    }
}
