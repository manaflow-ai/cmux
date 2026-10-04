//! `fs-v1` on cmux Cloud hosts only (decision D4, 2026-10-04): the daemon
//! of a Cloud VM serves file ops over the VM home, because the link token's
//! team policy already decided who reaches its `daemon` service. Every
//! other host (a Mac above all) installs no owner, does not advertise
//! `fs-v1`, and answers `fs.unavailable` to every fs op. File ops on a Mac
//! come later with an allow-list of user-chosen roots.
//!
//! A Cloud host is a Linux machine whose daemon carries the Cloud model
//! plane identity (`CMUX_CODEROUTER_URL` and `CMUX_VM_ID`, in the process
//! environment or in `$HOME/.config/cmux/model-plane.env`; the same source
//! the machine spend readout uses). No argv flag is added, so an upgraded
//! daemon starts with the guest's existing command line.

use std::path::PathBuf;

use cmux_tui_core::fs_ops::{FsService, Roots};

/// True when this daemon serves `fs-v1`.
pub(super) fn is_cloud_host(linux: bool, model_plane_identity: bool) -> bool {
    linux && model_plane_identity
}

/// Installs the file owner over `home` when this is a Cloud host. Returns
/// whether `fs-v1` is now served.
pub(super) fn install_if_cloud_host() -> bool {
    let env_file = crate::coderouter_usage::default_env_file_path()
        .and_then(|path| std::fs::read_to_string(path).ok());
    let identity =
        crate::coderouter_usage::resolve_source(|key| std::env::var(key).ok(), env_file.as_deref())
            .is_some();
    if !is_cloud_host(cfg!(target_os = "linux"), identity) {
        return false;
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return false };
    let roots = Roots::new([home]);
    if roots.is_empty() {
        return false;
    }
    cmux_tui_core::fs_ops::install(FsService::new(roots))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RED (decision D4): only a Linux host with the Cloud identity serves
    /// file ops; a Mac never does, whatever its environment says.
    #[test]
    fn only_a_linux_host_with_the_cloud_identity_serves_fs() {
        assert!(is_cloud_host(true, true));
        assert!(!is_cloud_host(false, true), "a Mac with a model-plane env is not a Cloud host");
        assert!(!is_cloud_host(true, false));
        assert!(!is_cloud_host(false, false));
    }
}
