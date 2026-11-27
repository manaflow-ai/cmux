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
//!   forward of its socket; one only the team hub reaches, `to-hub`, with op `move_forget`
//!   through the hub, `transfer_pull.rs`). It landed: the
//!   move commits. It did not: the move aborts.
//! - The hub says the target machine is deleted (`mesh.recipient_revoked`: its credential was
//!   revoked and no newer one joined): it can never answer, so the move aborts
//!   (`target_deleted`) and the chat runs here again.
//! - A target that cannot answer, or a move with no target named, keeps the chat frozen (two
//!   copies would both run), and the source asks again after another lease. Once it has stayed
//!   undecided for [`OFFER_AFTER`] (RFD 0063, "a move whose target never answers ends"), the
//!   chat is offered to the person: a `transfer_undecided` record, `session info`'s
//!   `moveUndecided`, and `acpmux session move --abort --take-back CHAT` takes it back here
//!   (`taken_back`). The watch goes on asking, so a target that answers later still ends it.
//!
//! Its state is in the move's directory, so a daemon that restarts mid-move watches it again:
//! `alive` (touched by begin and each read), `paged` (a page was read), `read` (each file read to
//! its end), `to` and `to-ssh` and `to-host`, `undecided` (when its target first could not say), `offered`.

use super::transfer_out::{bundle_files, names_a_move, transfer_epoch_marker, transfers_dir};
use super::*;
use cmux_json::JsonSet as _;

/// How long a move may go without its client before the source ends it.
pub(super) const TRANSFER_LEASE: std::time::Duration = std::time::Duration::from_secs(300);

/// How long the source waits for the target's answer to `transfer_forget`.
const ASK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// How long a move's target may stay unable to say whether it took the chat before the chat is
/// offered to the person (`transfer_undecided`). With the lease before the first ask, a chat
/// frozen by a target that never answers is offered back about ten minutes after its client
/// went away. Tests shorten it with the lease ([`offer_after`]).
pub(super) const OFFER_AFTER: std::time::Duration = TRANSFER_LEASE;

/// The bound for a watch running under `lease`: [`OFFER_AFTER`], or one lease when a test
/// shortened the lease below it.
pub(super) fn offer_after(lease: std::time::Duration) -> std::time::Duration {
    OFFER_AFTER.min(lease)
}

/// The file holding when a move's target first could not say (Unix ms).
const UNDECIDED: &str = "undecided";
/// The file that says the chat was offered back to the person (Unix ms of the offer).
const OFFERED: &str = "offered";

/// What a stalled move's target said when asked to give the move up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::hub) enum TargetSays {
    /// The chat landed there: the move commits.
    Landed,
    /// It did not, and now never will: the move aborts.
    NotLanded,
    /// The hub knows the machine is gone for good: the move aborts.
    Deleted,
    /// No answer, or no target to ask: the chat stays frozen.
    Unknown,
}

impl TargetSays {
    pub(in crate::hub) fn landed(landed: bool) -> Self {
        if landed { Self::Landed } else { Self::NotLanded }
    }
}

fn read_ms(path: &Path) -> Option<u64> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn now_ms() -> u64 {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    u64::try_from(now.unwrap_or_default().as_millis()).unwrap_or(u64::MAX)
}

/// The move in `dir`'s target could not say, again: stamps when it first could not, and answers
/// how long it has been undecided since.
pub(super) fn note_undecided(dir: &Path) -> std::time::Duration {
    let path = dir.join(UNDECIDED);
    let since = read_ms(&path).unwrap_or_else(|| {
        let now = now_ms();
        let _ = crate::home_fs::write(&path, now.to_string());
        now
    });
    std::time::Duration::from_millis(now_ms().saturating_sub(since))
}

/// When the move in `dir`'s target first could not say (Unix ms), and when the chat was offered
/// back to the person, if it was.
pub(in crate::hub) fn undecided(dir: &Path) -> Option<(u64, Option<u64>)> {
    Some((read_ms(&dir.join(UNDECIDED))?, read_ms(&dir.join(OFFERED))))
}

/// Held while a page is read and noted, and while the watch decides a move was not read to its
/// end and aborts it: a client never gets a bundle's last page from an aborted move.
pub(super) static PAGES: StdMutex<()> = StdMutex::new(());

/// The claim on a move's one watch (`Hub::claim_move_watch`), given back when dropped.
pub(super) struct MoveWatch {
    hub: Arc<Hub>,
    transfer_id: String,
}

