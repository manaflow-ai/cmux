//! Part of `Hub`; see `hub/mod.rs`. Messages `acpmux send --no-wait` hands to this daemon to
//! deliver (the transport, `server/outbox.rs`), and the peer acceptances a forwarded prompt waits
//! for.
//!
//! A sender gets its delivery id as soon as the message is recorded here, whatever the target: a
//! session on this daemon or on a peer behind ssh, connected or not. The daemon then delivers it
//! in the background, retrying with the same prompt id, so a target that already took it answers
//! with the first outcome instead of running it twice. Each delivery is `queued`, `delivering`
//! (attempt n), `delivered` (the target's acceptance: its session, turn and whether it steered),
//! `held` (the runaway guard holds it until the person resumes the pair, `agent_pairs.rs`) or
//! `failed` (the last error). The record is saved beside the sessions on every change, so a
//! daemon restart goes on with what was not delivered yet; a store in memory keeps it in memory.
//! Settled deliveries are kept for [`KEEP_SETTLED_MS`].
//!
//! On disk it is `outbox.json`, every delivery as of the last snapshot, and `outbox.journal`,
//! one line for each delivery changed since, in order; a reader takes the snapshot and then the
//! journal's lines, the last line for an id winning. The journal's first line names the snapshot
//! it follows (its size and SHA-256): a journal left beside any other snapshot (an older daemon
//! rewrote `outbox.json` without it, or a crash came between a new snapshot and the journal's
//! reset) is not read, so it never takes a delivery back to an older state. A change appends only the deliveries it
//! changed, so its cost does not grow with the deliveries kept: rewriting the whole file on every
//! change wrote 2 GB in 14 minutes with a day's 2,500 deliveries (5 MB) kept (hang-watch
//! `6159015094`, cmuxterm-hq#8660). A snapshot is written again once the journal is twice its
//! size (at least [`COMPACT_FLOOR`]), and at open when a journal is left over, so a change costs
//! about one and a half times its own lines however many deliveries are kept.
//!
//! A change returns once a file that holds it is on disk, unless the write failed: that is
//! logged and the change is only in memory until a later write succeeds, as before. A new
//! delivery is the exception: when its write fails it is taken out again and the sender is told,
//! so a message is never answered as kept when a restart would lose it. The files are
//! written outside the deliveries lock and changes made while one write runs share the next one
//! (group commit): 60 sends at once used to queue behind 180 whole-file writes and syncs, each up
//! to a second on a busy disk (`design/acpmux-perf.md` in leo-workspace).
//!
//! A peer answers a forwarded `session/prompt` only when its turn ends (or, for a steer, when the
//! agent's step ends), so the forwarding daemon passes the peer's `_acpmux/prompt_accepted` on to
//! the connection that sent the prompt as soon as it arrives ([`PeerAccepts`]).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Notify;

use crate::rpc::RpcError;

/// How long a delivered or failed message stays readable by `send --status`.
pub const KEEP_SETTLED_MS: u64 = 24 * 60 * 60 * 1000;

/// Shared bounded retry schedule for delivery and projection-only reconciliation.
pub(crate) const RETRY_DELAYS_SECS: &[u64] = &[2, 5, 10, 30, 60, 120, 300, 600, 900];

/// How long a message that could not be delivered yet (a peer that is down, a target that does
/// not answer) keeps being tried, at the last of [`RETRY_DELAYS_SECS`] once those run out, and
/// at once whenever a peer's link is ready again ([`Outbox::peer_ready`]). A message is not
/// lost because a machine was off or overloaded for half an hour (Leo, 2026-11-02: "sends
/// shouldn't time out just bc of load").
pub(crate) const RETRY_FOR_MS: u64 = KEEP_SETTLED_MS;

/// The journal is folded into a new snapshot once it holds this many bytes or twice as many as
/// the snapshot, whichever is more.
pub(crate) const COMPACT_FLOOR: u64 = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Queued,
    Delivering,
    Delivered,
    /// The target's daemon holds it for a paused agent pair: it runs when the person resumes the
    /// pair, never by a retry here.
    Held,
    Failed,
}

/// One message to deliver.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Delivery {
    pub id: String,
    /// The session key the sender named (`NAME`, an id, or `PEER/NAME`).
    pub target: String,
    /// The `session/prompt` params to send, `sessionId` = `target`; its prompt id is the
    /// delivery's idempotency key.
    pub request: Value,
    /// The session the sender's connection proved it runs in, sent again as the caller.
    #[serde(default)]
    pub caller: Option<String>,
    /// The session a sender's connection named with a caller token this daemon could not prove
    /// (an agent's shell holding a stale session's token). Sent again as that unproven caller
    /// (`server/outbox.rs` `attempt_once`), so the replay is no owner's terminal send either
    /// (`server/requests.rs` `owner_terminal`) and stays unverified, as the send itself was.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unproven_caller: Option<String>,
    /// The sender's connection declared no terminal (`cli_caller.rs`: an old acpmux CLI, or a
    /// shell in an acpmux session's environment whose token proved nothing): the replay declares
    /// an agent's shell, so it is no owner's terminal send either. False for a record saved
    /// before the field.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub not_terminal: bool,
    pub state: State,
    #[serde(default)]
    pub attempts: u32,
    /// No attempt so far could have reached the target: each one failed before the request
    /// left this daemon (`peer_unreachable`). Only such a delivery may go through the mesh
    /// relay instead (`server/mesh_send.rs` `relay`), whose message runs under its own prompt
    /// id. False for a record saved before the field, which may have reached it.
    #[serde(default)]
    pub never_sent: bool,
    /// The mesh relay post for it, recorded before it goes: the hub may hold it even when its
    /// answer was lost, so from then on only the relay tries it again, as the same message (the
    /// hub answers a key again only for the same message), and the peer's link never runs it as
    /// well. Cleared when the hub refuses it outright (`server/outbox.rs` `relay_attempt`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay_post: Option<crate::mesh::OutMessage>,
    #[serde(default)]
    pub error: Option<String>,
    /// The target's `_acpmux/prompt_accepted` (or its reply) once delivered.
    #[serde(default)]
    pub accepted: Option<Value>,
    pub created_at: u64,
    pub updated_at: u64,
}

impl Delivery {
    fn is_team_receipt(&self) -> bool {
        self.id.starts_with("mesh:") && self.request.get("teamOrigin") == Some(&Value::Bool(true))
    }

    pub fn prompt_id(&self) -> &str {
        self.request.pointer("/_meta/acpmux/promptId").and_then(Value::as_str).unwrap_or_default()
    }

    pub fn projection_only(&self) -> bool {
        self.request.pointer("/_meta/acpmux/forwardProjection").is_some()
    }

    pub fn settled(&self) -> bool {
        // Projection intents stay in a legacy-terminal state on disk. An older
        // daemon ignores them instead of executing a lookup as a prompt.
        if self.projection_only() && self.state == State::Held {
            return false;
        }
        matches!(self.state, State::Delivered | State::Held | State::Failed)
    }

