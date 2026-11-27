//! Part of `Hub` (a child of `transfer_history.rs`). A chat's session pack is kept current as its
//! log grows (RFD 0075, "acpmux packs as it appends"): each time the log passes another 4 MiB
//! ([`crate::store::GROWN_EVERY`]), the chat's pack store (`history-pack` in its folder) seals the
//! segment that filled and its manifest names it. A move's export then finds every sealed segment
//! already there and encodes only the open tail, a few hundred milliseconds, not the 2 to 3 s a
//! 30 MB log takes from nothing.
//!
//! Leo, 2026-11-23: "likewise, i want ultra good compression and being able to rapidly partially
//! decompact or wahteer the heck".
//!
//! Off the append path. The store calls a hook from the append that took a log segment past a
//! multiple of 4 MiB (two divisions on every append, the hook once per 4 MiB): it only puts the
//! chat's id in [`Hub::pack_grown`] and wakes the worker ([`Hub::pack_as_it_grows_worker`]). The
//! worker takes the set and, on a thread of its own at the lowest CPU priority (its zstd workers
//! inherit it), packs one chat after another. No append waits for it, and no lock an append
//! takes is held while it encodes: it holds only the chat's [`PackTurn`], which only packs take.
//!
//! What a seal packs is the lines an export packs ([`Hub::write_lines`]): records through the
//! chat's last stored seq, after [`Hub::display_logged`]. The first seal of a chat in a daemon's
//! life is a whole [`pack::pack`], which checks every sealed segment the store holds against the
//! log (BLAKE3, about 4 ms a segment) and encodes from the first that differs. After it, while
//! the log's stamp ([`Store::log_stamp`]: a count of rewrites of lines already written) stays the
//! same, a seal reads only the records after the last sealed segment's last seq and extends the
//! pack from there ([`pack::pack_after`]): its cost is the 4 MiB that filled and the open tail,
//! whatever the log's length. A rewritten log (retention, a history that arrived) changes the
//! stamp, and the next seal is a whole pack again.
//!
//! A chat that awaits its history (`transfer-history-pending.json`), moved away, or was purged
//! is not packed: its log here is not the chat's whole log. Nothing here changes the log, the
//! cold archive (`store/cold.rs`) or cold segments; the pack is a second copy, about a twelfth
//! of the log's size, in the chat's folder, and goes with it.
//!
//! A seal writes the chat's lines to a `work-*` folder in its pack store and removes it after. A
//! daemon that ends mid-seal (a restart, a kill, an update) leaves that folder, which is the
//! chat's whole log as lines: on Leo's Mac, 2026-11-27, five of them held 18.75 GB (8.4 and
//! 7.0 GB of one 8.6 GB chat) and nothing removed them. [`sweep_dead_work`] removes them: each
//! seal sweeps its own chat's under its pack turn (only a seal makes one, and only under that
//! turn), so any it finds is a dead seal's. A chat's next seal comes with its next 4 MiB, and
//! the chats whose logs are large enough to leave a big one are the ones that grow. No sweep
//! walks every chat at start: `session_dir` settles or materializes a chat (journal and fork
//! stores), which is not a cost to pay for 700 chats to find a few folders.
//!
//! `ACPMUX_PACK_AS_IT_GROWS=0` turns it off (nothing is installed; a pack is then made only at
//! a move, as before).
//!
//! Stop condition: the worker is a task of the hub's scope and ends when the daemon shuts down
//! (the scope's close cancels it; `shutdown.rs` also wakes it, and it finds the shutdown begun;
//! a round checks it between chats) or the hub is gone; it holds the hub weakly between wakes.

use super::*;

/// Whether the worker runs: unless `ACPMUX_PACK_AS_IT_GROWS` is `0`, `false` or `off`.
fn enabled() -> bool {
    !matches!(
        std::env::var("ACPMUX_PACK_AS_IT_GROWS").ok().as_deref().map(str::trim),
        Some("0" | "false" | "off")
    )
}

/// The prefix of a seal's scratch folder in a chat's pack store.
const WORK_PREFIX: &str = "work-";

/// Removes every seal scratch folder (`work-*`) in the pack store at `root`; the bytes freed.
/// The caller holds the chat's [`PackTurn`], so none of them is a live seal's.
pub(in crate::hub) fn sweep_dead_work(root: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(root) else { return 0 };
    let mut freed = 0u64;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let dir = entry.file_type().is_ok_and(|t| t.is_dir());
        if !dir || !name.to_string_lossy().starts_with(WORK_PREFIX) {
            continue;
        }
        let bytes = super::super::bundle_files(&entry.path())
            .map(|files| files.iter().map(|(_, size)| size).sum::<u64>())
            .unwrap_or(0);
        match crate::home_fs::remove_dir_all(entry.path()) {
            Ok(()) => freed += bytes,
            Err(error) => tracing::warn!("dead seal scratch not removed: {error:#}"),
        }
    }
    freed
}

/// What one seal of a chat did.
#[derive(Debug)]
pub(in crate::hub) struct Sealed {
    /// The pack's manifest after it.
    pub manifest: pack::Manifest,
    pub stats: pack::PackStats,
    /// Whether it extended the pack from its sealed end (else it was a whole pack).
    pub extended: bool,
}

