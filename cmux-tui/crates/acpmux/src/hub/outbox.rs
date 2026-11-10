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
//! journal's lines, the last line for an id winning. A change appends only the deliveries it
//! changed, so its cost does not grow with the deliveries kept: rewriting the whole file on every
//! change wrote 2 GB in 14 minutes with a day's 2,500 deliveries (5 MB) kept (hang-watch
//! `6159015094`, cmuxterm-hq#8660). A snapshot is written again once the journal is twice its
//! size (at least [`COMPACT_FLOOR`]), and at open when a journal is left over, so a change costs
//! about one and a half times its own lines however many deliveries are kept.
//!
//! A change returns once a file that holds it is on disk, unless the write failed: that is
//! logged and the change is only in memory until a later write succeeds, as before. The files are
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
    /// Bytes of the journal since the last snapshot, and of that snapshot.
    journal: u64,
    snapshot: u64,
    /// The next write is a snapshot: a journal was left at open, or an append failed and may
    /// have left a torn line.
    snapshot_next: bool,
    /// Bytes written to both files in this launch.
    written: u64,
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
            disk.journal = saved.journal_bytes;
            disk.snapshot_next = saved.journal_bytes > 0;
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
                let _ = std::fs::remove_file(entry.path());
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

    fn book(&self) -> std::sync::MutexGuard<'_, Book> {
        self.deliveries.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Where delivery `d`'s attachments are kept, when it has any and the outbox is on disk.
    pub fn attachments_path(&self, d: &Delivery) -> Option<PathBuf> {
        let blocks = d.request.get("prompt").and_then(Value::as_array)?;
        let path = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        crate::attach::any(blocks).then(|| attachments_dir(&path).join(format!("{}.json", d.id)))
    }

    /// Records a new delivery; the same prompt id again answers with the first one.
    pub fn add(&self, delivery: Delivery) -> Delivery {
        let (delivery, change) = self.add_scoped(delivery, false);
        self.save(change);
        self.changed.notify_waiters();
        delivery
    }

    /// A direct forward's recovery intent is scoped to its proven sender and target.
    /// Independent sessions may legitimately use the same client prompt id.
    /// Unlike ordinary queued deliveries, a forward must not proceed when this
    /// write fails: no later retry can recreate its intent after a restart.
    pub fn remember_forward(&self, delivery: Delivery) -> anyhow::Result<Delivery> {
        let (delivery, change) = self.add_scoped(delivery, true);
        self.save_checked(change)?;
        self.changed.notify_waiters();
        Ok(delivery)
    }

    fn add_scoped(&self, delivery: Delivery, scoped: bool) -> (Delivery, u64) {
        let mut book = self.book();
        let prompt_id = delivery.prompt_id().to_owned();
        if let Some(first) = book.deliveries.values().find(|d| {
            !d.is_team_receipt()
                && d.prompt_id() == prompt_id
                && d.request.pointer("/_meta/acpmux/forwardProjection").is_some() == scoped
                && (!scoped
                    || (d.caller == delivery.caller
                        && d.target == delivery.target
                        && projected_message(d) == projected_message(&delivery)))
        }) {
            let first = first.clone();
            // The first add may still be writing: answer once the file holds it too.
            let change = book.changes;
            return (first, change);
        }
        book.deliveries.insert(delivery.id.clone(), delivery.clone());
        book.dirty.insert(delivery.id.clone());
        let change = book.changed();
        (delivery, change)
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
        self.path.lock().unwrap_or_else(|e| e.into_inner()).is_none()
            || self.disk.lock().unwrap_or_else(|e| e.into_inner()).saved >= change
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
        let Some(path) = self.path.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
            return Ok(());
        };
        let mut disk = self.disk.lock().unwrap_or_else(|e| e.into_inner());
        if disk.saved >= change {
            return Ok(());
        }
        let snapshot = disk.snapshot_next || disk.journal >= COMPACT_FLOOR.max(2 * disk.snapshot);
        // The changed deliveries' lines and, for a snapshot, every delivery, as of one change.
        let (lines, whole, dirty, newest) = {
            let mut book = self.book();
            let dirty = std::mem::take(&mut book.dirty);
            let encoded = (|| -> serde_json::Result<_> {
                // A torn line an append left behind ends before these.
                let mut lines = if disk.snapshot_next { b"\n".to_vec() } else { Vec::new() };
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
        // The journal gets these lines before any snapshot, so a crash between the snapshot and
        // the journal's truncation replays the same last state for each id over it.
        let written = (|| -> anyhow::Result<()> {
            let journal = journal_path(&path);
            if lines.iter().any(|b| *b != b'\n') {
                use std::io::Write;
                let appended = crate::store::open_private_append(&journal).and_then(|mut f| {
                    f.write_all(&lines)?;
                    f.sync_data()?;
                    Ok(())
                });
                if let Err(e) = appended {
                    disk.snapshot_next = true;
                    return Err(e);
                }
                disk.journal += lines.len() as u64;
                disk.written += lines.len() as u64;
            }
            if let Some(whole) = whole {
                crate::config::write_atomic(&path, &whole)?;
                disk.snapshot = whole.len() as u64;
                disk.written += whole.len() as u64;
                match std::fs::OpenOptions::new().write(true).open(&journal) {
                    Ok(f) => {
                        f.set_len(0)?;
                        f.sync_data()?;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(e.into()),
                }
                disk.journal = 0;
                disk.snapshot_next = false;
            }
            Ok(())
        })();
        // Failed writes never advance saved. A retry of the same in-memory intent
        // must try the write again before it can report success.
        if let Err(e) = written {
            self.book().dirty.extend(dirty);
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

/// What the files at `path` hold.
struct Saved {
    deliveries: BTreeMap<String, Delivery>,
    snapshot_bytes: u64,
    journal_bytes: u64,
}

/// The snapshot at `path`, then each journal line over it. A snapshot that cannot be read starts
/// empty (and is replaced); a journal line that cannot be read (a torn append) is skipped.
fn read_saved(path: &Path) -> Saved {
    let (mut deliveries, snapshot_bytes) = match std::fs::read(path) {
        Ok(bytes) => (
            serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                tracing::warn!("outbox: {} cannot be read, starting empty: {e}", path.display());
                BTreeMap::new()
            }),
            bytes.len() as u64,
        ),
        Err(_) => (BTreeMap::new(), 0),
    };
    let journal = std::fs::read(journal_path(path)).unwrap_or_default();
    for line in journal.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
        match serde_json::from_slice::<Delivery>(line) {
            Ok(d) => {
                deliveries.insert(d.id.clone(), d);
            }
            Err(e) => tracing::warn!("outbox: a journal line cannot be read, skipped: {e}"),
        }
    }
    Saved { deliveries, snapshot_bytes, journal_bytes: journal.len() as u64 }
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
            outbox.add(d);
        }
        let mut intent = delivery(9);
        intent.request["_meta"]["acpmux"]["forwardProjection"] = json!({"text": "x"});
        intent.state = State::Held;
        outbox.add(intent);
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
        outbox.add(delivery(1));
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
        assert_eq!(outbox.add(delivery(1)).id, "d-1");
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
                    outbox.add(delivery(n));
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
            std::thread::spawn(move || outbox.add(delivery(1)))
        };
        while outbox.get("d-1").is_none() {
            std::thread::yield_now();
        }
        let retry = {
            let outbox = outbox.clone();
            let path = path.clone();
            std::thread::spawn(move || {
                let again = outbox.add(delivery(1));
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

    /// cmuxterm-hq#8660 (hang-watch `6159015094`): the bytes a change writes do not grow with
    /// the deliveries kept. Small is 10 kept, god 25,000 (ten days of a busy machine, 52 MB);
    /// "before" is what the whole-file rewrite wrote for each change, the snapshot's size.
    #[test]
    fn a_change_writes_the_same_bytes_with_ten_or_25000_deliveries_kept() {
        let mut per_change = Vec::new();
        for kept in [10, 25_000] {
            let (dir, path) = temp_outbox();
            let all: BTreeMap<String, Delivery> = (0..kept)
                .map(|n| sized(n, State::Delivered))
                .map(|d| (d.id.clone(), d))
                .collect();
            let before = serde_json::to_vec(&all).unwrap().len() as u64;
            std::fs::write(&path, serde_json::to_vec(&all).unwrap()).unwrap();
            let outbox = Outbox::default();
            outbox.open(&path);
            let start = outbox.disk.lock().unwrap().written;
            let changes = 2_000;
            for n in 0..changes / 4 {
                // A send's life: queued, delivering, attempted again, delivered.
                let id = format!("d-{}", kept + n);
                outbox.add(sized(kept + n, State::Queued));
                outbox.update(&id, |d| d.state = State::Delivering);
                outbox.update(&id, |d| d.attempts += 1);
                outbox.update(&id, |d| d.state = State::Delivered);
            }
            let after = (outbox.disk.lock().unwrap().written - start) / changes as u64;
            eprintln!("kept {kept}: before {before} B per change, after {after} B per change");
            per_change.push(after);
            // Everything comes back after a restart, from the snapshot and the journal.
            let restarted = Outbox::default();
            assert!(restarted.open(&path).is_empty());
            assert_eq!(restarted.list(None, usize::MAX).0.len(), kept + changes / 4);
            assert_eq!(restarted.get(&format!("d-{kept}")).unwrap().attempts, 1);
            assert!(before > 10 * after || kept == 10);
            let _ = std::fs::remove_dir_all(&dir);
        }
        assert!(
            per_change[1] * 10 <= per_change[0] * 12,
            "god {} B per change is over 1.2x small {} B",
            per_change[1],
            per_change[0]
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
            outbox.add(delivery(n));
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
        assert_eq!(std::fs::metadata(&journal).unwrap().len(), 0, "the open compacts");
        let snapshot: BTreeMap<String, Delivery> =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(snapshot.len(), 3, "the snapshot alone holds everything for an older daemon");
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
        outbox.add(delivery(0));
        // The snapshot's rename fails: a folder that is not empty is in its place.
        std::fs::create_dir_all(path.join("occupied")).unwrap();
        outbox.disk.lock().unwrap().snapshot_next = true;
        outbox.update("d-0", |d| d.state = State::Delivered);
        assert!(outbox.disk.lock().unwrap().saved < outbox.book().changes, "nothing marked saved");
        let journal = String::from_utf8(std::fs::read(journal_path(&path)).unwrap()).unwrap();
        let last: Delivery = serde_json::from_str(journal.lines().last().unwrap()).unwrap();
        assert_eq!(last.state, State::Delivered);
        std::fs::remove_dir_all(&path).unwrap();
        let restarted = Outbox::default();
        assert!(restarted.open(&path).is_empty());
        assert_eq!(restarted.get("d-0").unwrap().state, State::Delivered);
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
        outbox.add(d);
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