    /// What `_acpmux/send_status` answers.
    pub fn status(&self) -> Value {
        json!({
            "deliveryId": self.id,
            "target": self.target,
            "promptId": self.prompt_id(),
            "status": self.state,
            "attempts": self.attempts,
            "error": self.error,
            "accepted": self.accepted,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            // Why it failed, for a program: the target's machine has no such session.
            "reason": self.no_session().then_some("no_session"),
        })
    }

    /// It failed because the target's machine has no such session (`server/outbox.rs`).
    pub fn no_session(&self) -> bool {
        self.state == State::Failed
            && self
                .error
                .as_deref()
                .is_some_and(|e| e.starts_with(super::no_session::NO_SESSION_PREFIX))
    }
}

/// The deliveries, saved at `path` when the store is on disk.
#[derive(Default)]
pub struct Outbox {
    deliveries: StdMutex<Book>,
    path: StdMutex<Option<PathBuf>>,
    /// What is on disk, held while a write runs.
    disk: StdMutex<Disk>,
    /// At most one bounded delivery/reconciliation task for each id in this launch.
    running: StdMutex<HashSet<String>>,
    /// Fired on every change: a `send_status` that waits wakes.
    pub changed: Notify,
    /// Fired when a peer's link is ready again (`hub/peers.rs`): a message waiting out a retry
    /// delay tries again at once instead of minutes later.
    pub peer_ready: Notify,
}

/// The deliveries and the number of changes made to them.
#[derive(Default)]
struct Book {
    deliveries: BTreeMap<String, Delivery>,
    changes: u64,
    /// The deliveries changed since the last write: the next one journals them.
    dirty: BTreeSet<String>,
}

/// What the files hold.
#[derive(Default)]
struct Disk {
    /// The last change on disk.
    saved: u64,
    /// Bytes of the journal's lines since the last snapshot, and of that snapshot.
    journal: u64,
    snapshot: u64,
    /// The journal's first line for the snapshot on disk.
    header: Vec<u8>,
    /// A journal that starts with `header` is on disk: changes append to it. Otherwise the next
    /// change writes a new journal whole (header and its lines).
    journal_open: bool,
    /// The next write is a snapshot: a journal was left at open, or an append failed.
    snapshot_next: bool,
    /// The journal may end in a torn line (it did at open, or an append failed): the next
    /// append starts with a newline, so that line never swallows the next one.
    torn: bool,
    /// Bytes written to both files in this launch.
    written: u64,
    /// A snapshot that failed (a nearly full disk) is tried again once the journal holds this
    /// many bytes, not on every change.
    snapshot_retry_at: u64,
}