impl Drop for MoveWatch {
    fn drop(&mut self) {
        let mut watched = self.hub.watched_moves.lock().unwrap_or_else(|e| e.into_inner());
        watched.remove(&self.transfer_id);
    }
}

/// When the move in `dir` last heard from its client (`alive` holds the Unix time in ms), or None
/// when it has no record of it.
pub(in crate::hub) fn last_activity(dir: &Path) -> Option<std::time::SystemTime> {
    let ms: u64 = std::fs::read_to_string(dir.join("alive")).ok()?.trim().parse().ok()?;
    Some(std::time::UNIX_EPOCH + std::time::Duration::from_millis(ms))
}

/// Whether every file of the move in `dir` was read to its end; None when that is unknown.
pub(super) fn fully_read(dir: &Path) -> Option<bool> {
    let bundle = std::fs::read_dir(dir).ok()?.flatten().find(|e| e.path().is_dir())?.path();
    let files = bundle_files(&bundle).ok()?;
    let read = std::fs::read_to_string(dir.join("read")).unwrap_or_default();
    let read: Vec<&str> = read.lines().collect();
    // An empty file needs no page: the target has it whole without one.
    Some(files.iter().all(|(path, size)| *size == 0 || read.contains(&path.as_str())))
}

/// The file that says a client read a page of the move: its copy began, so a client is driving it.
const PAGED: &str = "paged";

/// A client read a page of the move in `dir` (`transfer_read`): stamps [`PAGED`] once.
pub(super) fn note_paged(dir: &Path) {
    let path = dir.join(PAGED);
    if !path.exists() {
        let _ = crate::home_fs::write(&path, "");
    }
}

/// Whether any page of the move in `dir` was read: a client began its copy.
pub(super) fn was_paged(dir: &Path) -> bool {
    dir.join(PAGED).exists()
        || std::fs::read_to_string(dir.join("read")).is_ok_and(|r| !r.trim().is_empty())
}

/// How long ago the move last heard from its driver. A missing or malformed stamp is
/// deliberately unknown: a takeover must never guess that a move is dead.
pub(super) fn idle_for(dir: &Path) -> Option<std::time::Duration> {
    last_activity(dir).map(|at| at.elapsed().unwrap_or_default())
}

/// A takeover is safe only while the old driver has not delivered a complete bundle. Once every
/// file was read, the target may have finished and the source must keep the move fenced until it
/// can ask that target whether the chat landed.
pub(super) fn takeover_allowed(
    idle: Option<std::time::Duration>,
    fully_read: Option<bool>,
    lease: std::time::Duration,
) -> bool {
    idle.is_some_and(|age| age >= lease) && fully_read == Some(false)
}

/// A marker newer than the durable event log means the daemon crashed between writing the
/// marker and appending `transfer_out`; that bundle was never offered to another owner.
fn marker_is_uncommitted(marker: Option<u64>, durable_epoch: u64) -> bool {
    marker.is_some_and(|marker| marker > durable_epoch)
}

