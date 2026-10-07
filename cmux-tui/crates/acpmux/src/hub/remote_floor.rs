//! Part of `Hub`; see `hub/mod.rs`. The remote approval floor
//! (decisions.md REMOTE-CHIEF, REMOTE-FLOOR-ENFORCEMENT): a turn a remote
//! device started (`Control::Web`) never runs below it, whatever changed
//! after the remote guard and the dispatch check let it start. The
//! permission step (`handle_permission_for`) is the fail-closed base:
//!
//! - In a Web turn nothing approves itself. A policy or a rule that would
//!   approve (set during the turn, by any client) makes the request ask; a
//!   deny still denies. The chat allowance never applies (`permissions.rs`).
//! - When the session's mode stops asking during a Web turn (the harness
//!   moved itself, also from no declared mode, or any client set it), the
//!   turn is cancelled and every later permission request in it is
//!   cancelled, never shown: a harness in a mode that does not ask runs
//!   tools without a request. A prompt not yet sent is not sent.
//! - An ACP file read (`fs/read_text_file`) outside the session's folder
//!   asks, naming the resolved path; the read then opens that very file
//!   (checked on the open descriptor). A file that is not a regular file or
//!   has other hard links, and a folder that is the home directory or above
//!   it, count as outside. An ACP write never goes through a symlink, its
//!   question names the resolved path, and it writes only that file.
//! - Between turns, a session whose last turn was a Web turn is held to the
//!   floor too (an agent's background request), until a local turn starts.
//!   Both marks are read back when a host is adopted (`hosts.rs`).
//!
//! Not covered here: approvals a harness keeps inside its own process
//! (its settings' allow rules). A grant a client gave this process ("allow
//! always") ends Web control (`web_control.rs`).

use super::*;

/// The remote floor's marks on a session.
#[derive(Default)]
pub(crate) struct FloorState {
    /// The last turn was a Web turn: an agent request between turns is
    /// held to the floor.
    pub(super) last_turn_web: AtomicBool,
    /// The Web turn the floor cancelled: every later request in it is
    /// cancelled, also after a local restore of an asking mode.
    pub(super) floor_cancelled_turn: StdMutex<Option<String>>,
    /// A mode the harness reported while it declared no modes; the asking
    /// check reads it. Cleared when the agent exits.
    pub(super) undeclared_mode: StdMutex<Option<String>>,
    /// The agent process holds a lasting grant a client gave it ("allow
    /// always"): Web control ends until the agent exits (`web_control.rs`).
    pub(super) harness_grant: AtomicBool,
    /// A remote chain's agent host was adopted with no record that it runs
    /// in the sandbox (it started before the sandbox existed): Web control
    /// ends until the agent exits (`remote_sandbox.rs`).
    pub(super) unsandboxed: AtomicBool,
}

impl Hub {
    /// Whether `session`'s current turn was started or steered by a remote
    /// device. A turn adopted after a restart keeps its recorded control.
    pub(super) fn web_turn(session: &Session) -> bool {
        match session.turn() {
            Some(t) => t.control == Control::Web,
            None => session.floor.last_turn_web.load(Ordering::SeqCst),
        }
    }

