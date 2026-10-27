//! `vmHost`: whether this machine is a dedicated agent VM, where the VM would
//! be the sandbox (a remote chain's Claude Code without bwrap or Seatbelt, and
//! the owner's peer daemon's new sessions approve-all).
//!
//! Off everywhere until an attested source exists. Nothing the guest can write
//! may turn off the sandbox, and every input this used to read is guest state:
//! the agent user of a Cloud VM has passwordless sudo, so it can write
//! `/etc/cmux/vm-kind` and remove `/srv/team`, and as this user it can write
//! config.json's `vmHost`. So [`Hub::vm_host`] is false: a remote chain's
//! Claude Code runs inside the platform sandbox after its probe and canary
//! (`remote_sandbox.rs`) on a Cloud VM as on any other host, and no session
//! starts approve-all for it (`vm_host_peer_approves`).
//!
//! Still read, for display only (`_acpmux/vm_host`, `acpmux host vm-host`):
//!
//! - `cmuxVm`: whether the creation marker says cmux created this VM for one
//!   owner (`/etc/cmux/vm-kind` reads `owner`, no team files root
//!   `/srv/team`, the rule the Cloud peer bridge uses: `cmux-tui`
//!   `remote_cli/acpmux_peer.rs` `vm_admits`).
//! - `configured`: config.json's `vmHost`, which no longer turns anything on.
//!
//! `_acpmux/vm_host {on: false}` still writes `vmHost: false`; `on: true` is
//! refused everywhere ([`UNATTESTED`]). Who may ask: this machine's unix socket
//! and app, and the owner's peer daemon (`Control::Peer`), never a Web client.

use super::*;

/// The marker files, under `/` outside tests (`Hub::set_vm_marker_root`).
const KIND_FILE: &str = "etc/cmux/vm-kind";
const TEAM_FILES_ROOT: &str = "srv/team";
/// `error.data.reason` when `on` is asked: no attested source says this machine
/// is a dedicated agent VM (module docs).
pub const UNATTESTED: &str = "vmHost.unattested";
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

    /// Whether the creation marker says cmux created this machine as one
    /// owner's VM (module docs). Guest-writable: for display, never trust.
    pub fn cmux_vm(&self) -> bool {
        let root = self.vm_marker_root.lock().unwrap_or_else(|e| e.into_inner()).clone();
        cmux_vm_at(&root)
    }

    /// Whether this machine is a dedicated agent VM: false until an attested
    /// source exists. No marker, team root or config value on this machine
    /// decides it, since the agent can write each of them (module docs).
    pub async fn vm_host(&self) -> bool {
        false
    }

    /// `_acpmux/vm_host`'s view of this machine: `vmHost` (on now: always
    /// false), `cmuxVm` (the creation marker, for display) and `configured`
    /// (config.json's value, null when absent; it turns nothing on).
    pub async fn vm_host_view(&self) -> Value {
        let configured = self.config.read().await.vm_host;
        json!({
            "vmHost": self.vm_host().await,
            "cmuxVm": self.cmux_vm(),
            "configured": configured,
        })
    }

    /// The per-machine toggle (module docs): off writes `vmHost: false`; on is
    /// refused, on a VM cmux created too.
    pub async fn set_vm_host(&self, on: bool) -> Result<Value, RpcError> {
        if on {
            return Err(RpcError::new(
                -32000,
                "vmHost stays off here: no attested source says this is a dedicated agent VM, and nothing on the machine itself (its /etc/cmux/vm-kind or config.json) may turn off the sandbox; remote Claude runs in the sandbox",
            )
            .with_data(json!({"reason": UNATTESTED})));
        }
        {
            let mut cfg = self.config.write().await;
            cfg.vm_host = Some(false);
            cfg.save().map_err(|e| RpcError::internal(format!("save vmHost: {e}")))?;
        }
        Ok(self.vm_host_view().await)
    }
}

#[cfg(test)]
mod tests {
    use super::cmux_vm_at;

    /// A fresh machine root with these markers (removed by the caller).
    fn root(kind: Option<&str>, team: bool) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let d = std::env::temp_dir().join(format!("acpmux-vm-marker-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        if let Some(kind) = kind {
            std::fs::create_dir_all(d.join("etc/cmux")).unwrap();
            std::fs::write(d.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
        }
        if team {
            std::fs::create_dir_all(d.join("srv/team")).unwrap();
        }
        d
    }

    fn admits(kind: Option<&str>, team: bool) -> bool {
        let d = root(kind, team);
        let admitted = cmux_vm_at(&d);
        let _ = std::fs::remove_dir_all(&d);
        admitted
    }

    #[test]
    fn only_an_owner_vm_without_team_files_is_cmux_created() {
        assert!(admits(Some("owner"), false));
        assert!(!admits(Some("owner"), true), "team files: shared");
        assert!(!admits(Some("team"), false), "a team VM");
        assert!(!admits(None, false), "a personal or SSH-added machine");
        assert!(!admits(Some("ownerx"), false));
    }

    /// A team files root this user cannot see into (a root-only `/srv`) is not "absent".
    #[cfg(unix)]
    #[test]
    fn a_team_files_root_that_cannot_be_checked_counts_as_there() {
        use std::os::unix::fs::PermissionsExt;
        let d = root(Some("owner"), true);
        std::fs::set_permissions(d.join("srv"), std::fs::Permissions::from_mode(0o000)).unwrap();
        // Root reads through a 000 folder: this check means nothing there.
        let blocked = std::fs::symlink_metadata(d.join("srv/team")).is_err();
        let admitted = cmux_vm_at(&d);
        std::fs::set_permissions(d.join("srv"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let _ = std::fs::remove_dir_all(&d);
        if blocked {
            assert!(!admitted, "an unreadable /srv/team must refuse");
        }
    }
}
