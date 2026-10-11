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
//! - Cloud VM: the root-owned Cloud image stamp (the `fs-v1` check,
//!   link/cloud_fs.rs), the root-owned bake instance id, or `CMUX_VM_ID` in
//!   the environment.
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

use std::io::Read as _;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;
use std::sync::Arc;

use cmux_tui_core::server::{AgentStartHost, AgentStartHostSource};

const VM_KIND_FILE: &str = "/etc/cmux/vm-kind";
const TEAM_FILES_ROOT: &str = "/srv/team";
const TEAM_LOGIN_GROUP: &str = "cmux-ssh";
const BAKE_INSTANCE_FILE: &str = "/etc/cmux/bake-instance-id";
const VM_ID_VAR: &str = "CMUX_VM_ID";
const HOST_OVERRIDE_VAR: &str = "CMUX_AGENT_START_HOST";

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
    Arc::new(move || detect(vm_id, team_gid).max(requested))
}

fn detect(vm_id: bool, team_gid: Option<u32>) -> AgentStartHost {
    // Team markers first: a team VM is refused whatever else this machine
    // shows (also with no Cloud marker at all).
    let team_files = team_gid.is_some_and(|gid| {
        trusted(TEAM_FILES_ROOT, true).is_some_and(|meta| meta.gid() == gid)
    });
    let kind = read_kind();
    if team_files || kind.as_deref() == Some("team") {
        return AgentStartHost::TeamVm;
    }
    let cloud = crate::link::cloud_fs::trusted_cloud_stamp()
        || trusted(BAKE_INSTANCE_FILE, false).is_some()
        || vm_id;
    match (cloud, kind.as_deref()) {
        (false, _) => AgentStartHost::Allowed,
        (true, Some("owner")) => AgentStartHost::Allowed,
        (true, _) => AgentStartHost::UnknownCloud,
    }
}

/// The metadata of `path` when it and every folder above it are owned by
/// root, not writable by group or others, and not symlinks (a user cannot
/// plant or swap it); `dir` says which kind `path` must be.
fn trusted(path: &str, dir: bool) -> Option<std::fs::Metadata> {
    let path = Path::new(path);
    let mut current = Some(path);
    let mut leaf = None;
    while let Some(at) = current {
        let meta = std::fs::symlink_metadata(at).ok()?;
        let kind_ok = if at == path && !dir { meta.file_type().is_file() } else { meta.is_dir() };
        if !kind_ok || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
            return None;
        }
        if leaf.is_none() {
            leaf = Some(meta);
        }
        current = at.parent();
    }
    leaf
}

/// The recorded kind, trimmed (at most 64 bytes), when the record is
/// trusted. Opened without following a symlink and checked again on the
/// open file, so a swap between the checks is refused.
fn read_kind() -> Option<String> {
    use std::os::unix::fs::OpenOptionsExt as _;
    trusted(VM_KIND_FILE, false)?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(VM_KIND_FILE)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.file_type().is_file() || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
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
