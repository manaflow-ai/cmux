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
    pub async fn load_store_async(self: &Arc<Self>) {
        let hub = self.clone();
        let result = tokio::task::spawn_blocking(move || {
            hub.load_from_store(true);
            // Before spawns are released, after the index is complete. This sweep must never
            // mistake the initially empty in-memory session map for an empty store.
            #[cfg(unix)]
            hub.sweep_session_tmp();
        })
        .await;
        if let Err(error) = result {
            tracing::error!("reading the session store failed: {error}");
        }
        self.watch_transfers();
        self.watch_orphans();
        self.store_load.ready.send_replace(true);
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
            if meta.id != id || (meta.permission_policy.is_some() && meta.policy_source.is_none()) {
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
            hub.install_stored_session(meta, true, hosted);
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
            INITIALIZE | MUX_STATUS | MUX_PERSON_ENROLL | MUX_PERSON_PROVE => {}
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