impl Hub {
    /// Installs the store's hook and starts the worker (module docs); `None` when it is off.
    /// The hub's scope owns it: its close at shutdown ends it, as the shutdown check does.
    pub fn pack_as_it_grows_worker(
        self: &Arc<Self>,
    ) -> Option<tokio::task::JoinHandle<Option<()>>> {
        if !enabled() {
            return None;
        }
        let (set, wake) = (self.pack_grown.clone(), self.pack_grown_wake.clone());
        self.store.on_log_grown(Arc::new(move |id: &str| {
            set.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned());
            wake.notify_one();
        }));
        let hub = Arc::downgrade(self);
        let (set, wake) = (self.pack_grown.clone(), self.pack_grown_wake.clone());
        Some(self.scope.spawn_until_cancelled("pack-as-it-grows", async move {
            loop {
                wake.notified().await;
                let Some(hub) = hub.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                let ids = std::mem::take(&mut *set.lock().unwrap_or_else(|e| e.into_inner()));
                if ids.is_empty() {
                    continue;
                }
                let (done, ended) = oneshot::channel::<()>();
                let asked = ids.clone();
                // A thread of its own, not the blocking pool: its priority is lowered for good.
                let spawned =
                    std::thread::Builder::new().name("acpmux-pack-grow".into()).spawn(move || {
                        lower_this_thread();
                        hub.pack_round(ids);
                        let _ = done.send(());
                    });
                match spawned {
                    Ok(_) => {
                        let _ = ended.await;
                    }
                    Err(error) => {
                        // Kept for the next wake, so these chats do not wait for their logs to
                        // pass another mark.
                        set.lock().unwrap_or_else(|e| e.into_inner()).extend(asked);
                        tracing::warn!("chat packs not sealed (kept for the next round): {error}");
                    }
                }
            }
        }))
    }

    /// One round over `ids`, one chat after another.
    fn pack_round(&self, ids: std::collections::BTreeSet<String>) {
        for id in ids {
            if self.shutting_down() {
                return;
            }
            match self.seal_pack(&id) {
                Ok(Some(sealed)) => tracing::debug!(
                    session = %id,
                    "chat pack sealed: {} segments, {} of {} bytes encoded, extended {}",
                    sealed.manifest.segments.len(),
                    sealed.stats.encoded_bytes,
                    sealed.stats.raw_bytes,
                    sealed.extended,
                ),
                Ok(None) => {}
                Err(error) => tracing::warn!(session = %id, "chat pack not sealed: {error:#}"),
            }
        }
    }

    /// Brings chat `id`'s pack up to its log (module docs). `None` when the chat is not one
    /// packed here.
    pub(in crate::hub) fn seal_pack(&self, id: &str) -> anyhow::Result<Option<Sealed>> {
        // The turn comes first, so a seal already running for this chat cannot put back the
        // entry this one drops below.
        let _turn = PackTurn::take(id);
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        let Some(session) = session else {
            self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
            return Ok(None);
        };
        if session.purged.load(Ordering::SeqCst)
            || session.read_meta(|m| m.moved_to.is_some())
            || self.history_awaited(id).is_some()
        {
            // Its entry goes with it: a purged or moved chat's id is not kept for the daemon's
            // life, and a chat that comes back (a history that arrived) is packed whole.
            self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
            return Ok(None);
        }
        // Every record stored by now; one whose append is under way waits for the next seal.
        let through = session.read_meta(|m| m.last_seq);
        if through == 0 {
            return Ok(None);
        }
        let opened = self.pack_store(id).and_then(|store| Ok((store, self.store.log_stamp(id)?)));
        let (store, stamp) = match opened {
            Ok(opened) => opened,
            Err(error) => {
                // As any failed seal below: the next one trusts nothing.
                self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
                return Err(error);
            }
        };
        // Under the turn no other seal of this chat runs: any scratch here is a dead one's.
        let freed = sweep_dead_work(store.root());
        if freed > 0 {
            tracing::info!(session = %id, "removed {freed} bytes of seal scratch a daemon left");
        }
        let checked =
            self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).get(id) == Some(&stamp);
        let work = store.root().join(format!("{WORK_PREFIX}{}", uuid::Uuid::now_v7().simple()));
        let sealed = (|| -> anyhow::Result<Sealed> {
            if checked && let Some(extended) = self.extend_pack(&session, through, &store, &work)? {
                return Ok(extended);
            }
            let (manifest, stats, _) = self.pack_through(&session, through, &store, &work)?;
            Ok(Sealed { manifest, stats, extended: false })
        })();
        let _ = crate::home_fs::remove_dir_all(&work);
        if sealed.is_err() {
            // Whatever failed, the next seal trusts nothing: it packs whole and re-verifies.
            self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        }
        let sealed = sealed?;
        self.pack_checked.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned(), stamp);
        Ok(Some(sealed))
    }

    /// The pack in `store` extended from its last sealed segment with the records after it
    /// through `through`, or `None` when it has no sealed segment to extend from.
    fn extend_pack(
        &self,
        session: &Session,
        through: u64,
        store: &pack::Store,
        work: &Path,
    ) -> anyhow::Result<Option<Sealed>> {
        let Some(manifest) = pack::Manifest::load(store, &session.id).map_err(pack_error)? else {
            return Ok(None);
        };
        let last = manifest.segments.iter().take_while(|s| s.sealed).last();
        let Some((line, Some((_, seq)))) = last.map(|s| (s.line + s.lines, s.seq)) else {
            return Ok(None);
        };
        crate::home_fs::create_dirs(work)?;
        let lines = work.join("tail.ndjson");
        let (last, _) = self.write_lines(session, seq, through, &lines)?;
        // As a whole pack checks: a log that ends before `through` is not recorded as sealed
        // through it.
        if last != through {
            let _ = crate::home_fs::remove_file(&lines);
            anyhow::bail!("the log here holds no record at seq {through} (it ends at {last})");
        }
        let params = pack::Params::default();
        let packed = pack::pack_after(store, &session.id, line, &[lines], &params);
        Ok(packed.map_err(pack_error)?.map(|(manifest, stats)| Sealed {
            manifest,
            stats,
            extended: true,
        }))
    }
}

#[cfg(test)]
#[path = "pack_as_it_grows_tests.rs"]
mod tests;
