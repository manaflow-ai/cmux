//! The machine kind `agent-session-start` needs (cx-d0tq, hq-84 rule): a
//! remote start is refused on a team VM, and on a Cloud VM whose kind the
//! daemon cannot tell. The kind comes from this machine's own identity,
//! read again at every start (a few file checks), never from a request.
//!
//! The daemon runs as the work user and cannot read cmux-host's state
//! (/var/lib/cmux is 0700 root), so cmux-host records the kind where any
//! user can read it: `/etc/cmux/vm-kind` (cmux-host cloud/wire.rs
//! `VM_KIND_FILE`), `owner` from a machine bind, `team` from a team enroll,
//! root-owned. A record counts only when it and every folder above it are
//! owned by root, not writable by group or others, and not symlinks, and the
//! open file (O_NOFOLLOW) passes the same check, so a user cannot plant or
//! swap one.
//!
//! - team VM (checked first, on any machine): kind `team`, or the baked team
//!   files root `/srv/team` (a directory owned by root, group `cmux-ssh`).
//! - Cloud VM: the Cloud image stamp `/etc/cmux/image-stamp` or the bake
//!   instance id `/etc/cmux/bake-instance-id` exists (trusted or not: a
//!   tampered one can only make the kind stricter), or `CMUX_VM_ID` is set.
//! - owner VM: a Cloud VM with kind `owner` and no team marker.
//! - Any other Cloud VM (no record, an unreadable one, another value) is of
//!   unknown kind and refused (fail closed). Anything that is not a Cloud VM
//!   (a Mac, a plain SSH host) is allowed.
//!
//! Not containment: a team member already has a shell on the VM and can run
//! an agent there directly. The gate keeps the app from starting
//! local-control chats on team VMs; it does not hold back a member.
//!
//! `CMUX_AGENT_START_HOST` (`team-vm` or `unknown-cloud`), read once at
//! daemon start, can only make the kind stricter; the socket tests use it.
//! Any other value is ignored.
//!
//! Test seam, debug builds only (`#[cfg(debug_assertions)]`; a release binary
//! has no trace of it): `CMUX_TEST_CLOUD_ETC=<absolute dir>`, read once at
//! daemon start ([`cloud_etc`]), stands in for `/etc/cmux` for the image
//! stamp, `vm-kind` and `bake-instance-id`, here and in `link/cloud_fs.rs`.
//! Under it a record must be owned by the daemon's own uid instead of root,
//! and the ownership walk stops at that folder instead of `/`; the
//! group/other-write and no-symlink rules, the stamp prefix, the model plane
//! identity and the `owner`/`team` reading stay as they are. The team files
//! root `/srv/team` is not moved. The Linux journey
//! (`tests/cloud_move_journey.rs`) makes a daemon a personal Cloud VM this way.

use std::io::Read as _;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use cmux_tui_core::server::{AgentStartHost, AgentStartHostSource};

/// The machine's Cloud records, in [`CloudEtc::dir`] (`/etc/cmux`).
const VM_KIND_FILE: &str = "vm-kind";
const BAKE_INSTANCE_FILE: &str = "bake-instance-id";
/// The Cloud image stamp (link/cloud_fs.rs reads it too).
pub(crate) const IMAGE_STAMP_FILE: &str = "image-stamp";
const TEAM_FILES_ROOT: &str = "/srv/team";
const TEAM_LOGIN_GROUP: &str = "cmux-ssh";
const VM_ID_VAR: &str = "CMUX_VM_ID";
const HOST_OVERRIDE_VAR: &str = "CMUX_AGENT_START_HOST";
/// The debug-only seam (module docs).
#[cfg(debug_assertions)]
const TEST_CLOUD_ETC_VAR: &str = "CMUX_TEST_CLOUD_ETC";

/// Where this machine's Cloud records live and who must own them.
pub(crate) struct CloudEtc {
    /// `/etc/cmux`: the image stamp, `vm-kind` and `bake-instance-id`.
    pub(crate) dir: PathBuf,
    /// The uid a record and every folder above it must belong to (root).
    pub(crate) owner: u32,
    /// Where the ownership walk stops (`/`).
    pub(crate) top: PathBuf,
}

impl CloudEtc {
    pub(crate) fn file(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }
}

/// The Cloud records' place, settled once (at daemon start: the first call
/// is the daemon's host gate and link entry setup).
pub(crate) fn cloud_etc() -> &'static CloudEtc {
    static ETC: OnceLock<CloudEtc> = OnceLock::new();
    ETC.get_or_init(|| {
        #[cfg(debug_assertions)]
        if let Some(etc) = test_cloud_etc() {
            return etc;
        }
        CloudEtc { dir: PathBuf::from("/etc/cmux"), owner: 0, top: PathBuf::from("/") }
    })
}

