//! Part of `Hub`; see `hub/mod.rs`. The one writer of a chat's journal while a journal restore
//! owns it (review of #37284 at 4dcbe192, F1 to F3: a seq taken while a restore owns the chat,
//! one path at a time, made the restore diverge or wrote into the seqs it needed).
//!
//! Every record of a chat's journal is appended by `Hub::append_record_locked` (`hub/mod.rs`),
//! under the chat's `append_lock`: turns, recovery (a cut turn's continuation, its unknown
//! outcome), `queued` and every `queue_*` record, admissions, forwarded prompts, an agent's own
//! updates. A restore's own records go in by `journal_restore.rs` under the same lock, at the seqs
//! they had. No other code appends a chat's record (`a_chat_journal_is_appended_in_one_place`
//! reads the source for it).
//!
//! From a restore's admission until it ends (its last try, or its hold's lapse) the chat parks:
//! a record appended meanwhile takes no seq and goes nowhere yet. It is kept, in order, and
//! appended, published and counted when the restore ends, after the restore's records and the
//! recovery that follows them. Only the restore's own thread, holding the token of its try,
//! writes meanwhile ([`RestoreWriter`]). Turns and prompts wait for `restore_done` before they
//! write (`queue.rs`), so what parks is what comes on its own: an agent's update between turns, a
//! client's edit of the queue, a status.
//!
//! A parked record's caller gets it back with seq 0, and not stored: the seq is its own, and it
//! is durable, only once it is in (review of #37284 at c4a6f4e7, F1: c4a6f4e7 said stored, then
//! dropped a record the store refused when the restore ended). One whose source sends it again
//! until it is stored (`stored_only`, an agent host's entry) is not kept: it comes again. Every
//! other one
//! is kept; when the store refuses it at the restore's end, it and every later record of the
//! chat wait, in order, and go in first at the next append ([`Hub::behind_unparked`]).

use super::*;
use std::cell::Cell;

/// A record appended while a restore owned its chat, kept until the restore ends.
pub(super) struct Parked {
    dir: String,
    kind: String,
    msg: Value,
    host_seq: Option<u64>,
    at: u64,
    stored_only: bool,
    kept: log_deferral::Kept,
    notify: bool,
}

thread_local! {
    /// The chat (its address) and the restore try whose token this thread holds.
    static WRITER: Cell<(usize, u64)> = const { Cell::new((0, 0)) };
    /// Set while this thread writes a log's recovery (`log_load.rs`): its records are marked.
    static RECOVERING: Cell<bool> = const { Cell::new(false) };
}

/// The key that marks a record this machine's own recovery wrote after a restart (a cut turn's
/// unknown outcome and continuation, a lost wait, a queue put back): a journal restore takes
/// those seqs back when the owner's copy holds what was really there (review of #37284 at
/// 4dcbe192, F1), and the recovery is made again on the restored log.
pub(super) const RECOVERY_MARK: &str = "_acpmuxRecovery";

/// Marks every record this thread appends, while it lives, as recovery ([`RECOVERY_MARK`]).
pub(super) struct Recovering {
    before: bool,
}

impl Recovering {
    pub(super) fn start() -> Self {
        Recovering { before: RECOVERING.with(|r| r.replace(true)) }
    }
}

impl Drop for Recovering {
    fn drop(&mut self) {
        RECOVERING.with(|r| r.set(self.before));
    }
}

/// `msg` marked as recovery when this thread writes one ([`Recovering`]).
pub(super) fn marked(mut msg: Value) -> Value {
    if RECOVERING.with(Cell::get)
        && let Some(fields) = msg.as_object_mut()
    {
        fields.insert(RECOVERY_MARK.into(), Value::Bool(true));
    }
    msg
}

/// Whether a record is one recovery wrote ([`RECOVERY_MARK`]).
pub(super) fn is_recovery(record: &EventRecord) -> bool {
    record.msg.get(RECOVERY_MARK) == Some(&Value::Bool(true))
}

