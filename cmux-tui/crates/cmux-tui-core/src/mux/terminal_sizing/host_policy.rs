//! The per-Mac terminal sizing policy (`host-size-policy-v1`,
//! cmux-next-ios/PROTOCOL.md "Terminal sizing policy"): one preference of
//! this daemon's host, stored in its settings file (`mobile.terminalSizing`,
//! `mobile.terminalSizingOrder`) and applied to every terminal without a
//! terminal override or workspace default.
//!
//! The setting names devices, not participants: `mac` is this host's own
//! views (a desktop device kind on a connection that is not a phone's
//! spliced lane), `device:<id>` the views of one device id. Each terminal
//! expands those tokens into the engine priority keys of its current
//! participants, again whenever its participants, their identities or the
//! setting change (`Mux::refresh_host_policy_locked`), so the
//! engine itself stays the shared reducer of docs/shared-terminal-sizing.md.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::*;
use crate::panic_free::RecoverPoison;
use crate::sizing_policy::TerminalSizingMode;

/// The daemon serves `get-host-size-policy` and `set-host-size-policy`.
pub const HOST_SIZE_POLICY_CAPABILITY: &str = "host-size-policy-v1";
/// Settings key of the mode.
pub(crate) const MODE_SETTING: &str = "mobile.terminalSizing";
/// Settings key of the priority order.
pub(crate) const ORDER_SETTING: &str = "mobile.terminalSizingOrder";
/// Token of this host's own views.
pub(crate) const MAC_TOKEN: &str = "mac";
/// Prefix of a device token.
const DEVICE_PREFIX: &str = "device:";
/// Most tokens an order keeps.
pub(crate) const MAX_ORDER: usize = 32;

/// How a shared terminal is sized when several devices show it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HostSizeMode {
    /// Fit the smallest viewer: every viewer sees the whole grid.
    #[default]
    Smallest,
    /// Prefer this Mac: its own views set the grid while one counts.
    Mac,
    /// Prefer the active device: the viewer that typed or focused last.
    Latest,
    /// The order in [`HostSizePolicy::order`], highest first.
    Priority,
}

impl HostSizeMode {
    pub(crate) fn parse(raw: &str) -> Option<Self> {
        match raw {
            "smallest" => Some(Self::Smallest),
            "mac" => Some(Self::Mac),
            "latest" => Some(Self::Latest),
            "priority" => Some(Self::Priority),
            _ => None,
        }
    }
}

/// The host's policy as stored.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct HostSizePolicy {
    pub mode: HostSizeMode,
    /// Device tokens, highest first.
    pub order: Vec<String>,
}

/// Whether `token` is `mac` or `device:<id>` with a 1 to 128 character id of
/// `[A-Za-z0-9_.:-]`.
pub(crate) fn valid_token(token: &str) -> bool {
    if token == MAC_TOKEN {
        return true;
    }
    token.strip_prefix(DEVICE_PREFIX).is_some_and(|id| {
        (1..=128).contains(&id.len())
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
    })
}

impl HostSizePolicy {
    /// The policy the settings values give: an unknown mode reads as the
    /// default, invalid and repeated tokens are dropped, at most
    /// [`MAX_ORDER`] are kept.
    pub(crate) fn from_settings(mode: Option<&Value>, order: Option<&Value>) -> Self {
        let mode = mode.and_then(Value::as_str).and_then(HostSizeMode::parse).unwrap_or_default();
        let mut tokens: Vec<String> = Vec::new();
        for token in order.and_then(Value::as_array).into_iter().flatten() {
            let Some(token) = token.as_str() else { continue };
            if valid_token(token) && !tokens.iter().any(|known| known == token) {
                tokens.push(token.to_string());
            }
            if tokens.len() == MAX_ORDER {
                break;
            }
        }
        Self { mode, order: tokens }
    }