/// Debug builds only: `CMUX_TEST_CLOUD_ETC`, an absolute folder owned by
/// this user, stands in for `/etc/cmux` (module docs).
#[cfg(debug_assertions)]
fn test_cloud_etc() -> Option<CloudEtc> {
    let dir = PathBuf::from(std::env::var_os(TEST_CLOUD_ETC_VAR)?);
    if !dir.is_absolute() {
        return None;
    }
    // SAFETY: getuid has no preconditions and cannot fail.
    let owner = unsafe { libc::getuid() };
    Some(CloudEtc { top: dir.clone(), dir, owner })
}

/// The daemon's source: the environment is read once here, the files at
/// every call.
pub(crate) fn source() -> AgentStartHostSource {
    let env = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
    let vm_id = env(VM_ID_VAR).is_some();
    let requested = match env(HOST_OVERRIDE_VAR).as_deref() {
        Some("team-vm") => AgentStartHost::TeamVm,
        Some("unknown-cloud") => AgentStartHost::UnknownCloud,
        _ => AgentStartHost::Allowed,
    };
    let team_gid = group_id(TEAM_LOGIN_GROUP);
    let etc = cloud_etc();
    Arc::new(move || detect(etc, vm_id, team_gid).max(requested))
}

fn detect(etc: &CloudEtc, vm_id: bool, team_gid: Option<u32>) -> AgentStartHost {
    // Team markers first: a team VM is refused whatever else this machine
    // shows (also with no Cloud marker at all).
    let root = Path::new("/");
    let team_files = team_gid.is_some_and(|gid| {
        trusted(Path::new(TEAM_FILES_ROOT), true, 0, root).is_some_and(|meta| meta.gid() == gid)
    });
    let kind = read_kind(etc);
    if team_files || kind.as_deref() == Some("team") {
        return AgentStartHost::TeamVm;
    }
    // Any stamp or bake id counts as Cloud evidence here, trusted or not: a
    // tampered one makes the kind stricter (unknown), never looser.
    // An error other than "not found" (a folder the daemon cannot search)
    // counts as present too.
    let present = |name: &str| {
        cmux_blocking::fs::symlink_metadata(etc.file(name))
            .map_or_else(|error| error.kind() != std::io::ErrorKind::NotFound, |_| true)
    };
    let cloud = present(IMAGE_STAMP_FILE) || present(BAKE_INSTANCE_FILE) || vm_id;
    match (cloud, kind.as_deref()) {
        (false, _) => AgentStartHost::Allowed,
        (true, Some("owner")) => AgentStartHost::Allowed,
        (true, _) => AgentStartHost::UnknownCloud,
    }
}

/// The metadata of `path` when it and every folder above it up to `top`
/// are owned by `owner` (root), not writable by group or others, and not
/// symlinks (a user cannot plant or swap it); `dir` says which kind `path`
/// must be.
fn trusted(path: &Path, dir: bool, owner: u32, top: &Path) -> Option<std::fs::Metadata> {
    if !path.starts_with(top) {
        return None;
    }
    let mut current = Some(path);
    let mut leaf = None;
    while let Some(at) = current {
        let meta = cmux_blocking::fs::symlink_metadata(at).ok()?;
        let kind_ok = if at == path && !dir { meta.file_type().is_file() } else { meta.is_dir() };
        if !kind_ok || meta.uid() != owner || meta.mode() & 0o022 != 0 {
            return None;
        }
        if leaf.is_none() {
            leaf = Some(meta);
        }
        if at == top {
            break;
        }
        current = at.parent();
    }
    leaf
}

/// The recorded kind, trimmed (at most 64 bytes), when the record is
/// trusted. Opened without following a symlink and checked again on the
/// open file, so a swap between the checks is refused.
fn read_kind(etc: &CloudEtc) -> Option<String> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let path = etc.file(VM_KIND_FILE);
    trusted(&path, false, etc.owner, &etc.top)?;
    let file = crate::blocking::fs::open_with(
        std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW),
        &path,
    )
    .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.file_type().is_file() || meta.uid() != etc.owner || meta.mode() & 0o022 != 0 {
        return None;
    }
    let mut text = String::new();
    file.take(64).read_to_string(&mut text).ok()?;
    Some(text.trim().to_owned())
}

/// The gid of group `name`, if it exists (getgrnam_r: the daemon has other
/// threads by now).
fn group_id(name: &str) -> Option<u32> {
    let name = std::ffi::CString::new(name).ok()?;
    let mut buffer = vec![0_u8; 4096];
    loop {
        // SAFETY: an all-zero `group` is a valid out value for getgrnam_r.
        let mut group: libc::group = unsafe { std::mem::zeroed() };
        let mut found: *mut libc::group = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call; the buffer outlives it.
        let status = unsafe {
            libc::getgrnam_r(
                name.as_ptr(),
                &mut group,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut found,
            )
        };
        if status == libc::ERANGE && buffer.len() < 1 << 20 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        return (status == 0 && !found.is_null()).then_some(group.gr_gid);
    }
}
