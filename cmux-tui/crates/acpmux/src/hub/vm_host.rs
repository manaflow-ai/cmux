//! `vmHost`: whether this machine takes a caller's VM boundary, the owner's
//! per-machine toggle. The caller decides the boundary, never this machine
//! (`vm_boundary.rs`): a remote chain's Claude Code runs without bwrap only
//! for a session whose caller asked for it, after the Cloud API told that
//! caller it owns this VM (or its fleet registry says it is a dedicated agent
//! VM). This setting can only refuse that.
//!
//! Nothing on the machine turns anything on. The agent user of a Cloud VM has
//! passwordless sudo, so it can write `/etc/cmux/vm-kind`, remove `/srv/team`,
//! and as this user write config.json. So:
//!
//! - `vmHost` (on now, [`Hub::vm_host`], what the app's switch shows): this
//!   machine takes a caller's boundary ([`Hub::takes_vm_boundary`]: Linux
//!   only, off once config.json says `vmHost: false`). On changes nothing by
//!   itself: with no caller asking, a session runs in the platform sandbox
//!   after its probe and canary (`remote_sandbox.rs`).
//! - `cmuxVm`: whether the creation marker says cmux created this VM for one
//!   owner (`/etc/cmux/vm-kind` reads `owner`, no team files root
//!   `/srv/team`, the rule the Cloud peer bridge uses: `cmux-tui`
//!   `remote_cli/acpmux_peer.rs` `vm_admits`). For display only.
//! - `configured`: config.json's `vmHost`; only `false` means anything.
//!
//! `_acpmux/vm_host {on: false}` writes `vmHost: false`; `{on: true}` removes
//! it, back to taking a caller's boundary. Both apply at once, to the spawns
//! after them, with no restart. Who may ask: this machine's unix socket and
//! app, and the owner's peer daemon (`Control::Peer`), never a Web client.

use super::*;

/// The marker files, under `/` outside tests (`Hub::set_vm_marker_root`).
const KIND_FILE: &str = "etc/cmux/vm-kind";
const TEAM_FILES_ROOT: &str = "srv/team";
/// `error.data.reason` when a Web client asks to change it.
pub const REMOTE_REFUSED: &str = "vmHost.remote";

/// Whether the machine under `root` is a VM cmux created for one owner: a
/// readable `vm-kind` of `owner`, and no team files root.
pub(crate) fn cmux_vm_at(root: &Path) -> bool {
    // Fail closed, as the peer bridge's `team_files_present`: only "not found" means no team
    // files root; one this user cannot stat (a root-only `/srv/team`) counts as there.
    match std::fs::symlink_metadata(root.join(TEAM_FILES_ROOT)) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        _ => return false,
    }
    std::fs::read_to_string(root.join(KIND_FILE)).is_ok_and(|kind| kind.trim() == "owner")
}

impl Hub {
    /// Read the creation marker under `root` instead of `/` (tests).
    pub fn set_vm_marker_root(&self, root: PathBuf) {
        *self.vm_marker_root.lock().unwrap_or_else(|e| e.into_inner()) = root;
    }

    /// The folder the machine's `etc/cmux` markers are read under: `/`
    /// outside tests (`agent_login.rs` reads `vm-kind` and `agent-auth.sh` there).
    pub(crate) fn vm_marker_root(&self) -> PathBuf {
        self.vm_marker_root.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The gateway fallback (`agent_login::GATEWAY_FALLBACK_ENV`) for `session`, whose Claude has
    /// no credential on a machine whose team cmux's gateway serves: records the gateway as
    /// Claude's way in here (`cr use team claude`) and restarts the chat's agent on it, after the
    /// turn under way when there is one. Whether the choice was recorded.
    pub(crate) fn use_gateway_now(self: &Arc<Self>, session: &Arc<Session>) -> bool {
        let machine = crate::agent_login::Machine {
            root: self.vm_marker_root(),
            home: dirs::home_dir().unwrap_or_default(),
        };
        match machine.choose_team(crate::agent_login::Agent::Claude) {
            Ok(true) => {}
            Ok(false) => return false,
            Err(e) => {
                tracing::warn!(session = %session.id, error = %e, "gateway fallback: record the choice");
                return false;
            }
        }
        let hub = Arc::clone(self);
        let ids = std::collections::BTreeSet::from([session.id.clone()]);
        // task-owner: one restart of one chat's agent; it ends with the restart.
        drop(tokio::spawn(async move {
            let _ = hub.restart_harnesses(None, Some(&ids)).await;
        }));
        true
    }

    /// Whether the creation marker says cmux created this machine as one
    /// owner's VM (module docs). Guest-writable: for display, never trust.
    pub fn cmux_vm(&self) -> bool {
        let root = self.vm_marker_root.lock().unwrap_or_else(|e| e.into_inner()).clone();
        cmux_vm_at(&root)
    }

    /// Whether this machine takes a caller's VM boundary now (module docs).
    pub async fn vm_host(&self) -> bool {
        self.takes_vm_boundary().await
    }

    /// `_acpmux/vm_host`'s view of this machine: `vmHost` (on now), `cmuxVm`
    /// (the creation marker, for display) and `configured` (config.json's
    /// value, null when absent).
    pub async fn vm_host_view(&self) -> Value {
        let configured = self.config.read().await.vm_host;
        json!({
            "vmHost": self.vm_host().await,
            "cmuxVm": self.cmux_vm(),
            "configured": configured,
        })
    }

    /// The per-machine toggle (module docs): off writes `vmHost: false`, on
    /// removes it.
    pub async fn set_vm_host(&self, on: bool) -> Result<Value, RpcError> {
        {
            let mut cfg = self.config.write().await;
            cfg.vm_host = if on { None } else { Some(false) };
            cfg.save().map_err(|e| RpcError::internal(format!("save vmHost: {e}")))?;
        }
        Ok(self.vm_host_view().await)
    }
}

#[cfg(test)]
mod tests;
