//! `fs-v1` on cmux Cloud hosts only (decision D4, 2026-10-04): the daemon
//! of a Cloud VM serves file ops over the VM home, because the link token's
//! team policy already decided who reaches its `daemon` service. Every
//! other host (a Mac above all) installs no owner, does not advertise
//! `fs-v1`, and answers `fs.unavailable` to every fs op. File ops on a Mac
//! come later with an allow-list of user-chosen roots.
//!
//! A Cloud host is a Linux machine with BOTH:
//! - the image stamp `/etc/cmux/image-stamp` that every Cloud image bake
//!   writes as root (`cmux-devbox <epoch>` or `cmux-vm inputs=...`). It is
//!   trusted only when it and every folder above it are owned by root, are
//!   not writable by group or others, and are not symlinks, so a normal
//!   user cannot create or plant it;
//! - the Cloud model plane identity (`CMUX_CODEROUTER_URL` and
//!   `CMUX_VM_ID`, in the process environment or in
//!   `$HOME/.config/cmux/model-plane.env`; the source the machine spend
//!   readout uses).
//!
//! No argv flag is added, so an upgraded daemon starts with the guest's
//! existing command line.
//!
//! Test seam, debug builds only: `CMUX_TEST_CLOUD_ETC=<absolute dir>`
//! (`agent_start_host::cloud_etc`, read once at daemon start) stands in for
//! `/etc/cmux`, and the stamp there must be owned by the daemon's own uid,
//! with the walk stopping at that folder instead of `/`. Everything else
//! above (Linux, the stamp's prefix, no group/other write, no symlink, the
//! model plane identity) is checked as on a real Cloud host. Release builds
//! and a daemon without the variable read the root-owned `/etc/cmux` only.

use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use cmux_tui_core::fs_ops::{FsService, Roots};
use cmux_tui_core::server::agent_transfer::AgentTransferHost;

/// What a Cloud image stamp starts with (the devbox and cmux-vm bakes).
const STAMP_PREFIXES: [&str; 2] = ["cmux-devbox ", "cmux-vm "];
/// Longest stamp read.
const MAX_STAMP_BYTES: u64 = 4096;

/// True when this daemon serves `fs-v1`.
pub(super) fn is_cloud_host(linux: bool, trusted_stamp: bool, model_plane_identity: bool) -> bool {
    linux && trusted_stamp && model_plane_identity
}

/// True when `stamp` is a regular file whose text starts like a Cloud
/// image stamp, and it and each folder from its parent up to `top` are
/// owned by `owner_uid`, not writable by group or others, and not symlinks.
pub(super) fn trusted_stamp(stamp: &Path, top: &Path, owner_uid: u32) -> bool {
    if !stamp.starts_with(top) {
        return false;
    }
    let mut current = Some(stamp);
    while let Some(path) = current {
        let Ok(meta) = cmux_blocking::fs::symlink_metadata(path) else { return false };
        let kind_ok = if path == stamp { meta.file_type().is_file() } else { meta.is_dir() };
        if !kind_ok || meta.uid() != owner_uid || meta.mode() & 0o022 != 0 {
            return false;
        }
        if path == top {
            break;
        }
        current = path.parent();
    }
    let Ok(file) = cmux_blocking::fs::open(stamp) else { return false };
    let mut text = String::new();
    if std::io::Read::read_to_string(&mut std::io::Read::take(file, MAX_STAMP_BYTES), &mut text)
        .is_err()
    {
        return false;
    }
    STAMP_PREFIXES.iter().any(|prefix| text.starts_with(prefix))
}

/// True when this machine is a cmux Cloud host (the module's test).
fn this_is_a_cloud_host() -> bool {
    let env_file = crate::coderouter_usage::default_env_file_path()
        .and_then(|path| cmux_blocking::fs::read_to_string(path).ok());
    let identity =
        crate::coderouter_usage::resolve_source(|key| std::env::var(key).ok(), env_file.as_deref())
            .is_some();
    let linux = cfg!(target_os = "linux");
    // The root-owned stamp of a Cloud image (`/etc/cmux/image-stamp`).
    let etc = crate::agent_start_host::cloud_etc();
    let stamp = etc.file(crate::agent_start_host::IMAGE_STAMP_FILE);
    is_cloud_host(linux, linux && trusted_stamp(&stamp, &etc.top, etc.owner), identity)
}

/// What `agent-transfer-v1` guards moved chats with: on a Cloud host they
/// arrive under `$HOME/work` under peer control, elsewhere only in the folder
/// the app names, under web control. `None` without a `HOME`.
pub(super) fn agent_transfer_host() -> Option<AgentTransferHost> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    Some(AgentTransferHost { cloud: this_is_a_cloud_host(), home })
}

/// Installs the file owner over `HOME` when this is a Cloud host. Returns
/// whether `fs-v1` is now served.
pub(super) fn install_if_cloud_host() -> bool {
    if !this_is_a_cloud_host() {
        return false;
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return false };
    let roots = Roots::new([home]);
    if roots.is_empty() {
        return false;
    }
    if !cmux_tui_core::fs_ops::install(FsService::new(roots)) {
        return false;
    }
    // Leftover temporaries of writes a previous daemon did not finish; off
    // the startup path.
    let _ = std::thread::Builder::new().name("cmux-fs-sweep".into()).spawn(|| {
        if let Some(service) = cmux_tui_core::fs_ops::installed() {
            service.sweep_stale_temporaries();
        }
    });
    true
}

#[cfg(test)]
#[path = "cloud_fs_tests.rs"]
mod tests;
