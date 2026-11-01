//! Part of `Hub`; see `hub/mod.rs`. A move whose client went away (`transfer_out.rs`): the chat
//! is frozen here, and nothing would unfreeze it. The source watches each move it began: once
//! the move has been idle (no read, commit or abort) for the lease, it ends the move itself.
//!
//! - The bundle was not read to its end: no target can have finished the move (`transfer_finish`
//!   checks every file's size), so the move is aborted and the chat runs here again.
//! - It was: the target named at begin (`to: {socket}`) is asked with
//!   `_acpmux/transfer_forget {transferId, sessionId}`, which drops any receive of the move
//!   there and refuses any later one (a late `transfer_receive` or `transfer_finish` fails), and
//!   says whether the chat landed (a target on another machine, `to-ssh`, through an ssh
//!   forward of its socket). It landed: the
//!   move commits. It did not: the move aborts. A target that cannot answer, or a move with no
//!   target named, keeps the chat frozen, and the source asks again after another lease.
//!
//! Its state is in the move's directory, so a daemon that restarts mid-move watches it again:
//! `alive` (touched by begin and each read), `read` (each file read to its end), `to` and
//! `to-ssh` and `to-host`.

use super::transfer_out::{bundle_files, names_a_move, transfers_dir};
use super::*;
use cmux_json::JsonSet as _;

/// How long a move may go without its client before the source ends it.
pub(super) const TRANSFER_LEASE: std::time::Duration = std::time::Duration::from_secs(300);

/// How long the source waits for the target's answer to `transfer_forget`.
const ASK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Held while a page is read and noted, and while the watch decides a move was not read to its
/// end and aborts it: a client never gets a bundle's last page from an aborted move.
pub(super) static PAGES: StdMutex<()> = StdMutex::new(());

/// When the move in `dir` last heard from its client (`alive` holds the Unix time in ms), or None
/// when it has no record of it.
fn last_activity(dir: &Path) -> Option<std::time::SystemTime> {
    let ms: u64 = std::fs::read_to_string(dir.join("alive")).ok()?.trim().parse().ok()?;
    Some(std::time::UNIX_EPOCH + std::time::Duration::from_millis(ms))
}

/// Whether every file of the move in `dir` was read to its end; None when that is unknown.
fn fully_read(dir: &Path) -> Option<bool> {
    let bundle = std::fs::read_dir(dir).ok()?.flatten().find(|e| e.path().is_dir())?.path();
    let files = bundle_files(&bundle).ok()?;
    let read = std::fs::read_to_string(dir.join("read")).unwrap_or_default();
    let read: Vec<&str> = read.lines().collect();
    // An empty file needs no page: the target has it whole without one.
    Some(files.iter().all(|(path, size)| *size == 0 || read.contains(&path.as_str())))
}

/// The client heard from the move in `dir`: begin, or a page read (`path` to its end with `eof`).
pub(super) fn note_activity(dir: &Path, eof_of: Option<&str>) {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    let _ = std::fs::write(dir.join("alive"), now.unwrap_or_default().as_millis().to_string());
    if let Some(path) = eof_of {
        use std::io::Write;
        let file = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("read"));
        if let Ok(mut file) = file {
            let _ = writeln!(file, "{path}");
        }
    }
}

/// A unix socket this user owns: the source connects to the target it names.
#[cfg(unix)]
fn own_socket(path: &Path) -> bool {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    path.is_absolute()
        && std::fs::symlink_metadata(path).is_ok_and(|m| {
            // SAFETY: getuid has no preconditions and cannot fail.
            m.file_type().is_socket() && m.uid() == unsafe { libc::getuid() }
        })
}
#[cfg(not(unix))]
fn own_socket(_path: &Path) -> bool {
    false
}

/// Asks the target at `socket` to drop its receive of the move and whether the chat landed
/// there; None when it cannot say.
async fn ask_target(socket: &Path, session_id: &str, transfer_id: &str) -> Option<bool> {
    if !own_socket(socket) {
        return None;
    }
    let ask = async {
        let client = crate::client::Client::connect(socket).await.ok()?;
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-transfer-watch"}});
        client.request(crate::rpc::method::INITIALIZE, hello).await.ok()?;
        let forget = json!({"transferId": transfer_id, "sessionId": session_id});
        let answer = client.request("_acpmux/transfer_forget", forget).await.ok()?;
        answer["landed"].as_bool()
    };
    tokio::time::timeout(ASK_TIMEOUT, ask).await.ok().flatten()
}

impl Hub {
    /// How long a move may go without its client before the source ends it (tests shorten it).
    /// A watch already waiting on the old lease reads the new one at once.
    pub fn set_transfer_lease(&self, lease: std::time::Duration) {
        *self.transfer_lease.lock().unwrap_or_else(|e| e.into_inner()) = lease;
        self.transfer_lease_changed.notify_waiters();
    }

