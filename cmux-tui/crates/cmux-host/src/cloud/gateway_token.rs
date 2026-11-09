//! The bearer of this machine's inference gateway (`cmux inference gateway --token-file`), when the person made this
//! machine their team's gateway machine (cmux-platform `InferenceGateway.ts`: a machine holds the team's gateway socket
//! as its own VM install, and only when the team named it).
//!
//! Leo, 2026-11-07: "what we are willing to do for now is a tiny vm per subscription (user)/per team. that's it."
//!
//! Opt-in: only while the work user's `~/.config/cmux/inference-gateway/enabled` exists (`cmux inference setup`
//! makes it; checked for existence only, never followed or read). While it does, this thread keeps a fresh access
//! token of this machine's own install in [`TOKEN_FILE`], 0600 and owned by the work user, in a folder only root
//! writes, so no path the work user controls is ever written by root. Without the marker the file is removed. The
//! token is the one cmux-host itself uses; it acts only as this machine's install, and lives minutes. It is never
//! logged.

use std::fs;
use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use super::client::{CloudClient, Http};
use crate::daemon_spec::{WORK_HOME, WORK_USER};
use crate::linux::spawn::lookup_user;

/// Straight under root's `/run`, never under `/run/cmux` (the work user's): no path above the file is one the work
/// user can replace.
pub const TOKEN_DIR: &str = "/run/cmux-inference-gateway";
pub const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";
/// How often the thread looks at the marker and renews the token (the token cache renews a minute before expiry).
const EVERY: Duration = Duration::from_secs(60);

/// The newest thread's generation: a thread replaced on a rebind never removes the file its successor keeps.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// The marker the person's setup makes in the work user's home.
pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/inference-gateway/enabled")
}

/// Stops the thread when dropped (a rebind replaces it).
pub struct GatewayToken {
    stop: Arc<AtomicBool>,
}

impl Drop for GatewayToken {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl GatewayToken {
    pub fn spawn<H: Http + Send + 'static>(
        mut client: CloudClient<H>,
        now_wall_ms: fn() -> u64,
        log: fn(&str),
    ) -> std::io::Result<GatewayToken> {
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
        let newest = move || GENERATION.load(Ordering::SeqCst) == generation;
        std::thread::Builder::new().name("cmux-host-gateway-token".to_owned()).spawn(
            move || {
                let marker = marker(Path::new(WORK_HOME));
                let mut wrote = false;
                while !stopping.load(Ordering::SeqCst) && newest() {
                    // symlink_metadata: the marker is checked, never followed.
                    if fs::symlink_metadata(&marker).is_ok_and(|m| m.is_file()) {
                        match client
                            .token(now_wall_ms())
                            .and_then(|t| write_token(Path::new(TOKEN_DIR), &t))
                        {
                            Ok(()) => {
                                if !wrote {
                                    log("inference gateway: this machine's gateway token is kept");
                                }
                                wrote = true;
                            }
                            Err(e) => log(&format!("inference gateway token: {e}")),
                        }
                    } else if newest() && (wrote || Path::new(TOKEN_FILE).exists()) {
                        let _ = fs::remove_file(TOKEN_FILE);
                        wrote = false;
                    }
                    // Sleep in short steps so a stop is seen soon.
                    for _ in 0..EVERY.as_secs() {
                        if stopping.load(Ordering::SeqCst) {
                            break;
                        }
                        std::thread::sleep(Duration::from_secs(1));
                    }
                }
                if newest() {
                    let _ = fs::remove_file(TOKEN_FILE);
                }
            },
        )?;
        Ok(GatewayToken { stop })
    }
}

/// Writes `token` to `dir/token` through a fresh temporary and a rename: root's folder (0755), the file the work
/// user's (0600). Unchanged contents are not rewritten.
pub fn write_token(dir: &Path, token: &str) -> Result<(), String> {
    let user = lookup_user(WORK_USER).ok_or("no work user")?;
    use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _};
    // The parent must be root's and writable by no one else, so nothing can swap the folder after the checks below.
    let parent = dir.parent().ok_or("the token folder has no parent")?;
    let up = fs::symlink_metadata(parent).map_err(|e| e.to_string())?;
    if !up.is_dir() || up.uid() != 0 || up.mode() & 0o022 != 0 {
        return Err("the token folder's parent is not root's alone".into());
    }
    match fs::DirBuilder::new().mode(0o755).create(dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(format!("cannot make the token folder: {e}")),
    }
    let meta = fs::symlink_metadata(dir).map_err(|e| e.to_string())?;
    if !meta.is_dir() || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
        return Err("the token folder is not root's own folder".into());
    }
    let path = dir.join("token");
    if fs::read_to_string(&path).is_ok_and(|old| old == token) {
        return Ok(());
    }
    let tmp = dir.join(format!(".token.{}", std::process::id()));
    let _ = fs::remove_file(&tmp);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)
        .map_err(|e| format!("cannot write the token: {e}"))?;
    let written = file
        .write_all(token.as_bytes())
        .and_then(|()| file.sync_all())
        .and_then(|()| std::os::unix::fs::fchown(&file, Some(user.uid), Some(user.gid)));
    if let Err(e) = written.and_then(|()| fs::rename(&tmp, &path)) {
        let _ = fs::remove_file(&tmp);
        return Err(format!("cannot write the token: {e}"));
    }
    Ok(())
}
