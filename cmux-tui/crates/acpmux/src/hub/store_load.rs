//! Metadata loading after the listener starts. Exact-id reads install just that chat; names
//! and operations over the whole session set wait for the index, never for the chat logs.
use super::*;

pub(super) struct StoreLoad {
    pub ready: tokio::sync::watch::Sender<bool>,
    pub total: std::sync::atomic::AtomicUsize,
}

impl StoreLoad {
    pub fn new(loading: bool) -> Self {
        Self { ready: tokio::sync::watch::channel(!loading).0, total: Default::default() }
    }
}

impl Hub {
    pub(super) fn load_from_store(self: &Arc<Self>, deferred: bool) {
        // A bounded debug seam for slow-filesystem startup tests; absent in release builds.
        #[cfg(debug_assertions)]
        if let Some(ms) = std::env::var("ACPMUX_TEST_DELAY_LOAD_STORE_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
        {
            std::thread::sleep(std::time::Duration::from_millis(ms.min(10_000)));
        }
        let Ok(mut metas) = self.store.list().inspect_err(|e| tracing::warn!("store list: {e}"))
        else {
            // Adoption still reaches every host this list hid: an off push waits for it
            // (`full_access_turned_off`).
            if deferred {
                self.adoption_ready.send_replace(false);
            }
            return;
        };
        tracing::debug!(target: crate::daemon::HANDOFF_TIMING, "handoff timing: store listed");
        // The small index the chat logs load by (`log_load.rs`): agent hosts still running.
        let read = Self::read_live_host_sessions();
        // Records that can not be read may hide a host whose lines adoption holds again: an off
        // push waits for adoption then too (`full_access_turned_off`).
        let unknown = read.is_none();
        let hosted = read.unwrap_or_default();
        let waiting =
            metas.iter().filter(|m| m.status == SessionStatus::Waiting).map(|m| m.id.clone());
        if deferred && (!hosted.is_empty() || unknown) {
            self.adoption_ready.send_replace(false);
        }
        {
            let mut plan = self.load_plan.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            plan.listed = true;
            plan.waiting.extend(waiting);
            plan.adopting.extend(hosted.iter().cloned());
            plan.hosted.extend(hosted.iter().cloned());
        }
        // An older daemon's approve-all that could be vmHost's asks now (`policy_source.rs`).
        let unsaved = self.settle_legacy_grants(&mut metas);
        // A deleted chat stays out of the map through its grace (`soft_delete.rs`).
        self.hold_deleted(&mut metas);
        self.store_load.total.store(metas.len(), Ordering::SeqCst);
        // A first start with no ledger file: each session's running totals (`hub/ledger`).
        if self.ledger.wants_seed() {
            // Forks' own turns are read first, so the ledger's lock waits on no log read.
            let seeds: Vec<_> =
                metas.iter().map(|m| ledger::Seed::of(m, self.fork_own_turns(m))).collect();
            self.ledger.seed(seeds);
        }
        for meta in metas {
            let hosted = hosted.contains(&meta.id);
            let saved = !unsaved.contains(&meta.id);
            self.install_stored_session(meta, deferred, hosted, saved);
        }
        tracing::info!(
            "loaded {} sessions from store",
            self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len()
        );
        if deferred {
            self.logs_ready.send_replace(false);
        }
        self.resume_races();
    }

    pub async fn load_store_async(self: &Arc<Self>) {
        let hub = self.clone();
        let result = tokio::task::spawn_blocking(move || {
            tracing::debug!(target: crate::daemon::HANDOFF_TIMING, "handoff timing: store load");
            hub.load_from_store(true);
            tracing::debug!(target: crate::daemon::HANDOFF_TIMING, "handoff timing: store installed");
            // Before spawns are released, after the index is complete. This sweep must never
            // mistake the initially empty in-memory session map for an empty store.
            #[cfg(unix)]
            hub.sweep_session_tmp();
            // The moves and scratch a daemon before this one left in `transfers/`: its scratch
            // goes now (`transfer_out.rs` `scratch_dir`), not at the next move.
            super::transfer_out::note_started();
            hub.sweep();
            // And the seal scratch a relaunch cut short in chats' pack stores (`pack_trust.rs`).
            hub.sweep_all_pack_work();
        })
        .await;
        if let Err(error) = result {
            tracing::error!("reading the session store failed: {error}");
        }
        self.watch_orphans();
        self.store_load.ready.send_replace(true);
        tracing::debug!(target: crate::daemon::HANDOFF_TIMING, "handoff timing: store loaded");
        // Chats read now get the synced winners kept for them (`synced.rs`).
        self.synced_after_start();
        // Chats with no agent may leave memory (`evict.rs`): the reaper runs for them too.
        if self.evicted.after().is_some() || self.evicted.cap().is_some() {
            self.wake_idle_reaper();
        }
        // Closed sessions' temporary folders, now and every hour (`closed_tmp.rs`).
        #[cfg(unix)]
        self.sweep_closed_tmps();
        self.bg_notify_resume_in_background();
    }

    pub(crate) async fn wait_store(&self) {
        let mut ready = self.store_load.ready.subscribe();
        let _ = ready.wait_for(|ready| *ready).await;
    }

    pub(crate) fn store_loaded(&self) -> bool {
        *self.store_load.ready.borrow()
    }

    /// Only an exact UUID can bypass the index: names/prefixes need the whole set to prove
    /// uniqueness. A legacy policy needs the migration's complete ancestry and waits for it.
    pub(crate) async fn session_meta(self: &Arc<Self>, key: &str) {
        if self.store_loaded() {
            return;
        }
        let id = match SessionReceipt::split_qualified_id(key) {
            Some((host, id)) if host == LOCAL_HOST_ID => id,
            Some(_) => {
                self.wait_store().await;
                return;
            }
            None => key,
        };
        if uuid::Uuid::parse_str(id).is_err() {
            self.wait_store().await;
            return;
        }
        let (hub, id) = (self.clone(), id.to_owned());
        let installed = tokio::task::spawn_blocking(move || {
            if hub
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains_key(&id)
            {
                return true;
            }
            let Ok(Some(meta)) = hub.store.load_startup(&id) else {
                return false;
            };
            // A deleted chat stays out of the map: the whole read holds it (`soft_delete.rs`).
            if meta.id != id
                || super::soft_delete::deleted_until(&meta).is_some()
                || (meta.permission_policy.is_some() && meta.policy_source.is_none())
            {
                return false;
            }
            // Unknown liveness is kept for adoption; it never turns a possibly running turn
            // into a lost one. The full pass makes the same conservative choice.
            let hosted = Self::read_live_host_sessions().is_none_or(|h| h.contains(&id));
            {
                let mut plan = hub.load_plan.lock().unwrap_or_else(|e| e.into_inner());
                if hosted {
                    plan.hosted.insert(id.clone());
                    plan.adopting.insert(id.clone());
                }
                if meta.status == SessionStatus::Waiting {
                    plan.waiting.insert(id.clone());
                }
            }
            hub.install_stored_session(meta, true, hosted, true);
            true
        })
        .await
        .unwrap_or(false);
        if !installed {
            self.wait_store().await;
        }
    }

    /// Read-only chat requests can paint while the rest of the index loads. Mutations and
    /// list/name resolution need its complete ownership and ancestry information.
    pub(crate) async fn prepare_store_request(self: &Arc<Self>, method: &str, params: &Value) {
        use crate::rpc::method::*;
        if self.store_loaded() {
            return;
        }
        match method {
            // Terminal history reads the harness's own file, even if the acpmux event store or
            // device chat index is still loading after an app restart.
            INITIALIZE
            | MUX_STATUS
            | MUX_PERSON_ENROLL
            | MUX_PERSON_PROVE
            | MUX_CHAT_TRANSCRIPT_PAGE
            | MUX_CHAT_TRANSCRIPT_FIND => {}
            MUX_ATTACH | MUX_INFO | MUX_EVENTS => {
                if let Ok(key) = crate::server::session_key(params) {
                    self.session_meta(key).await;
                }
            }
            _ => self.wait_store().await,
        }
    }

    pub(crate) fn loading_status(&self) -> Value {
        let loaded = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len();
        let total = self.store_load.total.load(Ordering::SeqCst).max(loaded);
        let phase = if !self.store_loaded() {
            "loading-store"
        } else if !*self.adoption_ready.borrow() {
            "adopting"
        } else if !self.logs_loaded() {
            "loading-logs"
        } else if !self.startup_complete() {
            "starting-agents"
        } else {
            "ready"
        };
        let startup_done = *self.startup_work_done.borrow();
        json!({"phase": phase, "sessionsLoaded": loaded, "sessionsTotal": total,
               "startupDone": startup_done})
    }

    /// The daemon's startup task runs (`daemon.rs`) until [`Hub::end_startup_work`].
    pub(crate) fn begin_startup_work(&self) {
        self.startup_work_done.send_replace(false);
    }

    /// The daemon's startup task ended: `_acpmux/status` `loading.startupDone`.
    pub(crate) fn end_startup_work(&self) {
        self.startup_work_done.send_replace(true);
    }
}