/// What `record`, as its chat's journal holds it at the journal's end, makes of where the
/// journal's own recovery begins (`SessionMeta::recovered_after`, review of #37284 at 8b5f3063,
/// F2): a recovery record goes on with it, or begins it just before itself; any other record
/// ends it. The same rule `journal_restore.rs` `recovery_tail` reads the journal by, kept as the
/// records go in, so a list names it without reading the journal.
pub(super) fn note_recovery(meta: &mut SessionMeta, record: &EventRecord) {
    meta.recovered_after = if is_recovery(record) {
        meta.recovered_after.or(Some(record.seq.saturating_sub(1)))
    } else {
        None
    };
}

/// The token of restore try `n` of `session` on this thread while it lives: only this thread
/// writes the chat's journal meanwhile.
pub(super) struct RestoreWriter {
    before: (usize, u64),
}

impl RestoreWriter {
    pub(super) fn hold(session: &Session) -> Self {
        let n = session.restore_token.load(Ordering::SeqCst);
        let before = WRITER.with(|w| w.replace((std::ptr::from_ref(session) as usize, n)));
        RestoreWriter { before }
    }
}

impl Drop for RestoreWriter {
    fn drop(&mut self) {
        WRITER.with(|w| w.set(self.before));
    }
}

/// Whether a record not stored comes again from its source: its caller appends it again
/// (`stored_only`), or it logs an agent host's entry (`host_seq`), which the host keeps and sends
/// again until it hears it stored. Kept here too, it would go in twice.
fn again_unstored(stored_only: bool, host_seq: Option<u64>) -> bool {
    stored_only || host_seq.is_some()
}

fn holds_token(session: &Session) -> bool {
    let n = session.restore_token.load(Ordering::SeqCst);
    n != 0 && WRITER.with(Cell::get) == (std::ptr::from_ref(session) as usize, n)
}

impl Hub {
    /// From now on `session` parks every record but its restore's (`journal_restore.rs`, at its
    /// admission). Try `n`'s token writes.
    pub(super) fn park_writes(&self, session: &Session, n: u64) {
        let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        session.restore_token.store(n, Ordering::SeqCst);
        if !self.at_4dcb() {
            session.parked.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(Vec::new);
        }
    }

    /// The restore ended: what parked meanwhile goes in, in order, and the chat writes as before.
    /// What the store refuses waits for the next append ([`Self::behind_unparked`]).
    pub(super) fn unpark_writes(&self, session: &Session) {
        let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        session.restore_token.store(0, Ordering::SeqCst);
        let parked = session.parked.lock().unwrap_or_else(|e| e.into_inner()).take();
        let parked = parked.unwrap_or_default();
        if parked.is_empty() {
            return;
        }
        tracing::info!(session = %session.id, records = parked.len(), "records kept while a restore owned this chat go in");
        self.catch_up_locked(session);
        if self.at_c4a6() {
            // c4a6f4e7: each appended, its answer not read.
            for p in parked {
                let _ = self.write_record_locked(
                    session,
                    &p.dir,
                    &p.kind,
                    p.msg,
                    p.host_seq,
                    Some(p.at),
                    p.stored_only,
                    p.kept,
                    p.notify,
                );
            }
            return;
        }
        session.unparked.lock().unwrap_or_else(|e| e.into_inner()).extend(parked);
        self.store_unparked(session);
    }

    /// Writes what parked so far, now, by the restore's own thread, before it rebuilds anything
    /// from the journal (`log_load.rs`: `settle_restored`, `recover_log`): a queue edit or a
    /// removal made meanwhile changed the chat in memory and was answered, so the rebuilt queue
    /// must read its record (review of #37284 at ff3da306, F1: the rebuild left it out, and the
    /// answered edit was lost). What parks after it still waits for the restore's end. A thread
    /// that holds no token of the restore writes nothing here.
    ///
    /// Answers whether every record kept so far is in the journal: one the store refuses stays
    /// kept ([`Session::unparked`]), and its caller decides (review of #37284 at a088585e, F1:
    /// a088585e went on as if it were in). A rebuild reads the ones kept after the journal
    /// ([`Self::kept_unstored`]).
    pub(super) fn write_parked(&self, session: &Session) -> bool {
        if self.at_ff3d() || !holds_token(session) {
            return true;
        }
        let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        let parked = {
            let mut parked = session.parked.lock().unwrap_or_else(|e| e.into_inner());
            parked.as_mut().map(std::mem::take).unwrap_or_default()
        };
        if !parked.is_empty() {
            tracing::info!(session = %session.id, records = parked.len(), "records kept while a restore owns this chat go in before it is rebuilt");
            self.catch_up_locked(session);
            session.unparked.lock().unwrap_or_else(|e| e.into_inner()).extend(parked);
        }
        self.store_unparked(session) || self.at_a088()
    }