/// The client heard from the move in `dir`: begin, or a page read (`path` to its end with `eof`).
pub(super) fn note_activity(dir: &Path, eof_of: Option<&str>) {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    let _ =
        crate::home_fs::write(dir.join("alive"), now.unwrap_or_default().as_millis().to_string());
    if let Some(path) = eof_of {
        use std::io::Write;
        let file =
            crate::home_fs::OpenOptions::new().create(true).append(true).open(dir.join("read"));
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

/// Where the move in `dir` went, as it was begun: the target machine's host, hub daemon id or
/// socket, the first that is known.
fn move_target(dir: &Path) -> Option<String> {
    ["to-host", super::transfer_pull::TO_HUB, "to"]
        .into_iter()
        .find_map(|f| std::fs::read_to_string(dir.join(f)).ok())
        .map(|t| t.trim().to_owned())
        .filter(|t| !t.is_empty())
}

/// Asks the target at `socket` to drop its receive of the move and whether the chat landed
/// there.
async fn ask_target(socket: &Path, session_id: &str, transfer_id: &str) -> TargetSays {
    ask_socket(socket, session_id, transfer_id)
        .await
        .map_or(TargetSays::Unknown, TargetSays::landed)
}

async fn ask_socket(socket: &Path, session_id: &str, transfer_id: &str) -> Option<bool> {
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
            // A receive (`in-…`), a forget mark or a prepare (`pre-…`) is not a move out.
            if !super::transfer::is_plain_id(&transfer_id)
                || transfer_id.to_ascii_lowercase().starts_with("in-")
                || transfer_id.starts_with("forgot-")
                || transfer_id.starts_with("pre-")
            {
                continue;
            }
            let Ok(inner) = std::fs::read_dir(entry.path()) else { continue };
            for chat in inner.flatten().filter(|e| e.path().is_dir()) {
                let id = chat.file_name().to_string_lossy().into_owned();
                let Some(session) = self.session_get(&id) else {
                    continue;
                };
                // A crash after the epoch marker was written but before `transfer_out` was
                // appended leaves a bundle with no durable ownership authority. Do not restore
                // that half-move as live: discard it and let the chat remain local.
                if session.ownership_epoch_is_valid()
                    && marker_is_uncommitted(
                        transfer_epoch_marker(&entry.path()).ok().flatten(),
                        session.ownership_epoch(),
                    )
                {
                    tracing::warn!(session = %session.id, transfer_id, "discarding transfer marker without durable transfer_out");
                    let _ = crate::home_fs::remove_dir_all(entry.path());
                    break;
                }
                // Under the `moving` lock: an abort logs `transfer_aborted` before it ends the
                // move and removes the bundle (`transfer_out.rs`), so a bundle read here before
                // that removal is no move to freeze again once the log says it ended (an abort
                // just after a restart, or a crash before the bundle was removed).
                let mut moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
                if moving.is_none()
                    && session.meta().moved_to.is_none()
                    && session.transfer_blocked() != Some(false)
                {
                    *moving = Some(transfer_id.clone());
                }
            }
        }
    }

    /// The one watch of move `transfer_id`, None when a watch, or the begin that makes the move,
    /// holds it already. A begin claims it before it makes the bundle and hands it to its watch
    /// once the move's `alive` stamp is written (`transfer_out.rs`): the startup pass
    /// (`watch_transfers`) can run while a begin is still making its bundle, and a watch that
    /// read no stamp then took the move for one idle a whole lease and ended it.
    pub(super) fn claim_move_watch(self: &Arc<Self>, transfer_id: &str) -> Option<MoveWatch> {
        let mut watched = self.watched_moves.lock().unwrap_or_else(|e| e.into_inner());
        watched
            .insert(transfer_id.to_owned())
            .then(|| MoveWatch { hub: self.clone(), transfer_id: transfer_id.to_owned() })
    }

    /// Watches the move `transfer_id` of `session`, which this daemon found at start, until it
    /// ends, unless another holds its watch. A move nobody read a page of cannot have landed
    /// anywhere and has no client copying it, so it ends now (the chat runs here again) rather
    /// than after a lease the chat spends frozen (RFD 0063, "Nothing lives only on the VM"). A
    /// move a client was midway through copying is kept for its lease: a take-over
    /// (`acpmux daemon run --take-over`) leaves that client reading, and its copy goes on from
    /// the offset it reached against the new daemon. A move read to its end waits for its lease.
    pub(super) fn watch_transfer_after_restart(
        self: &Arc<Self>,
        session: &Arc<Session>,
        transfer_id: &str,
    ) {
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let Some(watch) = self.claim_move_watch(transfer_id) else { return };
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_until_cancelled("move-watch-restart", async move {
            let dir = transfers_dir().join(&watch.transfer_id);
            if dir.is_dir()
                && fully_read(&dir) == Some(false)
                && !was_paged(&dir)
                && hub.end_stalled_move(&session, &watch.transfer_id, &dir).await
            {
                return;
            }
            hub.transfer_watch(&session, &watch.transfer_id).await;
        });
    }

    /// Watches the move `watch` claims until it ends; the claim goes with the watch.
    pub(super) fn watch_claimed(self: &Arc<Self>, session: &Arc<Session>, watch: MoveWatch) {
        if tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move { hub.transfer_watch(&session, &watch.transfer_id).await });
    }

    /// Every move a chat here is in, once the daemon starts. A stopped chat's move is not in
    /// its queue's restore (a closed chat's log is not read at load), so it is found by its
    /// bundle under `transfers/` and frozen again here.
    pub(super) fn watch_transfers(self: &Arc<Self>) {
        self.refreeze_stopped_moves();
        for session in self.sessions() {
            if let Some(transfer_id) = session.moving().filter(|id| names_a_move(id)) {
                self.watch_transfer_after_restart(&session, &transfer_id);
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
            let undecided = note_undecided(&dir);
            tracing::warn!(session = %session.id, transfer_id, undecided_s = undecided.as_secs(), "a stalled move's target cannot say whether it took the chat; it stays frozen");
            if undecided >= offer_after(lease) {
                self.offer_take_back(session, transfer_id, &dir, undecided);
            }
            tokio::select! {
                () = tokio::time::sleep(lease) => {}
                () = changed => {}
            }
        }
    }

    /// The chat was offered back once (`transfer_undecided`): logged once per move, so a
    /// client can show the choice, and marked in the move's directory so `session info` shows
    /// it (`moveUndecided`) and `--take-back` may end the move.
    fn offer_take_back(
        &self,
        session: &Arc<Session>,
        transfer_id: &str,
        dir: &Path,
        undecided: std::time::Duration,
    ) {
        if dir.join(OFFERED).exists() {
            return;
        }
        let mut record = json!({
            "transferId": transfer_id,
            "undecidedSecs": undecided.as_secs(),
            "epoch": session.ownership_epoch(),
            "takeBack": format!("acpmux session move --abort --take-back {}", session.id),
        });
        if let Some(target) = move_target(dir) {
            record.set("target", json!(target));
        }
        let (_, logged) = self.append_at(session, "mux", "transfer_undecided", record, None, None);
        if logged {
            let _ = crate::home_fs::write(dir.join(OFFERED), now_ms().to_string());
            tracing::warn!(session = %session.id, transfer_id, "a move's target has not answered for {}s; the chat is offered back to its person", undecided.as_secs());
        }
    }

    /// The epoch a move in `dir` fenced the chat at; None when its marker is unreadable.
    fn stalled_move_epoch(session: &Session, transfer_id: &str, dir: &Path) -> Option<u64> {
        match transfer_epoch_marker(dir) {
            Ok(Some(epoch)) => Some(epoch),
            Ok(None) => Some(session.ownership_epoch()),
            Err(error) => {
                tracing::warn!(session = %session.id, transfer_id, "stalled move epoch unreadable: {}", error.message);
                None
            }
        }
    }

    /// The person took the chat back from a move whose target stayed undecided past the bound
    /// (`session move --abort --take-back`): the move aborts here (`taken_back`). Refused before
    /// the chat was offered: until then the target may still answer.
    pub(in crate::hub) fn take_back_undecided(
        self: &Arc<Self>,
        session: &Arc<Session>,
        transfer_id: &str,
        dir: &Path,
    ) -> Result<(), RpcError> {
        let offered = undecided(dir).and_then(|(_, offered)| offered);
        if offered.is_none() {
            let lease = *self.transfer_lease.lock().unwrap_or_else(|e| e.into_inner());
            return Err(RpcError::new(
                -32000,
                format!(
                    "transfer.too_soon: the target of move {transfer_id} has not been silent \
                     for {}s yet; it may still answer, so the chat is not offered back",
                    offer_after(lease).as_secs()
                ),
            ));
        }
        let Some(epoch) = Self::stalled_move_epoch(session, transfer_id, dir) else {
            return Err(RpcError::new(-32000, "transfer.epoch: the move's epoch is unreadable"));
        };
        let _pages = PAGES.lock().unwrap_or_else(|e| e.into_inner());
        self.transfer_abort_with_epoch(session, transfer_id, Some("taken_back"), Some(epoch))
            .map(|_| ())
    }

    /// Ends a move its client left; false when only the target could tell how, and did not.
    pub(in crate::hub) async fn end_stalled_move(
        self: &Arc<Self>,
        session: &Arc<Session>,
        transfer_id: &str,
        dir: &Path,
    ) -> bool {
        let Some(epoch) = Self::stalled_move_epoch(session, transfer_id, dir) else {
            return false;
        };
        // A durable transfer_out from an older daemon can outlive its bundle directory (for
        // example, a crash between the event and export). There is no target to query in that
        // case, so abort the fenced move rather than leaving the chat frozen forever.
        if !dir.is_dir() {
            if let Err(error) = self.transfer_abort_with_epoch(
                session,
                transfer_id,
                Some("missing_bundle"),
                Some(epoch),
            ) {
                tracing::warn!(session = %session.id, transfer_id, "aborting move with missing bundle: {}", error.message);
            }
            return true;
        }
        {
            let _pages = PAGES.lock().unwrap_or_else(|e| e.into_inner());
            if fully_read(dir) == Some(false) {
                if let Err(e) = self.transfer_abort_with_epoch(
                    session,
                    transfer_id,
                    Some("stalled"),
                    Some(epoch),
                ) {
                    tracing::warn!(session = %session.id, transfer_id, "ending a stalled move: {}", e.message);
                }
                return true;
            }
        }
        let ssh = std::fs::read_to_string(dir.join("to-ssh")).ok();
        let hub = std::fs::read_to_string(dir.join(super::transfer_pull::TO_HUB)).ok();
        let says = match (std::fs::read_to_string(dir.join("to")), ssh) {
            // A machine only the team hub reaches: asked with op `move_forget` there.
            _ if hub.is_some() => {
                let daemon = hub.as_deref().unwrap_or_default().trim();
                self.ask_hub_forget(daemon, &session.id, transfer_id).await
            }
            (Ok(socket), None) => {
                ask_target(Path::new(socket.trim()), &session.id, transfer_id).await
            }
            // On another machine: asked through a forward of its socket, closed after.
            (Ok(socket), Some(host)) => {
                match crate::ssh_forward::Forward::open(host.trim(), socket.trim()).await {
                    Ok(fwd) => ask_target(&fwd.local, &session.id, transfer_id).await,
                    Err(e) => {
                        tracing::warn!(session = %session.id, transfer_id, "reaching a stalled move's target: {e:#}");
                        TargetSays::Unknown
                    }
                }
            }
            (Err(_), _) => TargetSays::Unknown,
        };
        let says = test_seam::answer(transfer_id).unwrap_or(says);
        let ended = match says {
            TargetSays::Landed => {
                let mut to = json!({"sessionId": session.id, "by": "watch"});
                // Where it went, so `resolve` follows it to that peer (`locate.rs`).
                if let Ok(host) = std::fs::read_to_string(dir.join("to-host")) {
                    to.set("host", json!(host.trim()));
                }
                self.transfer_commit_with_epoch(session, transfer_id, to, Some(epoch), None)
                    .await
                    .map(|_| ())
            }
            TargetSays::NotLanded | TargetSays::Deleted => {
                let reason = if says == TargetSays::Deleted { "target_deleted" } else { "stalled" };
                let _pages = PAGES.lock().unwrap_or_else(|e| e.into_inner());
                self.transfer_abort_with_epoch(session, transfer_id, Some(reason), Some(epoch))
                    .map(|_| ())
            }
            TargetSays::Unknown => return false,
        };
        if let Err(e) = ended {
            tracing::warn!(session = %session.id, transfer_id, "ending a stalled move: {}", e.message);
        }
        true
    }
}