impl Outbox {
    /// Reads the saved deliveries at `path` and saves there from now on. Returns the ones not
    /// settled, to deliver again. A file that cannot be read starts empty (and is replaced).
    pub fn open(&self, path: &Path) -> Vec<Delivery> {
        let saved = read_saved(path);
        *self.path.lock().unwrap_or_else(|e| e.into_inner()) = Some(path.to_owned());
        {
            let mut disk = self.disk.lock().unwrap_or_else(|e| e.into_inner());
            disk.snapshot = saved.snapshot_bytes;
            disk.header = saved.header;
            disk.journal = saved.journal_bytes;
            disk.journal_open = saved.journal_open;
            disk.snapshot_next = saved.journal_bytes > 0;
            disk.torn = saved.torn;
            disk.snapshot_retry_at = 0;
        }
        let mut book = self.book();
        book.deliveries.extend(saved.deliveries);
        // Attachments come back from beside the file; ones no waiting delivery names go.
        let dir = attachments_dir(path);
        let mut named = std::collections::HashSet::new();
        for d in book.deliveries.values_mut().filter(|d| !d.settled()) {
            let kept = dir.join(format!("{}.json", d.id));
            if let Some(request) =
                std::fs::read(&kept).ok().and_then(|b| serde_json::from_slice(&b).ok())
            {
                d.request = request;
                named.insert(kept);
            }
        }
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            if !named.contains(&entry.path()) {
                let _ = crate::home_fs::remove_file(entry.path());
            }
        }
        let pending = book.deliveries.values().filter(|d| !d.settled()).cloned().collect();
        // A journal left over is folded into the snapshot now, so the files read alone by an
        // older daemon hold everything.
        if saved.journal_bytes > 0 {
            let change = book.changed();
            drop(book);
            self.save(change);
        }
        pending
    }

    /// Folds the journal into a new snapshot, so `outbox.json` alone holds everything: at a
    /// daemon's shutdown (`hub/shutdown.rs` `flush`), for whichever daemon starts next, an older
    /// one too.
    pub fn compact(&self) {
        // The path lock is never held while the disk lock is taken, nor taken under it.
        if self.path.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            return;
        }
        {
            let mut disk = self.disk.lock().unwrap_or_else(|e| e.into_inner());
            if disk.journal == 0 && !disk.snapshot_next {
                return;
            }
            disk.snapshot_next = true;
        }
        let change = self.book().changed();
        self.save(change);
    }

    fn book(&self) -> std::sync::MutexGuard<'_, Book> {
        self.deliveries.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Where delivery `d`'s attachments are kept, when it has any and the outbox is on disk.
    pub fn attachments_path(&self, d: &Delivery) -> Option<PathBuf> {
        let blocks = d.request.get("prompt").and_then(Value::as_array)?;
        let path = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        crate::attach::any(blocks).then(|| attachments_dir(&path).join(format!("{}.json", d.id)))
    }

    /// Records a new delivery; the same prompt id to the same target again answers with the first
    /// one. Fails when the file cannot be written: then the delivery is not kept in memory either
    /// (not kept means not sent), and a later write never puts it on disk.
    pub fn add(&self, delivery: Delivery) -> anyhow::Result<Delivery> {
        let (delivery, change, added) = self.add_scoped(delivery, false);
        self.save_or_take_out(change, added.then_some(delivery.id.as_str()))?;
        // The first add of this prompt id failed and took it out after this one found it.
        if !added && !self.book().deliveries.contains_key(&delivery.id) {
            anyhow::bail!("the first send of this prompt id was not saved");
        }
        self.changed.notify_waiters();
        Ok(delivery)
    }

    /// A direct forward's recovery intent is scoped to its proven sender and target.
    /// Independent sessions may legitimately use the same client prompt id.
    /// Unlike ordinary queued deliveries, a forward must not proceed when this
    /// write fails: no later retry can recreate its intent after a restart.
    pub fn remember_forward(&self, delivery: Delivery) -> anyhow::Result<Delivery> {
        let (delivery, change, _) = self.add_scoped(delivery, true);
        self.save_checked(change)?;
        self.changed.notify_waiters();
        Ok(delivery)
    }

    /// The delivery that holds the prompt id, the change to wait for, and whether it is new.
    /// A prompt id names one message to one target, as the target's prompt ledger keys it
    /// (`Hub::prompt_with`): the same id to another target is another message.
    fn add_scoped(&self, delivery: Delivery, scoped: bool) -> (Delivery, u64, bool) {
        let mut book = self.book();
        let prompt_id = delivery.prompt_id().to_owned();
        if let Some(first) = book.deliveries.values().find(|d| {
            !d.is_team_receipt()
                && d.prompt_id() == prompt_id
                && d.target == delivery.target
                && d.request.pointer("/_meta/acpmux/forwardProjection").is_some() == scoped
                && (!scoped
                    || (d.caller == delivery.caller
                        && projected_message(d) == projected_message(&delivery)))
        }) {
            let first = first.clone();
            // The first add may still be writing: answer once the file holds it too.
            let change = book.changes;
            return (first, change, false);
        }
        book.deliveries.insert(delivery.id.clone(), delivery.clone());
        book.dirty.insert(delivery.id.clone());
        let change = book.changed();
        (delivery, change, true)
    }

    pub fn start_delivery(&self, id: &str) -> bool {
        self.running.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned())
    }

    pub fn end_delivery(&self, id: &str) {
        self.running.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
    }

    /// Whether a delivery not settled yet goes to a target `named` matches (a session's id, name
    /// or an id prefix the sender gave): a turn may still come for that session
    /// (`Hub::work_coming`).
    pub fn pending_to(&self, named: impl Fn(&str) -> bool) -> bool {
        self.book().deliveries.values().any(|d| {
            !d.settled() && !d.projection_only() && !d.is_team_receipt() && named(&d.target)
        })
    }

    /// How many deliveries are not settled yet (a projection intent waiting on its receiver's
    /// journal counts).
    pub fn unsettled(&self) -> usize {
        self.book().deliveries.values().filter(|d| !d.settled()).count()
    }

    /// Keep the original team destination independently of the hub's resolved receipt shape.
    /// Terminal records survive restart but are never submitted as prompts by `resume`.
    pub(crate) fn record_team_receipt(
        &self,
        id: &str,
        address: &str,
        caller: Option<&str>,
    ) -> bool {
        let key = format!("mesh:{id}");
        let mut book = self.book();
        let now = crate::store::now_ms();
        book.deliveries.entry(key.clone()).or_insert_with(|| Delivery {
            id: key.clone(),
            target: address.to_owned(),
            request: json!({"teamOrigin": true, "_meta": {"acpmux": {"promptId": key}}}),
            caller: caller.map(str::to_owned),
            unproven_caller: None,
            not_terminal: false,
            state: State::Delivered,
            attempts: 0,
            never_sent: false,
            relay_post: None,
            error: None,
            accepted: None,
            created_at: now,
            updated_at: now,
        });
        book.dirty.insert(key);
        let change = book.changed();
        drop(book);
        self.save(change);
        let in_memory = self.path.lock().unwrap_or_else(|e| e.into_inner()).is_none();
        in_memory || self.disk.lock().unwrap_or_else(|e| e.into_inner()).saved >= change
    }

    pub(crate) fn team_receipt(&self, id: &str) -> Option<Delivery> {
        self.book().deliveries.get(&format!("mesh:{id}")).filter(|d| d.is_team_receipt()).cloned()
    }

    /// The messages this daemon was handed to deliver, at most `limit`, and how many of all of
    /// them still wait: every one, or only those `caller` (a session id) sent. The waiting ones
    /// come first (none is cut while a settled one is shown), then the rest, newest first.
    /// Projection intents and team receipts are bookkeeping, not messages, and are left out.
    pub fn list(&self, caller: Option<&str>, limit: usize) -> (Vec<Delivery>, usize) {
        let book = self.book();
        let mut out: Vec<Delivery> = book
            .deliveries
            .values()
            .filter(|d| !d.is_team_receipt() && !d.projection_only())
            .filter(|d| caller.is_none_or(|c| d.caller.as_deref() == Some(c)))
            .cloned()
            .collect();
        let waiting = out.iter().filter(|d| !d.settled()).count();
        out.sort_by(|a, b| {
            a.settled()
                .cmp(&b.settled())
                .then_with(|| b.created_at.cmp(&a.created_at))
                .then_with(|| b.id.cmp(&a.id))
        });
        out.truncate(limit);
        (out, waiting)
    }

    pub fn get(&self, id: &str) -> Option<Delivery> {
        // Receipt metadata is readable only through the team-authorized mesh status path.
        // In particular, disabling the relay must not expose it as an ordinary delivery.
        self.book().deliveries.get(id).filter(|d| !d.is_team_receipt()).cloned()
    }

    /// Changes delivery `id` with `f` and saves.
    pub fn update(&self, id: &str, f: impl FnOnce(&mut Delivery)) {
        let mut book = self.book();
        let Some(d) = book.deliveries.get_mut(id) else { return };
        f(d);
        d.updated_at = crate::store::now_ms();
        book.dirty.insert(id.to_owned());
        let change = book.changed();
        drop(book);
        self.save(change);
        self.changed.notify_waiters();
    }

    /// Returns once a file that holds change `change` is on disk, or after logging a failed
    /// write (then nothing is marked saved, so the next change writes everything again). A write
    /// that started after the change covers it, so changes made while one write runs share the
    /// next.
    fn save(&self, change: u64) {
        if let Err(e) = self.save_checked(change) {
            tracing::warn!("outbox: could not save: {e:#}");
        }
    }

    fn save_checked(&self, change: u64) -> anyhow::Result<()> {
        self.save_or_take_out(change, None)
    }

    /// [`Self::save_checked`], and when the write fails, delivery `added` is taken out of the
    /// book before the next write can start: no later write puts on disk what its sender was
    /// told is not kept. Every add that shared the failed write fails too, as `saved` did not
    /// advance; each tries the write again itself.
    fn save_or_take_out(&self, change: u64, added: Option<&str>) -> anyhow::Result<()> {
        let Some(path) = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return Ok(());
        };
        let mut disk = self.disk.lock().unwrap_or_else(|e| e.into_inner());
        if disk.saved >= change {
            return Ok(());
        }
        let snapshot = disk.snapshot_next
            || (disk.journal >= COMPACT_FLOOR.max(2 * disk.snapshot)
                && disk.journal >= disk.snapshot_retry_at);
        // The changed deliveries' lines and, for a snapshot, every delivery, as of one change.
        let (lines, whole, dirty, newest) = {
            let mut book = self.book();
            let dirty = std::mem::take(&mut book.dirty);
            let encoded = (|| -> serde_json::Result<_> {
                // A torn line an append left behind ends before these.
                let mut lines = if disk.torn { b"\n".to_vec() } else { Vec::new() };
                for d in dirty.iter().filter_map(|id| book.deliveries.get(id)) {
                    serde_json::to_writer(&mut lines, &*on_disk(d))?;
                    lines.push(b'\n');
                }
                let whole = if snapshot {
                    let all: BTreeMap<&String, std::borrow::Cow<Delivery>> =
                        book.deliveries.iter().map(|(id, d)| (id, on_disk(d))).collect();
                    Some(serde_json::to_vec(&all)?)
                } else {
                    None
                };
                Ok((lines, whole))
            })();
            match encoded {
                Ok((lines, whole)) => (lines, whole, dirty, book.changes),
                Err(e) => {
                    book.dirty.extend(dirty);
                    return Err(e.into());
                }
            }
        };
        // The journal gets these lines before any snapshot: a snapshot that fails leaves them
        // readable after the snapshot they follow.
        let written = (|| -> anyhow::Result<()> {
            let journal = journal_path(&path);
            if lines.iter().any(|b| *b != b'\n') {
                if disk.journal_open {
                    use std::io::Write;
                    let appended = crate::store::open_private_append(&journal).and_then(|mut f| {
                        let start = f.metadata()?.len();
                        let written = f.write_all(&lines).and_then(|()| f.sync_data());
                        if written.is_err() {
                            // A failed change is not kept (an add is taken out): its whole line
                            // must not stay to be read after a restart. An append-only handle
                            // cannot truncate on Windows, so through its own write handle. Should
                            // that fail too, the next write is a snapshot (`snapshot_next`),
                            // which resets the journal.
                            let _ = crate::home_fs::OpenOptions::new()
                                .write(true)
                                .open(&journal)
                                .and_then(|w| w.set_len(start).and_then(|()| w.sync_data()));
                        }
                        Ok(written?)
                    });
                    if let Err(e) = appended {
                        disk.snapshot_next = true;
                        disk.torn = true;
                        return Err(e);
                    }
                    disk.torn = false;
                } else {
                    // A new journal: written whole and renamed in, its folder synced, so a power
                    // loss never drops the file a change was answered from.
                    let fresh = [disk.header.as_slice(), &lines].concat();
                    crate::config::write_atomic(&journal, &fresh)?;
                    disk.torn = false;
                    disk.written += disk.header.len() as u64;
                    disk.journal = 0;
                    disk.journal_open = true;
                }
                disk.journal += lines.len() as u64;
                disk.written += lines.len() as u64;
            }
            if let Some(whole) = whole {
                // Once this change's lines are synced it is on disk: a snapshot that fails then
                // only waits for a later try, after another snapshot's worth of journal.
                if let Err(e) = crate::config::write_atomic(&path, &whole) {
                    if !disk.journal_open {
                        return Err(e);
                    }
                    tracing::warn!(
                        "outbox: a snapshot could not be written, kept the journal: {e:#}"
                    );
                    disk.snapshot_retry_at = disk.journal + COMPACT_FLOOR.max(disk.snapshot);
                    disk.snapshot_next = false;
                    return Ok(());
                }
                disk.snapshot_retry_at = 0;
                disk.snapshot = whole.len() as u64;
                disk.header = header_for(&whole);
                disk.written += whole.len() as u64;
                disk.snapshot_next = false;
                disk.journal = 0;
                // The new snapshot holds everything; the journal beside it now names the old one
                // and is not read. Starting the new one now is only an early start: when it
                // fails, the next change writes it.
                disk.journal_open = false;
                match crate::config::write_atomic(&journal, &disk.header) {
                    Ok(()) => {
                        disk.journal_open = true;
                        disk.torn = false;
                        disk.written += disk.header.len() as u64;
                    }
                    Err(e) => tracing::warn!("outbox: a new journal could not be started: {e:#}"),
                }
            }
            Ok(())
        })();
        // Failed writes never advance saved. A retry of the same in-memory intent
        // must try the write again before it can report success.
        if let Err(e) = written {
            let mut book = self.book();
            book.dirty.extend(dirty);
            if let Some(id) = added {
                book.deliveries.remove(id);
            }
            return Err(e);
        }
        disk.saved = newest;
        Ok(())
    }
}

