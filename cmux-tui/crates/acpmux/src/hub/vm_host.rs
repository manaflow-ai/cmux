//! `vmHost`: whether this machine is a dedicated agent VM, where the VM is the
//! sandbox (`remote_sandbox.rs`: a remote chain's Claude Code runs without
//! Seatbelt, and the owner's peer daemon's new sessions start approve-all).
//!
//! On by default on a VM cmux itself created, off everywhere else (Leo,
//! 2026-10-26: "we wanna make it ergo and just like… shit just works. few
//! permissions. worst cases something happens but you just recover and learn"):
//!
//! - A cmux-created VM is one whose root-owned `/etc/cmux/vm-kind` reads
//!   `owner` and that has no team files root `/srv/team`, the rule the Cloud
//!   peer bridge uses (`cmux-tui` `remote_cli/acpmux_peer.rs` `vm_admits`).
//!   cmux's own creation paths write that file: the machine bind
//!   (`cmux-host` `cloud/client.rs` `record_owner_kind`) and the devbox
//!   image's `cmux-vm-kind-sync`. A team VM (shared by people) and every
//!   personal or SSH-added machine have no `owner` record.
//! - config.json's `vmHost` wins when present: `false` turns it off on a
//!   cmux-created VM, and `true` keeps it on wherever a fleet writes it (our
//!   own GCP lane VMs, leo-workspace `gcp-session-host vm-host`).
//! - `_acpmux/vm_host {on}` (`acpmux host vm-host [NAME] on|off`, the app's
//!   machine settings) is the per-machine toggle. Off writes `vmHost: false`;
//!   on removes the key, back to the default, and is refused on a machine
//!   cmux did not create. It applies at once, to the sessions started after
//!   it, with no restart: every use reads it live ([`Hub::vm_host`]).
//!
//! Who may toggle it: this machine's unix socket and app, and the owner's
//! peer daemon (`Control::Peer`), never a Web client. Turning it on needs no
//! person proof: on a cmux-created VM it is the default, and a process that
//! runs as this user can already write config.json and reload (the
//! same-uid residual in `person.rs`).

use super::*;

/// The marker files, under `/` outside tests (`Hub::set_vm_marker_root`).
const KIND_FILE: &str = "etc/cmux/vm-kind";
const TEAM_FILES_ROOT: &str = "srv/team";
/// `error.data.reason` when `on` is asked of a machine cmux did not create.
pub const NOT_CMUX_VM: &str = "vmHost.not_cmux_vm";
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

/// Whether `vmHost` is on: the config's own value, else whether cmux created
/// this VM.
pub(crate) fn effective(configured: Option<bool>, cmux_vm: bool) -> bool {
    configured.unwrap_or(cmux_vm)
}

impl Hub {
    /// Read the creation marker under `root` instead of `/` (tests).
    pub fn set_vm_marker_root(&self, root: PathBuf) {
        *self.vm_marker_root.lock().unwrap_or_else(|e| e.into_inner()) = root;
    }

    /// Whether cmux created this machine as one owner's VM (module docs).
    pub fn cmux_vm(&self) -> bool {
        let root = self.vm_marker_root.lock().unwrap_or_else(|e| e.into_inner()).clone();
        cmux_vm_at(&root)
    }

    /// Whether this machine is a dedicated agent VM now (module docs). Read
    /// at each use, so a toggle or a reload applies with no restart.
    pub async fn vm_host(&self) -> bool {
        let configured = self.config.read().await.vm_host;
        effective(configured, configured.is_none() && self.cmux_vm())
    }

    /// `_acpmux/vm_host`'s view of this machine: `vmHost` (on now), `cmuxVm`
    /// (created by cmux, so on by default) and `configured` (config.json's
    /// value, null when it follows the default).
    pub async fn vm_host_view(&self) -> Value {
        let configured = self.config.read().await.vm_host;
        let cmux_vm = self.cmux_vm();
        json!({
            "vmHost": effective(configured, cmux_vm),
            "cmuxVm": cmux_vm,
            "configured": configured,
        })
    }

    /// The per-machine toggle (module docs): off writes `vmHost: false`, on
    /// goes back to the default and is refused unless cmux created this VM.
    pub async fn set_vm_host(&self, on: bool) -> Result<Value, RpcError> {
        if on && !self.cmux_vm() {
            return Err(RpcError::new(
                -32000,
                "vmHost stays off here: it is only for a VM cmux created (an owner /etc/cmux/vm-kind), never a personal or SSH-added machine",
            )
            .with_data(json!({"reason": NOT_CMUX_VM})));
        }
        {
            let mut cfg = self.config.write().await;
            cfg.vm_host = if on { None } else { Some(false) };
            cfg.save().map_err(|e| RpcError::internal(format!("save vmHost: {e}")))?;
        }
        Ok(self.vm_host_view().await)
    }
}

#[cfg(test)]
mod tests {
    use super::{cmux_vm_at, effective};

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

    #[test]
    fn the_config_value_wins_over_the_marker() {
        assert!(effective(None, true), "on by default on a cmux VM");
        assert!(!effective(None, false), "off by default elsewhere");
        assert!(!effective(Some(false), true), "the toggle turned it off");
        assert!(effective(Some(true), false), "a fleet turned it on");
    }
}