    /// Why a Web turn of `session` may not go on, or None: the floor
    /// cancelled this turn, its Web control ended (the sticky flag), or its
    /// current mode does not ask.
    pub(super) fn remote_floor_breach(&self, session: &Session) -> Option<&'static str> {
        let turn = session.turn().map(|t| t.turn_id);
        if turn.is_some()
            && *session.floor.floor_cancelled_turn.lock().unwrap_or_else(|e| e.into_inner()) == turn
        {
            return Some("remote.turn_cancelled");
        }
        if session.floor.unsandboxed.load(Ordering::SeqCst) {
            return Some("remote.unsandboxed_agent");
        }
        if session.web_control_ended.load(Ordering::SeqCst) {
            return Some("remote.mode_left_asking_table");
        }
        let meta = session.meta();
        (!self.session_asks_now(session, &meta)).then_some("remote.mode_not_asking")
    }

    /// Whether the session's mode asks: the declared one (`web_modes.rs`),
    /// and a mode the harness reported without declaring any.
    pub(super) fn session_asks_now(&self, session: &Session, meta: &SessionMeta) -> bool {
        let table = self.web_modes();
        if !table.session_asks(meta) {
            return false;
        }
        if crate::web_modes::mode_of(meta).is_some() {
            return true;
        }
        match session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()).as_deref() {
            Some(mode) => table.modes(&crate::web_modes::family_of(meta)).iter().any(|m| m == mode),
            None => true,
        }
    }

    /// End the running Web turn of `session`: log why, cancel its pending
    /// permissions (which bumps the epoch, so a request already on its way
    /// is cancelled too) and send the harness `session/cancel` when its
    /// prompt went out (`turnSeq` set; a prompt not yet sent is not sent).
    pub(super) fn remote_floor_cancel(&self, session: &Session, reason: &str) {
        let Some(turn) = session.turn() else { return };
        {
            let mut cancelled =
                session.floor.floor_cancelled_turn.lock().unwrap_or_else(|e| e.into_inner());
            if cancelled.as_deref() == Some(turn.turn_id.as_str()) {
                return;
            }
            *cancelled = Some(turn.turn_id.clone());
        }
        tracing::warn!(session = %session.id, reason, "remote floor: the Web turn is cancelled");
        self.append(
            session,
            "mux",
            "remote_floor_cancel",
            json!({"reason": reason, "turnId": turn.turn_id}),
        );
        self.cancel_pending_permissions(session);
        if turn.turn_seq == 0 {
            return;
        }
        let Some(s) =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&session.id).cloned()
        else {
            return;
        };
        let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
        rt.spawn(async move {
            let child = s.child.lock().await.clone();
            // Only the turn the floor cancelled, never a newer one.
            if s.turn().map(|t| t.turn_id) != Some(turn.turn_id) {
                return;
            }
            if let (Some(c), Some(sid)) = (child, s.meta().agent_session_id) {
                let _ = c.notify(method::SESSION_CANCEL, json!({"sessionId": sid})).await;
            }
        });
    }
}

/// Where an ACP read in a Web turn lands, found without opening it.
pub(super) struct ReadTarget {
    /// The resolved path (symlinks and `..` resolved).
    pub(super) real: PathBuf,
    /// Its device and inode, checked again on the opened descriptor.
    id: (u64, u64),
    /// Inside the folder: a regular file with one link, in a folder below
    /// the home directory.
    pub(super) inside: bool,
}

/// The read target of `path` for `folder`; None when it cannot be resolved
/// (outside).
pub(super) fn read_target(path: &Path, folder: &Path) -> Option<ReadTarget> {
    use std::os::unix::fs::MetadataExt;
    let real = std::fs::canonicalize(path).ok()?;
    let m = std::fs::metadata(&real).ok()?;
    let root = std::fs::canonicalize(folder).ok();
    let home = dirs::home_dir().and_then(|h| std::fs::canonicalize(h).ok());
    let inside = m.is_file()
        && m.nlink() == 1
        && root.as_ref().is_some_and(|r| {
            real.starts_with(r) && !home.as_ref().is_some_and(|h| h.starts_with(r))
        });
    Some(ReadTarget { real, id: (m.dev(), m.ino()), inside })
}

/// Open the checked read target: never blocks (a FIFO), only a regular
/// file, only the very file that was checked (same device and inode), and
/// one that was inside still has one link.
pub(super) fn open_read_target(t: &ReadTarget) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let file =
        std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(&t.real)?;
    let m = file.metadata()?;
    if !m.is_file() {
        return Err(std::io::Error::other("not a regular file"));
    }
    if (m.dev(), m.ino()) != t.id || (t.inside && m.nlink() != 1) {
        return Err(std::io::Error::other("the file changed since it was checked"));
    }
    Ok(file)
}

/// Write `content` to the path `write_target` resolved, after approval:
/// never through a symlink (`O_NOFOLLOW`, and the path still resolves to
/// itself), only to a regular file with one link, and only to the file the
/// path names now.
pub(super) fn write_approved(target: &Path, content: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(target)?;
    let m = file.metadata()?;
    if !m.is_file() || m.nlink() != 1 {
        return Err(std::io::Error::other("not a regular file with one link"));
    }
    let named = std::fs::symlink_metadata(target)?;
    if std::fs::canonicalize(target)? != target || (named.dev(), named.ino()) != (m.dev(), m.ino())
    {
        return Err(std::io::Error::other("the file changed since it was approved"));
    }
    file.set_len(0)?;
    file.write_all(content)
}