/// Delivery `d` as it is written: attachment bytes are kept once beside the file
/// (`keep_attachments`), never in it.
fn on_disk(d: &Delivery) -> std::borrow::Cow<'_, Delivery> {
    let blocks = d.request.get("prompt").and_then(Value::as_array);
    if !blocks.is_some_and(|b| crate::attach::any(b)) {
        return std::borrow::Cow::Borrowed(d);
    }
    let mut d = d.clone();
    crate::attach::strip(&mut d.request);
    std::borrow::Cow::Owned(d)
}

/// The journal beside `outbox.json` (at `path`).
pub(crate) fn journal_path(path: &Path) -> PathBuf {
    path.with_extension("journal")
}

/// The journal's first line for a snapshot of `bytes`.
fn header_for(bytes: &[u8]) -> Vec<u8> {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(bytes);
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let mut line =
        serde_json::to_vec(&json!({"outboxSnapshot": {"bytes": bytes.len(), "sha256": hex}}))
            .unwrap_or_default();
    line.push(b'\n');
    line
}

/// What the files at `path` hold.
struct Saved {
    deliveries: BTreeMap<String, Delivery>,
    snapshot_bytes: u64,
    header: Vec<u8>,
    /// Bytes of journal lines read over the snapshot.
    journal_bytes: u64,
    /// The journal on disk follows this snapshot.
    journal_open: bool,
    /// Its last line has no newline (a torn append).
    torn: bool,
}

/// The snapshot at `path`, then each line of the journal that follows it. A snapshot that cannot
/// be read starts empty (and is replaced); a journal that names another snapshot is not read; a
/// journal line that cannot be read (a torn append) is skipped.
fn read_saved(path: &Path) -> Saved {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => {
            // Set aside: a journal started against "no snapshot" must never sit beside it, or a
            // later read that works would ignore that journal's accepted changes.
            let aside = path.with_extension("json.unreadable");
            let moved = crate::home_fs::rename(path, &aside);
            tracing::error!(
                "outbox: {} cannot be read ({e}); starting empty, set aside at {} ({moved:?})",
                path.display(),
                aside.display()
            );
            Vec::new()
        }
    };
    let mut deliveries: BTreeMap<String, Delivery> = if bytes.is_empty() {
        BTreeMap::new()
    } else {
        serde_json::from_slice(&bytes).unwrap_or_else(|e| {
            tracing::warn!("outbox: {} cannot be read, starting empty: {e}", path.display());
            BTreeMap::new()
        })
    };
    let header = header_for(&bytes);
    let journal = match std::fs::read(journal_path(path)) {
        Ok(journal) => journal,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => {
            // Set aside, never replaced by the next change's new journal: its lines may hold
            // changes that were answered as saved.
            let aside = journal_path(path).with_extension("journal.unreadable");
            let moved = crate::home_fs::rename(journal_path(path), &aside);
            tracing::error!(
                "outbox: the journal cannot be read ({e}); reading the snapshot alone, journal \
                 set aside at {} ({moved:?})",
                aside.display()
            );
            Vec::new()
        }
    };
    let (journal_open, lines) = match journal.strip_prefix(header.as_slice()) {
        Some(lines) => (true, lines),
        None => {
            if !journal.is_empty() {
                tracing::warn!("outbox: the journal follows another snapshot, not read");
            }
            (false, &[][..])
        }
    };
    for line in lines.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
        match serde_json::from_slice::<Delivery>(line) {
            Ok(d) => {
                deliveries.insert(d.id.clone(), d);
            }
            Err(e) => tracing::warn!("outbox: a journal line cannot be read, skipped: {e}"),
        }
    }
    Saved {
        deliveries,
        snapshot_bytes: bytes.len() as u64,
        header,
        journal_bytes: lines.len() as u64,
        journal_open,
        torn: !lines.is_empty() && !lines.ends_with(b"\n"),
    }
}