    /// The engine policy for a terminal whose participants are
    /// `(priority_key, is_this_mac, device_id)`, in attach order.
    pub(crate) fn expand(
        &self,
        participants: &[(String, bool, Option<String>)],
    ) -> TerminalSizingPolicy {
        let keys_for = |token: &str| -> Vec<String> {
            participants
                .iter()
                .filter(|(_, mac, device)| match token.strip_prefix(DEVICE_PREFIX) {
                    Some(id) => device.as_deref() == Some(id),
                    None => token == MAC_TOKEN && *mac,
                })
                .map(|(key, _, _)| key.clone())
                .collect()
        };
        let priority = |tokens: &[&str]| {
            let mut keys: Vec<String> = Vec::new();
            for token in tokens {
                for key in keys_for(token) {
                    if !keys.contains(&key) {
                        keys.push(key);
                    }
                }
            }
            TerminalSizingPolicy::new(TerminalSizingMode::Priority, keys, None)
        };
        match self.mode {
            HostSizeMode::Smallest => {
                TerminalSizingPolicy::new(TerminalSizingMode::Smallest, Vec::new(), None)
            }
            HostSizeMode::Latest => {
                TerminalSizingPolicy::new(TerminalSizingMode::Latest, Vec::new(), None)
            }
            HostSizeMode::Mac => priority(&[MAC_TOKEN]),
            HostSizeMode::Priority => {
                priority(&self.order.iter().map(String::as_str).collect::<Vec<_>>())
            }
        }
    }
}

impl Mux {
    /// `(priority_key, is_this_mac, device_id)` of each participant of
    /// `runtime`, in attach order. A relay sub-view is never this Mac; a
    /// view is this Mac when its device kind is a desktop and the daemon
    /// verified its connection is local (`Mux::is_this_mac_connection`).
    fn host_policy_participants(
        &self,
        sizing: &ClientSizingState,
        runtime: SurfaceId,
    ) -> Vec<(String, String, bool, Option<String>)> {
        let Some(entry) = sizing.terminal_sizing.get(&runtime) else { return Vec::new() };
        entry
            .engine
            .state()
            .participants
            .iter()
            .map(|row| {
                let member = entry.members.get(&row.participant.id);
                let mac = row.participant.device_kind.is_desktop()
                    && member.is_some_and(|member| {
                        member.view.is_none() && self.is_this_mac_connection(member.client)
                    });
                // A relay sub-view names a device only when this Mac relays
                // it; a sub-view from any other connection is never ranked
                // by a `device:` token.
                let trusted_device = member.is_none_or(|member| {
                    member.view.is_none() || self.is_this_mac_connection(member.client)
                });
                (
                    row.participant.id.clone(),
                    row.priority_key.clone(),
                    mac,
                    row.participant.device_id.clone().filter(|_| trusted_device),
                )
            })
            .collect()
    }

    /// Whether `runtime` follows the host policy: no terminal override, no
    /// workspace default, and the settings owner has published one.
    fn follows_host_policy(&self, sizing: &ClientSizingState, runtime: SurfaceId) -> bool {
        if sizing.host_policy.is_none() || sizing.terminal_size_policies.contains_key(&runtime) {
            return false;
        }
        self.workspace_default_of(sizing, runtime, runtime).is_none()
    }

    /// The workspace default a terminal follows: the one of `placement`'s
    /// workspace, else of any other placement's (a terminal shown in two
    /// workspaces keeps either's default; the host policy never replaces
    /// it). The same rule for `resolved_size_policy` and the host policy.
    pub(in crate::mux) fn workspace_default_of(
        &self,
        sizing: &ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
    ) -> Option<TerminalSizingPolicy> {
        let default_of = |surface: SurfaceId| {
            self.surface_workspace(surface)
                .and_then(|workspace| sizing.workspace_size_policies.get(&workspace).cloned())
        };
        if sizing.workspace_size_policies.is_empty() {
            // The common case: no workspace has a default, so no placement
            // needs looking up (and no surface walk under the sizing lock).
            return None;
        }
        default_of(placement).or_else(|| {
            let entry = sizing.terminal_sizing.get(&runtime);
            entry
                .into_iter()
                .flat_map(|entry| entry.placements.iter().copied())
                .find_map(default_of)
                .or_else(|| self.runtime_placements(runtime).into_iter().find_map(default_of))
        })
    }

