//! The machine kind `agent-session-start` needs (cx-d0tq, hq-84 rule): a
//! remote start is refused on a team VM, and on a Cloud VM whose kind the
//! daemon cannot tell. The kind comes from this machine's own identity,
//! read once at daemon start, never from a request:
//!
//! - team VM: the team binding `/var/lib/cmux/team-bound.json`, or the baked
//!   team files root `/srv/team` (a directory owned by root, group
//!   `cmux-ssh`). A marker counts only when root owns it and it is not a
//!   symlink, so a user cannot plant one; a marker the daemon cannot check
//!   (any error but "not found") makes the kind unknown.
//! - Cloud VM: the root-owned Cloud image stamp (the `fs-v1` check,
//!   link/cloud_fs.rs), the root-owned bake instance id, or `CMUX_VM_ID` in
//!   the environment.
//! - owner VM: a Cloud VM with no team marker and a root-owned bind record
//!   (`/var/lib/cmux/bound.json` or `/etc/cmux/daemon-instance-id`).
//!
//! Anything that is not a Cloud VM (a Mac, a plain SSH host) is allowed.
//!
//! `CMUX_AGENT_START_HOST` (`team-vm` or `unknown-cloud`) can only make the
//! kind stricter than the detected one; the socket tests use it. Any other
//! value is ignored.

use std::io::ErrorKind;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use cmux_tui_core::server::AgentStartHost;

const TEAM_BOUND_FILE: &str = "/var/lib/cmux/team-bound.json";
const TEAM_FILES_ROOT: &str = "/srv/team";
const TEAM_LOGIN_GROUP: &str = "cmux-ssh";
const OWNER_BOUND_FILES: [&str; 2] = ["/var/lib/cmux/bound.json", "/etc/cmux/daemon-instance-id"];
const BAKE_INSTANCE_FILE: &str = "/etc/cmux/bake-instance-id";
const VM_ID_VAR: &str = "CMUX_VM_ID";
pub(crate) const HOST_OVERRIDE_VAR: &str = "CMUX_AGENT_START_HOST";

/// A marker path: present (root-owned, no symlink), absent, or unknown.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Marker {
    Present,
    Absent,
    Unknown,
}

fn marker(path: &str, dir: bool, gid: Option<u32>) -> Marker {
    match std::fs::symlink_metadata(Path::new(path)) {
        Ok(meta) => {
            let kind_ok = if dir { meta.is_dir() } else { meta.file_type().is_file() };
            let group_ok = gid.is_none_or(|gid| meta.gid() == gid);
            if kind_ok && meta.uid() == 0 && group_ok { Marker::Present } else { Marker::Absent }
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Marker::Absent,
        Err(_) => Marker::Unknown,
    }
}

/// The gid of `name`, if the group exists.
fn group_id(name: &str) -> Option<u32> {
    let name = std::ffi::CString::new(name).ok()?;
    // SAFETY: getgrnam reads a NUL-terminated name; the returned record is
    // read at once, before any other getgr* call on this thread.
    let group = unsafe { libc::getgrnam(name.as_ptr()) };
    // SAFETY: a non-null result points to a valid group record.
    (!group.is_null()).then(|| unsafe { (*group).gr_gid })
}

/// This machine's kind for `agent-session-start`.
pub(crate) fn detect(env: impl Fn(&str) -> Option<String>) -> AgentStartHost {
    let team_files = match group_id(TEAM_LOGIN_GROUP) {
        Some(gid) => marker(TEAM_FILES_ROOT, true, Some(gid)),
        None => Marker::Absent,
    };
    let team_markers = [marker(TEAM_BOUND_FILE, false, None), team_files];
    let cloud = crate::link::cloud_fs::trusted_cloud_stamp()
        || marker(BAKE_INSTANCE_FILE, false, None) == Marker::Present
        || env(VM_ID_VAR).is_some_and(|value| !value.is_empty());
    let owner = OWNER_BOUND_FILES.iter().any(|file| marker(file, false, None) == Marker::Present);
    let detected = if team_markers.contains(&Marker::Present) {
        AgentStartHost::TeamVm
    } else if cloud && (team_markers.contains(&Marker::Unknown) || !owner) {
        AgentStartHost::UnknownCloud
    } else {
        AgentStartHost::Allowed
    };
    let requested = match env(HOST_OVERRIDE_VAR).as_deref() {
        Some("team-vm") => AgentStartHost::TeamVm,
        Some("unknown-cloud") => AgentStartHost::UnknownCloud,
        _ => AgentStartHost::Allowed,
    };
    detected.max(requested)
}