/// Where an ACP write in a Web turn lands: never through a symlink (an
/// existing link is refused), and with the parent folder resolved, so the
/// question names the real path.
pub(super) fn write_target(path: &Path) -> Result<PathBuf, String> {
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(format!(
            "{} is a symlink; a remote turn never writes through one",
            path.display()
        ));
    }
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(format!("{} has no parent folder", path.display()));
    };
    // A parent that does not exist yet is created by the write; its nearest
    // existing ancestor is resolved.
    let mut existing = parent.to_path_buf();
    let mut rest = Vec::new();
    // A dangling link counts as existing: resolving it then fails.
    while std::fs::symlink_metadata(&existing).is_err() {
        let Some(last) = existing.file_name().map(|n| n.to_owned()) else { break };
        rest.push(last);
        if !existing.pop() {
            break;
        }
    }
    let mut out =
        std::fs::canonicalize(&existing).map_err(|e| format!("{}: {e}", existing.display()))?;
    out.extend(rest.into_iter().rev());
    out.push(name);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::{open_read_target, read_target, write_approved, write_target};

    #[test]
    fn reads_resolve_links_and_count_odd_files_as_outside() {
        let d = std::env::temp_dir().join(format!("arf-unit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("work/sub")).unwrap();
        std::fs::create_dir_all(d.join("work2")).unwrap();
        let d = std::fs::canonicalize(&d).unwrap();
        std::fs::write(d.join("secret"), "s").unwrap();
        std::fs::write(d.join("work/sub/a"), "a").unwrap();
        std::fs::write(d.join("work2/b"), "b").unwrap();
        std::os::unix::fs::symlink(d.join("secret"), d.join("work/link")).unwrap();
        std::fs::hard_link(d.join("secret"), d.join("work/hard")).unwrap();
        let fifo = std::ffi::CString::new(d.join("work/fifo").to_str().unwrap()).unwrap();
        // SAFETY: a valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let work = d.join("work");
        let t = |p: &str| read_target(&d.join(p), &work).unwrap();
        assert!(t("work/sub/a").inside);
        assert_eq!(t("work/sub/a").real, d.join("work/sub/a"));
        // A link out of the folder resolves to its target, outside.
        assert_eq!(t("work/link").real, d.join("secret"));
        assert!(!t("work/link").inside);
        assert!(!t("secret").inside);
        assert!(!t("work/hard").inside);
        assert!(!t("work/fifo").inside);
        assert!(read_target(&d.join("work/missing"), &work).is_none());
        // A sibling whose name starts with the folder's is outside.
        assert!(!t("work2/b").inside);
        // The open is of the checked file only; a FIFO neither blocks nor opens.
        assert!(open_read_target(&t("work/sub/a")).is_ok());
        assert!(open_read_target(&t("work/fifo")).is_err());
        let checked = t("work/sub/a");
        // A new file renamed over it (both exist at once: a new inode).
        std::fs::write(d.join("work/sub/new"), "swapped").unwrap();
        std::fs::rename(d.join("work/sub/new"), d.join("work/sub/a")).unwrap();
        assert!(open_read_target(&checked).is_err(), "a swapped file");
        // Writes: a link is refused, a dangling parent link too, and the
        // parent resolves.
        assert!(write_target(&d.join("work/link")).is_err());
        std::os::unix::fs::symlink(d.join("work3"), d.join("work/dir")).unwrap();
        assert!(write_target(&d.join("work/dir/new/x")).is_err(), "a dangling link");
        std::fs::create_dir_all(d.join("work3")).unwrap();
        let t = write_target(&d.join("work/dir/new/x")).unwrap();
        assert_eq!(t, d.join("work3/new/x"));
        // The approved write lands only in a plain file at that path.
        let target = d.join("work/out.txt");
        write_approved(&target, b"ok").unwrap();
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "ok");
        assert!(write_approved(&d.join("work/link"), b"x").is_err());
        assert!(write_approved(&d.join("work/hard"), b"x").is_err());
        assert_eq!(std::fs::read_to_string(d.join("secret")).unwrap(), "s");
        let _ = std::fs::remove_dir_all(&d);
    }
}