/// What a test says a move's target answers, in place of asking it (a hub that knows the
/// machine is deleted, or a target that never answers), keyed by transfer id.
#[cfg(test)]
pub(in crate::hub) mod test_seam {
    use super::TargetSays;
    use std::collections::HashMap;
    use std::sync::{LazyLock, Mutex};

    static ANSWERS: LazyLock<Mutex<HashMap<String, TargetSays>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));

    pub(in crate::hub) fn answer(transfer_id: &str) -> Option<TargetSays> {
        ANSWERS.lock().unwrap_or_else(|e| e.into_inner()).get(transfer_id).copied()
    }

    pub(in crate::hub) fn set(transfer_id: &str, says: TargetSays) {
        ANSWERS.lock().unwrap_or_else(|e| e.into_inner()).insert(transfer_id.to_owned(), says);
    }
}

#[cfg(not(test))]
mod test_seam {
    pub(super) fn answer(_transfer_id: &str) -> Option<super::TargetSays> {
        None
    }
}

#[cfg(test)]
#[path = "transfer_watch_tests.rs"]
mod deleted_target_tests;

#[cfg(test)]
mod tests {
    use super::{marker_is_uncommitted, takeover_allowed};

    #[test]
    fn marker_ahead_of_durable_epoch_is_not_resumed() {
        assert!(marker_is_uncommitted(Some(1), 0));
        assert!(!marker_is_uncommitted(Some(1), 1));
        assert!(!marker_is_uncommitted(None, 0));
    }

    #[test]
    fn dead_driver_can_be_taken_over_only_before_bundle_is_complete() {
        let lease = std::time::Duration::from_secs(10);
        assert!(takeover_allowed(Some(lease), Some(false), lease));
        assert!(!takeover_allowed(
            Some(lease - std::time::Duration::from_secs(1)),
            Some(false),
            lease
        ));
        assert!(!takeover_allowed(Some(lease), Some(true), lease));
        assert!(!takeover_allowed(None, Some(false), lease));
    }
}
