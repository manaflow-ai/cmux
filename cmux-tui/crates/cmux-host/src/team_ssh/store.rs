//! The trust files: atomic writes in the order sshd needs, and the reads
//! behind `principals`.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use super::trust::{self, Snapshot, TrustState, Verified};
use super::{APPLY_LOCK_FILE, CA_FILE, KRL_FILE, PRINCIPALS_DIR, TRUST_FILE};
use crate::config::Paths;

/// Checks a written temp KRL before it replaces the live one (production:
/// `ssh-keygen -Q -l -f <tmp>`, so sshd never gets a KRL it cannot parse).
pub type KrlCheck<'a> = &'a dyn Fn(&Path) -> Result<(), String>;

/// Writes `bytes` to `path` through a temp file in the same directory,
/// fsync and rename, so sshd sees the old or the new file, never a part.
pub fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    write_atomic_checked(path, bytes, mode, &|_| Ok(()))
}

fn write_atomic_checked(
    path: &Path,
    bytes: &[u8],
    mode: u32,
    check: KrlCheck<'_>,
) -> io::Result<()> {
    let dir = path.parent().ok_or_else(|| io::Error::other("path has no parent"))?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = dir.join(format!(".{name}.tmp-{}", std::process::id()));
    let result = (|| {
        let mut file = fs::File::create(&tmp)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        check(&tmp).map_err(io::Error::other)?;
        fs::rename(&tmp, path)?;
        fs::File::open(dir)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// The production [`KrlCheck`]: `/usr/bin/ssh-keygen -Q -l -f <krl>` must
/// parse the KRL, as sshd will.
pub fn ssh_keygen_check(path: &Path) -> Result<(), String> {
    let out = std::process::Command::new("/usr/bin/ssh-keygen")
        .args(["-Q", "-l", "-f"])
        .arg(path)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("ssh-keygen: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        Err(format!("ssh-keygen cannot read the KRL: {}", err.trim()))
    }
}

/// The applied state, `None` when absent or unreadable (fail closed).
pub fn load_state(paths: &Paths) -> Option<TrustState> {
    let text = fs::read_to_string(paths.at(TRUST_FILE)).ok()?;
    serde_json::from_str(&text).ok()
}

/// What an accepted apply changed.
#[derive(Debug, PartialEq, Eq)]
pub struct Applied {
    pub previous: Option<TrustState>,
    pub state: TrustState,
    /// The KRL version moved (the reaper must run).
    pub krl_changed: bool,
}

/// An exclusive `flock` on the apply lock file, released on drop, so two
/// applies never interleave their check and writes.
struct ApplyLock(#[allow(dead_code)] fs::File);

fn lock(paths: &Paths) -> io::Result<ApplyLock> {
    let path = paths.at(APPLY_LOCK_FILE);
    let dir = path.parent().ok_or_else(|| io::Error::other("lock path has no parent"))?;
    fs::create_dir_all(dir)?;
    let mut options = fs::OpenOptions::new();
    options.create(true).truncate(false).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        options.mode(0o600);
    }
    let file = options.open(&path)?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(ApplyLock(file))
}

/// The applied state, with the KRL version raised to the header version of
/// the KRL on disk: after a crash between the KRL and the state write, an
/// older snapshot is still refused.
fn current(paths: &Paths) -> Option<TrustState> {
    let state = load_state(paths);
    let disk = fs::read(paths.at(KRL_FILE)).ok().and_then(|k| trust::krl_header_version(&k));
    match (state, disk) {
        (Some(s), Some(v)) => Some(TrustState { krl_version: s.krl_version.max(v), ..s }),
        (Some(s), None) => Some(s),
        (None, Some(v)) if v > 0 => {
            Some(TrustState { krl_version: v, generation: 0, synced_at: 0 })
        }
        (None, _) => None,
    }
}

/// Validates `snapshot`, refuses a regression, then writes the KRL (after
/// `check_krl` accepts the temp file), the CA keys and the state, in that
/// order, under the apply lock. A refusal changes no file, so the last sync
/// time keeps ageing toward the fail-closed bound.
pub fn apply(
    paths: &Paths,
    snapshot: &Snapshot,
    now: u64,
    check_krl: KrlCheck<'_>,
) -> Result<Applied, String> {
    let next: Verified = trust::verify(snapshot)?;
    let io = |what: &str, e: io::Error| format!("{what}: {e}");
    let dir = paths.at(PRINCIPALS_DIR);
    fs::create_dir_all(&dir).map_err(|e| io("ssh dir", e))?;
    let _lock = lock(paths).map_err(|e| io("apply lock", e))?;
    let previous = current(paths);
    trust::decide(previous.as_ref(), &next)?;
    write_atomic_checked(&paths.at(KRL_FILE), &next.krl, 0o644, check_krl)
        .map_err(|e| io("krl", e))?;
    let mut ca = next.ca_keys.join("\n");
    if !ca.is_empty() {
        ca.push('\n');
    }
    write_atomic(&paths.at(CA_FILE), ca.as_bytes(), 0o644).map_err(|e| io("ca keys", e))?;
    let state =
        TrustState { krl_version: next.krl_version, generation: next.generation, synced_at: now };
    let json = serde_json::to_vec(&state).map_err(|e| e.to_string())?;
    write_atomic(&paths.at(TRUST_FILE), &json, 0o644).map_err(|e| io("trust state", e))?;
    let krl_changed = previous.is_none_or(|p| p.krl_version != state.krl_version);
    Ok(Applied { previous, state, krl_changed })
}

/// `principals <user>`: the user's principals while trust is fresh.
pub fn principals(paths: &Paths, user: &str, now: u64) -> String {
    if !trust::valid_user(user) {
        return String::new();
    }
    let file = fs::read_to_string(paths.at(PRINCIPALS_DIR).join(user)).unwrap_or_default();
    trust::principals_output(load_state(paths).as_ref(), now, &file)
}