    /// Every live placement of terminal `runtime` (each view of it in any
    /// workspace), the runtime's own surface included. Walks the surfaces:
    /// called only while some workspace has a default.
    pub(in crate::mux) fn runtime_placements(&self, runtime: SurfaceId) -> Vec<SurfaceId> {
        self.with_state(|state| {
            let mut placements = state
                .surfaces
                .values()
                .filter(|surface| surface.terminal_runtime_id() == Some(runtime))
                .map(|surface| surface.id)
                .collect::<Vec<_>>();
            placements.sort_unstable();
            placements
        })
    }

    /// The host policy expanded for `runtime`'s current participants, or
    /// `None` when the terminal does not follow it.
    pub(in crate::mux) fn host_policy_for(
        &self,
        sizing: &ClientSizingState,
        runtime: SurfaceId,
    ) -> Option<TerminalSizingPolicy> {
        if !self.follows_host_policy(sizing, runtime) {
            return None;
        }
        let participants = self
            .host_policy_participants(sizing, runtime)
            .into_iter()
            .map(|(_, key, mac, device)| (key, mac, device))
            .collect::<Vec<_>>();
        sizing.host_policy.as_ref().map(|host| host.expand(&participants))
    }

    /// Re-expands the host policy of `runtime` after its participants or
    /// their identities changed. Marks the size state when it changed.
    pub(in crate::mux) fn refresh_host_policy_locked(
        &self,
        sizing: &mut ClientSizingState,
        runtime: SurfaceId,
    ) {
        let Some(policy) = self.host_policy_for(sizing, runtime) else { return };
        let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { return };
        if *entry.engine.policy() == policy {
            return;
        }
        let changed = entry.engine.set_policy(policy);
        sizing.note_size_state(runtime, changed);
    }

    /// The host policy in effect: the settings owner's, else (only before
    /// the owner has read the settings file) `latest`, the engine default
    /// the terminals use until then (`resolved_size_policy`).
    pub fn host_size_policy(&self) -> HostSizePolicy {
        self.client_sizing
            .lock()
            .recover_poison()
            .host_policy
            .clone()
            .unwrap_or_else(|| HostSizePolicy { mode: HostSizeMode::Latest, order: Vec::new() })
    }

    /// The participant ids of `surface`'s terminal that are this Mac's views.
    pub fn host_mac_participants(&self, surface: SurfaceId) -> Vec<String> {
        let Some(runtime) = self.surface(surface).and_then(|surface| surface.terminal_runtime_id())
        else {
            return Vec::new();
        };
        let sizing = self.client_sizing.lock().recover_poison();
        self.host_policy_participants(&sizing, runtime)
            .into_iter()
            .filter_map(|(id, _, mac, _)| mac.then_some(id))
            .collect()
    }

    /// Adopts the host policy the settings file holds and re-applies it to
    /// every terminal that follows it. Called by the settings owner when it
    /// opens and on every change of either key; a no-op when unchanged.
    /// `revision` is the settings store revision the policy was read at:
    /// a policy from an older revision than the adopted one is dropped, so
    /// two changes adopted out of order (each adopts after the store lock is
    /// released) still leave the newest in effect.
    pub(crate) fn adopt_host_size_policy(&self, policy: HostSizePolicy, revision: u64) {
        let mut sizing = self.client_sizing.lock().recover_poison();
        if sizing.host_policy_revision.is_some_and(|adopted| revision < adopted) {
            return;
        }
        sizing.host_policy_revision = Some(revision);
        if sizing.host_policy.as_ref() == Some(&policy) {
            return;
        }
        sizing.host_policy = Some(policy);
        let runtimes = sizing.terminal_sizing.keys().copied().collect::<Vec<_>>();
        let mut owner_changes = HashSet::new();
        for runtime in runtimes {
            let owners_before = sizing.terminal_owner_clients(runtime);
            self.refresh_host_policy_locked(&mut sizing, runtime);
            self.apply_terminal_grid(&sizing, runtime);
            owner_changes.extend(
                owners_before
                    .symmetric_difference(&sizing.terminal_owner_clients(runtime))
                    .copied(),
            );
        }
        drop(sizing);
        self.publish_size_states();
        self.emit_client_sizing_changes(owner_changes);
    }