    /// `session`'s journal records of `kinds`, in order, each given to `f` until it answers
    /// false, then those [`Self::kept_unstored`] holds (when the journal read whole).
    pub(super) fn scan_kinds_and_kept(
        &self,
        session: &Session,
        kinds: &[&str],
        f: &mut dyn FnMut(EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        let mut going = true;
        self.store.scan_kinds(&session.id, kinds, &mut |e| {
            going = f(e);
            going
        })?;
        for e in self.kept_unstored(session, kinds) {
            if !going {
                break;
            }
            going = f(e);
        }
        Ok(())
    }

    /// The records of `kinds` kept for `session` that are not in its journal yet: those the
    /// store refused ([`Session::unparked`]), then those parked while a restore owns it, in
    /// order, numbered past the journal's end as they go in. A rebuild of the queue reads them
    /// after the journal, so a change answered meanwhile is in it whether or not its record is
    /// stored yet (review of #37284 at a088585e, F1).
    pub(super) fn kept_unstored(&self, session: &Session, kinds: &[&str]) -> Vec<EventRecord> {
        if self.at_a088() {
            return Vec::new();
        }
        let unparked = session.unparked.lock().unwrap_or_else(|e| e.into_inner());
        let parked = session.parked.lock().unwrap_or_else(|e| e.into_inner());
        let kept = unparked.iter().chain(parked.iter().flatten());
        let next = session.seq.load(Ordering::SeqCst);
        kept.filter(|p| kinds.contains(&p.kind.as_str()))
            .zip(1..)
            .map(|(p, n)| EventRecord {
                seq: next + n,
                at: p.at,
                dir: p.dir.clone(),
                kind: p.kind.clone(),
                msg: p.msg.clone(),
                host_seq: p.host_seq,
            })
            .collect()
    }

    /// Whether a change of `session`'s queue parked since the last [`Self::write_parked`]: its
    /// change is in memory, and a queue rebuilt from the journal since lacks it (review of #37284
    /// at 07f76930, F1: an edit or a removal between the drain and the rebuild was lost). Read
    /// under the queue's lock: every change of the queue logs its record under that lock, so
    /// none is half made here, and one made after this is made on the rebuilt queue. Only the
    /// thread that holds the restore's token asks.
    pub(super) fn queue_changed_meanwhile(&self, session: &Session) -> bool {
        if self.at_07f7() || !holds_token(session) {
            return false;
        }
        let _queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
        let parked = session.parked.lock().unwrap_or_else(|e| e.into_inner());
        parked
            .as_ref()
            .is_some_and(|p| p.iter().any(|r| Self::QUEUE_KINDS.contains(&r.kind.as_str())))
    }

    /// Stores the records kept for `session` ([`Session::unparked`]), in order, each counted
    /// and published once it is in; the first the store refuses stops it, kept with those
    /// after it. Answers whether none is left. The caller holds `append_lock`.
    fn store_unparked(&self, session: &Session) -> bool {
        loop {
            let next = {
                let mut kept = session.unparked.lock().unwrap_or_else(|e| e.into_inner());
                if kept.is_empty() {
                    return true;
                }
                kept.remove(0)
            };
            let kept = match &next.kept {
                log_deferral::Kept::Sent => log_deferral::Kept::Sent,
                log_deferral::Kept::Stub(stub) => log_deferral::Kept::Stub(stub.clone()),
            };
            let (record, stored) = self.write_record_locked(
                session,
                &next.dir,
                &next.kind,
                next.msg.clone(),
                next.host_seq,
                Some(next.at),
                true,
                kept,
                next.notify,
            );
            if !stored {
                tracing::warn!(session = %session.id, kind = %next.kind, "a record kept while a restore owned this chat was not stored; it goes in at the next append");
                session.unparked.lock().unwrap_or_else(|e| e.into_inner()).insert(0, next);
                return false;
            }
            let mut deferral = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner());
            deferral.stored(&record.dir, &record.kind, &record.msg);
        }
    }