impl Book {
    /// Counts a change and drops what settled long ago; returns the change's number.
    fn changed(&mut self) -> u64 {
        let now = crate::store::now_ms();
        self.deliveries.retain(|_, d| {
            // Team bodies/receipts live at the hub for seven days; retain their origin
            // for that entire lifetime, including owner sends with no caller session.
            let keep = if d.is_team_receipt() { 7 * KEEP_SETTLED_MS } else { KEEP_SETTLED_MS };
            !d.settled() || now.saturating_sub(d.updated_at) < keep
        });
        self.changes += 1;
        self.changes
    }
}

/// The folder beside `outbox.json` (at `path`) that keeps waiting deliveries' attachments.
fn attachments_dir(path: &Path) -> PathBuf {
    path.with_file_name("outbox-attachments")
}

/// Keeps `request` (with its attachment bytes) at `path`, owner-only. Blocking.
pub fn keep_attachments(path: &Path, request: &Value) -> anyhow::Result<()> {
    crate::agent_tools::write_private(path, &serde_json::to_vec(request)?)
}

type AcceptHook = Box<dyn FnOnce(Value) + Send>;
type ProvisionalHook = std::sync::Arc<dyn Fn(Value) + Send + Sync>;

/// Prompts forwarded to a peer that wait for the peer's acceptance, by peer, target session and prompt id. Two
/// forwards of one id (a retry while the first still waits) each get theirs.
#[derive(Default)]
pub struct PeerAccepts {
    hooks: StdMutex<HashMap<(String, String, String), Vec<(u64, AcceptHook, ProvisionalHook)>>>,
    next: std::sync::atomic::AtomicU64,
}

impl PeerAccepts {
    /// Calls `hook` with peer `peer`'s `_acpmux/prompt_accepted` for `prompt_id`, once. Returns
    /// the wait's token for [`Self::forget`].
    pub fn wait(
        &self,
        peer: &str,
        session_id: &str,
        prompt_id: &str,
        hook: AcceptHook,
        provisional: ProvisionalHook,
    ) -> u64 {
        let token = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let key = (peer.to_owned(), session_id.to_owned(), prompt_id.to_owned());
        self.hooks.lock().unwrap_or_else(|e| e.into_inner()).entry(key).or_default().push((
            token,
            hook,
            provisional,
        ));
        token
    }

    /// The forwarded prompt answered: this wait no longer listens.
    pub fn forget(&self, peer: &str, session_id: &str, prompt_id: &str, token: u64) {
        let mut hooks = self.hooks.lock().unwrap_or_else(|e| e.into_inner());
        let key = (peer.to_owned(), session_id.to_owned(), prompt_id.to_owned());
        if let Some(waits) = hooks.get_mut(&key) {
            waits.retain(|(t, _, _)| *t != token);
            if waits.is_empty() {
                hooks.remove(&key);
            }
        }
    }

    /// Peer `peer`'s `_acpmux/prompt_accepted` arrived: every forward of that id to it hears it.
    pub fn accepted(&self, peer: &str, params: &Value) {
        let Some(session_id) = params.get("sessionId").and_then(Value::as_str) else { return };
        let Some(prompt_id) = params.get("promptId").and_then(Value::as_str) else { return };
        let key = (peer.to_owned(), session_id.to_owned(), prompt_id.to_owned());
        // Preserve a retry's early acknowledgement, including a retry registered
        // after the real acceptance. A provisional notice cannot persist or settle
        // a projection: the original may still be refused. Keep final hooks intact.
        if params.get("duplicate") == Some(&Value::Bool(true))
            && params.get("turnId").is_none_or(Value::is_null)
        {
            let callbacks: Vec<_> = self
                .hooks
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&key)
                .into_iter()
                .flatten()
                .map(|(_, _, hook)| hook.clone())
                .collect();
            for callback in callbacks {
                callback(params.clone());
            }
            return;
        }
        let waits = self.hooks.lock().unwrap_or_else(|e| e.into_inner()).remove(&key);
        for (_, hook, _) in waits.into_iter().flatten() {
            hook(params.clone());
        }
    }
}

/// The refusal for a `send_queue` from a connection that is not the unix socket.
pub fn local_only() -> RpcError {
    RpcError::invalid_params("only the unix socket queues a message for delivery")
        .with_data(json!({"reason": "outbox.local_only"}))
}