    /// A move of a stopped chat that a restart cut: its bundle (`transfers/<id>/<chat>`) is
    /// still there, so it neither committed nor aborted. The chat is frozen again under that
    /// move, for its client to finish or its watch to end.
    fn refreeze_stopped_moves(&self) {
        let Ok(entries) = std::fs::read_dir(transfers_dir()) else { return };
        for entry in entries.flatten() {
            let transfer_id = entry.file_name().to_string_lossy().into_owned();
            // A receive (`in-…`) or a forget mark is not a move out.
            if !super::transfer::is_plain_id(&transfer_id)
                || transfer_id.to_ascii_lowercase().starts_with("in-")
                || transfer_id.starts_with("forgot-")
            {
                continue;
            }
            let Ok(inner) = std::fs::read_dir(entry.path()) else { continue };
            for chat in inner.flatten().filter(|e| e.path().is_dir()) {
                let id = chat.file_name().to_string_lossy().into_owned();
                let Some(session) =
                    self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned()
                else {
                    continue;
                };
                let mut moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
                if moving.is_none() && session.meta().moved_to.is_none() {
                    *moving = Some(transfer_id.clone());
                }
            }
        }
    }

    /// Watches the move `transfer_id` of `session` until it ends.
    pub(super) fn watch_transfer(self: &Arc<Self>, session: &Arc<Session>, transfer_id: &str) {
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let (hub, session, transfer_id) = (self.clone(), session.clone(), transfer_id.to_owned());
        tokio::spawn(async move { hub.transfer_watch(&session, &transfer_id).await });
    }

    /// Every move a chat here is in, once the daemon starts. A stopped chat's move is not in
    /// its queue's restore (a closed chat's log is not read at load), so it is found by its
    /// bundle under `transfers/` and frozen again here.
    pub(super) fn watch_transfers(self: &Arc<Self>) {
        self.refreeze_stopped_moves();
        for session in self.sessions() {
            if let Some(transfer_id) = session.moving().filter(|id| names_a_move(id)) {
                self.watch_transfer(&session, &transfer_id);
            }
        }
    }

    async fn transfer_watch(self: &Arc<Self>, session: &Arc<Session>, transfer_id: &str) {
        let dir = transfers_dir().join(transfer_id);
        // A commit marks where the chat went (its `moving` stays); an abort clears `moving`. A
        // stopped chat is closed for its whole move, so its status says nothing here.
        while session.moving().as_deref() == Some(transfer_id) && session.meta().moved_to.is_none()
        {
            // Enabled before the lease is read, so a change after the read is not missed.
            let changed = self.transfer_lease_changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let lease = *self.transfer_lease.lock().unwrap_or_else(|e| e.into_inner());
            // A stamp ahead of the clock (it stepped back) counts as activity just now.
            let idle = last_activity(&dir).map_or(lease, |t| t.elapsed().unwrap_or_default());
            if idle < lease {
                tokio::select! {
                    () = tokio::time::sleep(lease - idle) => {}
                    () = changed => {}
                }
                continue;
            }
            if self.end_stalled_move(session, transfer_id, &dir).await {
                return;
            }
            tracing::warn!(session = %session.id, transfer_id, "a stalled move's target cannot say whether it took the chat; it stays frozen");
            tokio::select! {
                () = tokio::time::sleep(lease) => {}
                () = changed => {}
            }
        }
    }

    /// Ends a move its client left; false when only the target could tell how, and did not.
    async fn end_stalled_move(
        self: &Arc<Self>,
        session: &Arc<Session>,
        transfer_id: &str,
        dir: &Path,
    ) -> bool {
        {
            let _pages = PAGES.lock().unwrap_or_else(|e| e.into_inner());
            if fully_read(dir) == Some(false) {
                if let Err(e) = self.transfer_abort(session, transfer_id, Some("stalled")) {
                    tracing::warn!(session = %session.id, transfer_id, "ending a stalled move: {}", e.message);
                }
                return true;
            }
        }
        let ssh = std::fs::read_to_string(dir.join("to-ssh")).ok();
        let landed = match (std::fs::read_to_string(dir.join("to")), ssh) {
            (Ok(socket), None) => {
                ask_target(Path::new(socket.trim()), &session.id, transfer_id).await
            }
            // On another machine: asked through a forward of its socket, closed after.
            (Ok(socket), Some(host)) => {
                match crate::ssh_forward::Forward::open(host.trim(), socket.trim()).await {
                    Ok(fwd) => ask_target(&fwd.local, &session.id, transfer_id).await,
                    Err(e) => {
                        tracing::warn!(session = %session.id, transfer_id, "reaching a stalled move's target: {e:#}");
                        None
                    }
                }
            }
            (Err(_), _) => None,
        };
        let ended = match landed {
            Some(true) => {
                let mut to = json!({"sessionId": session.id, "by": "watch"});
                // Where it went, so `resolve` follows it to that peer (`locate.rs`).
                if let Ok(host) = std::fs::read_to_string(dir.join("to-host")) {
                    to.set("host", json!(host.trim()));
                }
                self.transfer_commit(session, transfer_id, to).await.map(|_| ())
            }
            Some(false) => {
                let _pages = PAGES.lock().unwrap_or_else(|e| e.into_inner());
                self.transfer_abort(session, transfer_id, Some("stalled")).map(|_| ())
            }
            None => return false,
        };
        if let Err(e) = ended {
            tracing::warn!(session = %session.id, transfer_id, "ending a stalled move: {}", e.message);
        }
        true
    }
}