    /// Holds back a record `append_record_locked` was given while records a restore's end could
    /// not store wait ([`Session::unparked`]): they go first; when one still does not, this one
    /// waits behind them (or, `stored_only`, goes back to its caller), not stored. None when
    /// nothing waits: it is written now. The caller holds `append_lock`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn behind_unparked(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
        stored_only: bool,
        kept: log_deferral::Kept,
        notify: bool,
    ) -> Result<(EventRecord, bool), (Value, log_deferral::Kept)> {
        let waits = !session.unparked.lock().unwrap_or_else(|e| e.into_inner()).is_empty();
        if !waits || self.store_unparked(session) {
            return Err((msg, kept));
        }
        let at = at.unwrap_or_else(now_ms);
        let record = EventRecord {
            seq: 0,
            at,
            dir: dir.into(),
            kind: kind.into(),
            msg: msg.clone(),
            host_seq,
        };
        if !again_unstored(stored_only, host_seq) {
            session.unparked.lock().unwrap_or_else(|e| e.into_inner()).push(Parked {
                dir: dir.into(),
                kind: kind.into(),
                msg,
                host_seq,
                at,
                stored_only,
                kept,
                notify,
            });
        }
        Ok((record, false))
    }

    /// Parks a record `append_record_locked` was given while a restore owns `session` and this
    /// thread holds no token of it; None when it writes now. Not stored yet: its caller hears so
    /// (c4a6f4e7 said stored). The caller holds `append_lock`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn parked_write(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
        stored_only: bool,
        kept: log_deferral::Kept,
        notify: bool,
    ) -> Result<(EventRecord, bool), (Value, log_deferral::Kept)> {
        let mut parked = session.parked.lock().unwrap_or_else(|e| e.into_inner());
        let Some(parked) = parked.as_mut().filter(|_| !holds_token(session)) else {
            return Err((msg, kept));
        };
        let at = at.unwrap_or_else(now_ms);
        let record = EventRecord {
            seq: 0,
            at,
            dir: dir.into(),
            kind: kind.into(),
            msg: msg.clone(),
            host_seq,
        };
        let old = self.at_c4a6();
        // One its source sends again until it is stored goes back to it.
        if again_unstored(stored_only, host_seq) && !old {
            return Ok((record, false));
        }
        parked.push(Parked {
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq,
            at,
            stored_only,
            kept,
            notify,
        });
        Ok((record, old))
    }
}

#[cfg(test)]
mod tests {
    /// Every append of a chat's journal record is `append_record_locked`'s (the restore's own
    /// records aside, `journal_restore.rs`): no other code calls the store's `append`, so nothing
    /// takes a seq while a restore owns the chat but through the writer that parks it. An import
    /// writes a new chat's log before it is listed; the machine journal is no chat's.
    #[test]
    fn a_chat_journal_is_appended_in_one_place() {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/src");
        let allowed =
            ["hub/mod.rs", "hub/journal_restore.rs", "hub/transfer.rs", "write_journal.rs"];
        let mut found = Vec::new();
        let mut dirs = vec![std::path::PathBuf::from(root)];
        while let Some(dir) = dirs.pop() {
            for entry in std::fs::read_dir(&dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    dirs.push(path);
                    continue;
                }
                let rel = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
                if !rel.ends_with(".rs")
                    || rel.ends_with("_tests.rs")
                    || rel.starts_with("store")
                    || allowed.contains(&rel.as_str())
                {
                    continue;
                }
                let text = std::fs::read_to_string(&path).unwrap();
                // A file's own test module may write a log directly.
                let text = text.split("#[cfg(test)]\nmod tests").next().unwrap_or_default();
                for (n, line) in text.lines().enumerate() {
                    if line.contains("store.append(") || line.contains(".append_line(") {
                        found.push(format!("{rel}:{}: {}", n + 1, line.trim()));
                    }
                }
            }
        }
        assert!(
            found.is_empty(),
            "a chat's journal appended past its writer:\n{}",
            found.join("\n")
        );
    }
}