/// The message id a forward intent records (`server/outbox.rs` `remember_forward`): a direct
/// send and its `send_queue` retry share a prompt id but are two messages, each its own intent.
fn projected_message(d: &Delivery) -> Option<&Value> {
    d.request.pointer("/_meta/acpmux/forwardProjection/messageId")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn delivery(n: usize) -> Delivery {
        let now = crate::store::now_ms();
        Delivery {
            id: format!("d-{n}"),
            target: "lane".into(),
            request: json!({"sessionId": "lane", "_meta": {"acpmux": {"promptId": format!("p-{n}")}}}),
            caller: None,
            unproven_caller: None,
            not_terminal: false,
            state: State::Queued,
            attempts: 0,
            never_sent: false,
            relay_post: None,
            error: None,
            accepted: None,
            created_at: now,
            updated_at: now,
        }
    }

    #[test]
    fn list_is_newest_first_by_sender_without_bookkeeping() {
        let outbox = Outbox::default();
        for n in 0..4 {
            let mut d = delivery(n);
            d.created_at = n as u64;
            d.caller = Some(if n % 2 == 0 { "s-even" } else { "s-odd" }.into());
            outbox.add(d).unwrap();
        }
        let mut intent = delivery(9);
        intent.request["_meta"]["acpmux"]["forwardProjection"] = json!({"text": "x"});
        intent.state = State::Held;
        outbox.add(intent).unwrap();
        let ids = |(v, _): (Vec<Delivery>, usize)| v.into_iter().map(|d| d.id).collect::<Vec<_>>();
        assert_eq!(ids(outbox.list(None, 10)), ["d-3", "d-2", "d-1", "d-0"]);
        assert_eq!(ids(outbox.list(Some("s-even"), 10)), ["d-2", "d-0"]);
        assert_eq!(ids(outbox.list(None, 1)), ["d-3"]);
        // A waiting one is never cut for a newer settled one, and the count is of all of them.
        for n in 1..4 {
            outbox.update(&format!("d-{n}"), |d| d.state = State::Delivered);
        }
        assert_eq!(outbox.list(None, 1).1, 1);
        assert_eq!(ids(outbox.list(None, 1)), ["d-0"]);
    }

    #[test]
    fn forward_intents_do_not_alias_other_senders_targets_or_queued_deliveries() {
        let outbox = Outbox::default();
        outbox.add(delivery(1)).unwrap();
        let mut intent = delivery(1);
        intent.id = "intent-1".into();
        intent.caller = Some("sender".into());
        intent.request["_meta"]["acpmux"]["forwardProjection"] = json!({"text": "hello"});
        assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-1");
        intent.id = "unused-retry-id".into();
        assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-1");
        intent.target = "another-target".into();
        intent.id = "intent-2".into();
        assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-2");
        intent.caller = Some("another-sender".into());
        intent.id = "intent-3".into();
        assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-3");
        // A `send_queue` retry of the same prompt id is another message: its own intent, so a
        // restart reads the receiver's journal for the retry's delivery id too.
        intent.request["_meta"]["acpmux"]["forwardProjection"]["messageId"] = json!("delivery-1");
        intent.id = "intent-4".into();
        assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-4");
        intent.id = "unused-retry-id".into();
        assert_eq!(outbox.remember_forward(intent).unwrap().id, "intent-4");
        assert_eq!(outbox.add(delivery(1)).unwrap().id, "d-1");
    }

    /// A queued send's prompt id is a key for one message to one target, as the target's own
    /// prompt ledger keys it (`Hub::prompt_with`): the same prompt id to another target is a
    /// message of its own and is delivered too. Before, `add` answered it with the first
    /// message's delivery (`delivered`, to the first target), and the second never went.
    #[test]
    fn a_queued_send_with_a_reused_prompt_id_to_another_target_is_its_own() {
        let outbox = Outbox::default();
        let first = delivery(1);
        assert_eq!(outbox.add(first.clone()).unwrap().id, "d-1");
        // The same message again (a CLI retry): the first delivery.
        let mut again = first.clone();
        again.id = "retry".into();
        assert_eq!(outbox.add(again).unwrap().id, "d-1");
        // The same prompt id to another target: its own delivery.
        let mut other = first.clone();
        other.id = "d-2".into();
        other.target = "other".into();
        other.request["sessionId"] = json!("other");
        assert_eq!(outbox.add(other.clone()).unwrap().id, "d-2");
        other.id = "retry-2".into();
        assert_eq!(outbox.add(other).unwrap().id, "d-2");
        assert_eq!(outbox.unsettled(), 2);
    }

    #[test]
    fn provisional_duplicate_does_not_consume_acceptance_hooks() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let accepts = PeerAccepts::default();
        let seen = std::sync::Arc::new(AtomicUsize::new(0));
        let provisional = std::sync::Arc::new(AtomicUsize::new(0));
        for _ in 0..2 {
            let provisional = provisional.clone();
            let seen = seen.clone();
            accepts.wait(
                "peer",
                "target",
                "p1",
                Box::new(move |_| {
                    seen.fetch_add(1, Ordering::SeqCst);
                }),
                std::sync::Arc::new(move |_| {
                    provisional.fetch_add(1, Ordering::SeqCst);
                }),
            );
        }
        accepts.accepted(
            "peer",
            &json!({"sessionId": "target", "promptId": "p1", "duplicate": true, "turnId": null}),
        );
        assert_eq!(seen.load(Ordering::SeqCst), 0);
        assert_eq!(provisional.load(Ordering::SeqCst), 2);
        accepts.accepted("peer", &json!({"sessionId": "target", "promptId": "p1", "turnId": "t1"}));
        assert_eq!(seen.load(Ordering::SeqCst), 2);

        // A retry registered after the original acknowledgement still hears its
        // provisional acknowledgement while the original turn remains busy.
        let seen_late = seen.clone();
        let provisional_late = provisional.clone();
        let token = accepts.wait(
            "peer",
            "target",
            "p1",
            Box::new(move |_| {
                seen_late.fetch_add(1, Ordering::SeqCst);
            }),
            std::sync::Arc::new(move |_| {
                provisional_late.fetch_add(1, Ordering::SeqCst);
            }),
        );
        accepts.accepted(
            "peer",
            &json!({"sessionId": "target", "promptId": "p1", "duplicate": true, "turnId": null}),
        );
        assert_eq!(provisional.load(Ordering::SeqCst), 3);
        assert_eq!(seen.load(Ordering::SeqCst), 2);
        accepts.forget("peer", "target", "p1", token);
        assert!(accepts.hooks.lock().unwrap().is_empty());
    }

    #[test]
    fn peer_acceptance_is_scoped_to_its_target_session() {
        let accepts = PeerAccepts::default();
        let seen = std::sync::Arc::new(StdMutex::new(Vec::new()));
        for target in ["a", "b"] {
            let seen = seen.clone();
            accepts.wait(
                "peer",
                target,
                "same-prompt",
                Box::new(move |_| {
                    seen.lock().unwrap().push(target);
                }),
                std::sync::Arc::new(|_| {}),
            );
        }
        accepts.accepted(
            "peer",
            &json!({"sessionId": "a", "promptId": "same-prompt", "turnId": "t-a"}),
        );
        assert_eq!(*seen.lock().unwrap(), vec!["a"]);
        // An unrelated peer also cannot consume the second target's hook.
        accepts.accepted(
            "other-peer",
            &json!({"sessionId": "b", "promptId": "same-prompt", "turnId": "t-b"}),
        );
        assert_eq!(*seen.lock().unwrap(), vec!["a"]);
        accepts.accepted(
            "peer",
            &json!({"sessionId": "b", "promptId": "same-prompt", "turnId": "t-b"}),
        );
        assert_eq!(*seen.lock().unwrap(), vec!["a", "b"]);
    }

    /// Sends from many tasks at once share writes, and the file still holds every one of them
    /// when each `add` returns: a restart delivers all of them.
    #[test]
    fn concurrent_adds_are_all_on_disk_when_they_return() {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("outbox.json");
        let outbox = std::sync::Arc::new(Outbox::default());
        assert!(outbox.open(&path).is_empty());
        let threads: Vec<_> = (0..64)
            .map(|n| {
                let outbox = outbox.clone();
                let path = path.clone();
                std::thread::spawn(move || {
                    outbox.add(delivery(n)).unwrap();
                    // What a restart would read right now holds this one.
                    let saved = read_saved(&path).deliveries;
                    assert!(saved.contains_key(&format!("d-{n}")), "d-{n} not on disk");
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        outbox.update("d-3", |d| d.state = State::Delivered);
        let restarted = Outbox::default();
        let pending = restarted.open(&path);
        assert_eq!(pending.len(), 63);
        assert_eq!(restarted.get("d-3").map(|d| d.state), Some(State::Delivered));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An add whose write fails is not kept: the sender is told so, and neither this daemon nor
    /// a restart delivers it. Nor does a later write that succeeds bring it back.
    #[test]
    fn an_add_whose_write_fails_is_not_kept() {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        // A regular file where the folder should be fails the write, also for root.
        let blocked = dir.join("blocked");
        std::fs::write(&blocked, b"block").unwrap();
        let path = blocked.join("outbox.json");
        let outbox = std::sync::Arc::new(Outbox::default());
        outbox.open(&path);
        assert!(outbox.add(delivery(1)).is_err());
        assert!(outbox.get("d-1").is_none(), "a delivery not on disk is still in memory");
        // Adds that share one failed write all fail, the same prompt id again among them.
        let held = outbox.disk.lock().unwrap();
        let adds: Vec<_> = [2, 3, 2]
            .into_iter()
            .enumerate()
            .map(|(n, d)| {
                let outbox = outbox.clone();
                let mut d = delivery(d);
                d.id = format!("d-{n}-again");
                std::thread::spawn(move || outbox.add(d).is_err())
            })
            .collect();
        std::thread::sleep(std::time::Duration::from_millis(50));
        drop(held);
        for add in adds {
            assert!(add.join().unwrap(), "an add that shared a failed write answered as kept");
        }
        assert_eq!(outbox.list(None, 10).0.len(), 0, "a delivery not on disk is still in memory");
        std::fs::remove_file(&blocked).unwrap();
        std::fs::create_dir(&blocked).unwrap();
        outbox.add(delivery(4)).unwrap();
        let restarted = Outbox::default();
        let pending: Vec<_> = restarted.open(&path).into_iter().map(|d| d.id).collect();
        assert_eq!(pending, ["d-4"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A retry of a prompt whose first add is still writing answers only once the file holds it.
    #[test]
    fn a_duplicate_add_returns_once_the_first_is_on_disk() {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("outbox.json");
        let outbox = std::sync::Arc::new(Outbox::default());
        outbox.open(&path);
        // Hold the write lock as a slow write would, then add: the delivery is in memory only.
        let held = outbox.disk.lock().unwrap();
        let first = {
            let outbox = outbox.clone();
            std::thread::spawn(move || outbox.add(delivery(1)).unwrap())
        };
        while outbox.get("d-1").is_none() {
            std::thread::yield_now();
        }
        let retry = {
            let outbox = outbox.clone();
            let path = path.clone();
            std::thread::spawn(move || {
                let again = outbox.add(delivery(1)).unwrap();
                (again.id, read_saved(&path).deliveries.contains_key("d-1"))
            })
        };
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(!retry.is_finished(), "the retry answered before the first add was on disk");
        drop(held);
        first.join().unwrap();
        assert_eq!(retry.join().unwrap(), ("d-1".to_owned(), true));
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn temp_outbox() -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("outbox.json");
        (dir, path)
    }

    /// A delivery the size of an average one in a day's real outbox (5.2 MB for 2,512).
    fn sized(n: usize, state: State) -> Delivery {
        let mut d = delivery(n);
        d.request["prompt"] = json!([{"type": "text", "text": "x".repeat(1800)}]);
        d.state = state;
        d
    }

    /// The bytes each of 2,000 changes writes (a send's life, four changes each) with `kept`
    /// delivered deliveries already in the outbox, for each size in `sizes`, after checking every
    /// one reads back after a restart and that each change writes under a tenth of what the
    /// whole-file rewrite did (the snapshot's size; `kept` 10 aside, whose snapshot is tiny).
    fn bytes_per_change(sizes: [usize; 2]) -> [u64; 2] {
        sizes.map(|kept| {
            let (dir, path) = temp_outbox();
            let all: BTreeMap<String, Delivery> =
                (0..kept).map(|n| sized(n, State::Delivered)).map(|d| (d.id.clone(), d)).collect();
            let before = serde_json::to_vec(&all).unwrap().len() as u64;
            std::fs::write(&path, serde_json::to_vec(&all).unwrap()).unwrap();
            let outbox = Outbox::default();
            outbox.open(&path);
            let start = outbox.disk.lock().unwrap().written;
            let changes = 2_000;
            for n in 0..changes / 4 {
                // A send's life: queued, delivering, attempted again, delivered.
                let id = format!("d-{}", kept + n);
                outbox.add(sized(kept + n, State::Queued)).unwrap();
                outbox.update(&id, |d| d.state = State::Delivering);
                outbox.update(&id, |d| d.attempts += 1);
                outbox.update(&id, |d| d.state = State::Delivered);
            }
            let after = (outbox.disk.lock().unwrap().written - start) / changes as u64;
            eprintln!("kept {kept}: before {before} B per change, after {after} B per change");
            // Everything comes back after a restart, from the snapshot and the journal.
            let restarted = Outbox::default();
            assert!(restarted.open(&path).is_empty());
            assert_eq!(restarted.list(None, usize::MAX).0.len(), kept + changes / 4);
            assert_eq!(restarted.get(&format!("d-{kept}")).unwrap().attempts, 1);
            assert!(before > 10 * after || kept == 10);
            let _ = std::fs::remove_dir_all(&dir);
            after
        })
    }

    /// cmuxterm-hq#8660 (hang-watch `6159015094`): the bytes a change writes do not grow with
    /// the deliveries kept. Small is 10 kept, large 2,500 (a day of a busy machine, 5 MB);
    /// "before" is what the whole-file rewrite wrote for each change, the snapshot's size. A
    /// count of bytes, so it holds at any size: a change that rewrote the file, or compacted it
    /// more often as it grew, writes more at 2,500 as it would at 25,000. The full ten days,
    /// `a_change_writes_the_same_bytes_with_25000_deliveries_kept`, runs on its own.
    #[test]
    fn a_change_writes_the_same_bytes_with_ten_or_2500_deliveries_kept() {
        let [small, large] = bytes_per_change([10, 2_500]);
        assert!(
            large * 10 <= small * 12,
            "large {large} B per change is over 1.2x small {small} B"
        );
    }

    /// The same at 25,000 kept (ten days of a busy machine, 52 MB), the size hang-watch saw. A
    /// debug build took 86 s alone on an idle 8-core CI runner and ran past nextest's 120 s hang
    /// guard beside other work (3 of 3 loaded lib runs), so it is a check for its own run:
    /// `cargo test -p acpmux --lib hub::outbox::tests::a_change_writes_the_same_bytes_with_25000_deliveries_kept -- --ignored --exact --test-threads=1 --nocapture`.
    /// The default run keeps `a_change_writes_the_same_bytes_with_ten_or_2500_deliveries_kept`.
    #[test]
    #[ignore = "own run, one test at a time: 52 MB through a debug build, past the hang guard under load"]
    fn a_change_writes_the_same_bytes_with_25000_deliveries_kept() {
        let [small, large] = bytes_per_change([10, 25_000]);
        assert!(
            large * 10 <= small * 12,
            "large {large} B per change is over 1.2x small {small} B"
        );
    }

    /// A torn last line (a crash or a full disk mid-append) costs only that line; the rest of the
    /// journal is read, and the open folds it into a fresh snapshot.
    #[test]
    fn a_torn_journal_line_is_skipped_and_the_open_compacts() {
        let (dir, path) = temp_outbox();
        let outbox = Outbox::default();
        outbox.open(&path);
        for n in 0..3 {
            outbox.add(delivery(n)).unwrap();
        }
        outbox.update("d-1", |d| d.state = State::Delivered);
        let journal = journal_path(&path);
        let mut torn = std::fs::read(&journal).unwrap();
        assert!(!torn.is_empty(), "small changes go to the journal");
        torn.extend_from_slice(br#"{"id":"d-9","tar"#);
        std::fs::write(&journal, torn).unwrap();
        let restarted = Outbox::default();
        let pending = restarted.open(&path);
        assert_eq!(pending.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(), ["d-0", "d-2"]);
        assert_eq!(restarted.get("d-1").unwrap().state, State::Delivered);
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(std::fs::read(&journal).unwrap(), header_for(&bytes), "the open compacts");
        let snapshot: BTreeMap<String, Delivery> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(snapshot.len(), 3, "the snapshot alone holds everything for an older daemon");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A torn tail stays fenced off when the snapshot meant to replace it fails (a full disk):
    /// the next change's line starts after a newline and is read after a restart.
    #[test]
    fn a_torn_tail_and_a_failed_snapshot_lose_no_later_change() {
        let (dir, path) = temp_outbox();
        let outbox = Outbox::default();
        outbox.open(&path);
        outbox.add(delivery(0)).unwrap();
        let journal = journal_path(&path);
        let mut torn = std::fs::read(&journal).unwrap();
        torn.extend_from_slice(br#"{"id":"d-9","tar"#);
        std::fs::write(&journal, torn).unwrap();
        {
            let mut disk = outbox.disk.lock().unwrap();
            disk.torn = true;
            disk.snapshot_next = true;
        }
        // The snapshot fails: a folder that is not empty is in its place.
        std::fs::create_dir_all(path.join("occupied")).unwrap();
        outbox.compact();
        assert!(outbox.disk.lock().unwrap().torn, "the fence outlives a failed snapshot");
        outbox.add(delivery(1)).unwrap();
        std::fs::remove_dir_all(&path).unwrap();
        let restarted = Outbox::default();
        let ids: Vec<String> = restarted.open(&path).into_iter().map(|d| d.id).collect();
        assert_eq!(ids, ["d-0", "d-1"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A snapshot that cannot be read at open is set aside, so a journal started against no
    /// snapshot never sits beside it to be ignored once it reads again.
    #[test]
    fn an_unreadable_snapshot_is_set_aside() {
        let (dir, path) = temp_outbox();
        std::fs::create_dir_all(path.join("unreadable")).unwrap();
        let outbox = Outbox::default();
        outbox.open(&path);
        outbox.add(delivery(0)).unwrap();
        assert!(path.with_extension("json.unreadable").exists());
        let restarted = Outbox::default();
        assert_eq!(restarted.open(&path).len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A change's lines reach the journal before any snapshot of it: a snapshot that fails (or
    /// a crash before the journal is cut) still finds the change in the journal, and since the
    /// journal's last line for each id is the snapshot's own state, a replay over a newer
    /// snapshot is never older.
    #[test]
    fn a_change_is_journaled_before_its_snapshot() {
        let (dir, path) = temp_outbox();
        let outbox = Outbox::default();
        outbox.open(&path);
        outbox.add(delivery(0)).unwrap();
        // The snapshot's rename fails: a folder that is not empty is in its place.
        std::fs::create_dir_all(path.join("occupied")).unwrap();
        outbox.disk.lock().unwrap().snapshot_next = true;
        outbox.update("d-0", |d| d.state = State::Delivered);
        // The change is on disk in the journal, so it is saved; the snapshot waits for a later
        // try, not the next change.
        assert_eq!(outbox.disk.lock().unwrap().saved, outbox.book().changes);
        assert!(!outbox.disk.lock().unwrap().snapshot_next);
        let tries = outbox.disk.lock().unwrap().snapshot_retry_at;
        assert!(tries >= COMPACT_FLOOR);
        let journal = String::from_utf8(std::fs::read(journal_path(&path)).unwrap()).unwrap();
        let last: Delivery = serde_json::from_str(journal.lines().last().unwrap()).unwrap();
        assert_eq!(last.state, State::Delivered);
        std::fs::remove_dir_all(&path).unwrap();
        let restarted = Outbox::default();
        assert!(restarted.open(&path).is_empty());
        assert_eq!(restarted.get("d-0").unwrap().state, State::Delivered);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An older daemon reads and rewrites `outbox.json` alone. The journal it left behind names
    /// the snapshot before that, so a newer daemon started after it never replays it over the
    /// older daemon's newer states: nothing goes back to waiting and is sent again.
    #[test]
    fn a_journal_beside_another_snapshot_is_not_read() {
        let (dir, path) = temp_outbox();
        let outbox = Outbox::default();
        outbox.open(&path);
        outbox.add(delivery(0)).unwrap();
        outbox.update("d-0", |d| d.state = State::Delivering);
        assert!(!read_saved(&path).deliveries["d-0"].settled());
        // The older daemon: delivers it and rewrites the snapshot, leaving the journal.
        let mut older = read_saved(&path).deliveries;
        older.get_mut("d-0").unwrap().state = State::Delivered;
        std::fs::write(&path, serde_json::to_vec(&older).unwrap()).unwrap();
        let restarted = Outbox::default();
        assert!(restarted.open(&path).is_empty(), "nothing resumes to be sent again");
        assert_eq!(restarted.get("d-0").unwrap().state, State::Delivered);
        // And a change after it starts a journal for this snapshot.
        restarted.add(delivery(1)).unwrap();
        let again = Outbox::default();
        assert_eq!(again.open(&path).len(), 1);
        assert_eq!(again.get("d-0").unwrap().state, State::Delivered);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// At shutdown the journal is folded in: `outbox.json` alone then holds every change, for
    /// whichever daemon starts next.
    #[test]
    fn compact_leaves_the_snapshot_holding_everything() {
        let (dir, path) = temp_outbox();
        let outbox = Outbox::default();
        outbox.open(&path);
        outbox.add(delivery(0)).unwrap();
        outbox.update("d-0", |d| d.state = State::Delivered);
        outbox.add(delivery(1)).unwrap();
        outbox.compact();
        let bytes = std::fs::read(&path).unwrap();
        let snapshot: BTreeMap<String, Delivery> = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(snapshot["d-0"].state, State::Delivered);
        assert!(snapshot.contains_key("d-1"));
        assert_eq!(std::fs::read(journal_path(&path)).unwrap(), header_for(&bytes));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A waiting delivery's attachments are kept once beside `outbox.json`, which never holds
    /// their bytes; a restart reads them back, and ones nothing names go.
    #[test]
    fn attachments_are_kept_beside_the_file_and_come_back_after_a_restart() {
        let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("outbox.json");
        let block = crate::attach::block("shot.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR");
        let data = block["data"].as_str().unwrap().to_owned();
        let request = json!({"sessionId": "lane", "prompt": [block],
                             "_meta": {"acpmux": {"promptId": "p1"}}});
        let d = Delivery {
            id: "d1".into(),
            target: "lane".into(),
            request,
            caller: None,
            unproven_caller: None,
            not_terminal: false,
            state: State::Queued,
            attempts: 0,
            never_sent: false,
            relay_post: None,
            error: None,
            accepted: None,
            created_at: 0,
            updated_at: crate::store::now_ms(),
        };
        let outbox = Outbox::default();
        outbox.open(&path);
        let kept = outbox.attachments_path(&d).unwrap();
        keep_attachments(&kept, &d.request).unwrap();
        let orphan = kept.with_file_name("gone.json");
        std::fs::write(&orphan, b"{}").unwrap();
        outbox.add(d).unwrap();
        let journal = std::fs::read_to_string(journal_path(&path)).unwrap_or_default();
        assert!(read_saved(&path).deliveries.contains_key("d1"));
        assert!(!std::fs::read_to_string(&path).unwrap_or_default().contains(&data));
        assert!(!journal.contains(&data));
        assert_eq!(outbox.get("d1").unwrap().request["prompt"][0]["data"], data);
        let restarted = Outbox::default();
        let pending = restarted.open(&path);
        assert_eq!(pending[0].request["prompt"][0]["data"], data);
        assert!(kept.exists() && !orphan.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