    /// Writes the host policy to the settings file (`order: None` keeps the
    /// stored order). The settings owner's change event applies it.
    pub fn set_host_size_policy(
        self: &Arc<Self>,
        mode: HostSizeMode,
        order: Option<Vec<String>>,
    ) -> anyhow::Result<HostSizePolicy> {
        if let Some(order) = &order {
            anyhow::ensure!(
                order.len() <= MAX_ORDER,
                "bad request: order takes at most {MAX_ORDER} tokens"
            );
            if let Some(token) = order.iter().find(|token| !valid_token(token)) {
                anyhow::bail!("bad request: invalid order token {token:?}; use mac or device:<id>");
            }
        }
        // The person's own preference: the caller checked it is the verified
        // app or a phone's lane (`Mux::may_set_host_size_policy`).
        let meta = cmux_config::WriteMeta {
            origin: cmux_config::Origin::App,
            idempotency_key: None,
            if_revision: None,
        };
        let mode_value = serde_json::to_value(mode)?;
        let set = |key: &str, value: Value| {
            self.settings_apply(cmux_config::Op::Set {
                target: cmux_config::Target::Key(key.to_string()),
                value,
                meta: meta.clone(),
            })
            .map_err(|refusal| anyhow::anyhow!("settings refused {key}: {refusal:?}"))
        };
        if let Some(order) = order {
            set(ORDER_SETTING, Value::from(order))?;
        }
        set(MODE_SETTING, mode_value)?;
        Ok(self.host_size_policy())
    }
}

/// Reads the host policy from a settings state.
pub(crate) fn host_policy_from_state(state: &cmux_config::State) -> HostSizePolicy {
    let value = |key: &str| {
        let view = state.get(&cmux_config::Target::Key(key.to_string()));
        view.row.and_then(|row| row.value).or(view.value)
    };
    HostSizePolicy::from_settings(value(MODE_SETTING).as_ref(), value(ORDER_SETTING).as_ref())
}

/// Whether a settings change touches the host policy.
pub(crate) fn touches_host_policy(keys: &[String]) -> bool {
    keys.iter().any(|key| key == MODE_SETTING || key == ORDER_SETTING)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn host_policy_tokens_expand_to_the_terminals_participants() {
        let participants = vec![
            ("anon:c1/mac".to_string(), true, None),
            ("anon:c2/iphone/p1".to_string(), false, Some("p1".to_string())),
            ("anon:c3/iphone/p2".to_string(), false, Some("p2".to_string())),
        ];
        let policy = HostSizePolicy::from_settings(
            Some(&json!("priority")),
            Some(&json!(["device:p2", "bad token", "mac", "device:p2", 7])),
        );
        assert_eq!(policy.order, vec!["device:p2".to_string(), "mac".to_string()]);
        let expanded = policy.expand(&participants);
        assert_eq!(expanded.mode, TerminalSizingMode::Priority);
        assert_eq!(expanded.priority, vec!["anon:c3/iphone/p2", "anon:c1/mac"]);
        let mac =
            HostSizePolicy { mode: HostSizeMode::Mac, order: Vec::new() }.expand(&participants);
        assert_eq!(mac.priority, vec!["anon:c1/mac"]);
        assert_eq!(
            HostSizePolicy::from_settings(Some(&json!("nope")), None).mode,
            HostSizeMode::Smallest
        );
    }
}
