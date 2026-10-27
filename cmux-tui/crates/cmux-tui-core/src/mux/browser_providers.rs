//! Browser providers: the browser runtime, provider registration, provider surface reconciliation, browser bootstrap (a provider tab's as a lane of the browser pool) and provider surface restart.

use super::*;
use crate::browser::{LaneHandle, LaneTask, LaneTurn};
use crate::browser_provider::ProviderWatch;
use crate::panic_free::RecoverPoison;

impl Mux {
    pub(super) fn browser_runtime(&self) -> anyhow::Result<Arc<BrowserRuntime>> {
        let mut runtime = self.browser_runtime.lock().recover_poison();
        if let Some(existing) = runtime.as_ref().filter(|existing| {
            !existing.is_closed() && existing.source() != crate::BrowserSource::Provider
        }) {
            return Ok(existing.clone());
        }
        let opts = self.surface_options.lock().recover_poison().clone();
        let created = BrowserRuntime::connect(&opts)?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    #[track_caller]
    pub(crate) fn register_browser_provider(
        self: &Arc<Self>,
        client: u64,
        registration: BrowserProviderRegistration,
    ) -> anyhow::Result<BrowserProviderSnapshot> {
        let snapshot = self.browser_providers.register(client, registration)?;
        self.reconcile_provider_browser_surfaces();
        Ok(snapshot)
    }

    #[track_caller]
    pub(crate) fn unregister_browser_provider(self: &Arc<Self>, client: u64) -> bool {
        let removed = self.browser_providers.unregister(client);
        if removed {
            self.reconcile_provider_browser_surfaces();
        }
        removed
    }

    /// The registry a browser surface wakes when it dies (see
    /// [`BrowserProviderRegistry::wake_waiters`]).
    pub(crate) fn browser_provider_registry(&self) -> Arc<BrowserProviderRegistry> {
        self.browser_providers.clone()
    }

    /// The pool browser surface lanes run on.
    pub(crate) fn browser_lanes(&self) -> browser::LanePool {
        self.browser_lanes.pool().clone()
    }

    pub(crate) fn browser_provider_snapshot(&self) -> Option<BrowserProviderSnapshot> {
        self.browser_providers.snapshot()
    }

    /// The refusal a daemon-rendered browser gets while no cmux-browser
    /// provider is attached (cx-r9ix). Only a provider publishes the CDP
    /// target such a tab attaches to, and the daemon launches no browser
    /// (cx-2u5k), so without one the tab would stay `starting` for good, as in
    /// a headless Cloud session. `None` while a provider is attached.
    pub(crate) fn browser_engine_unavailable(&self, operation: &str) -> Option<ResourceError> {
        if self.browser_provider_snapshot().is_some() {
            return None;
        }
        Some(ResourceError::operation_failed(
            operation,
            "no browser engine: neither the cmux app nor a cmux-browser provider is attached to this session, so a browser tab cannot start; open the cmux app (it renders browser tabs for every session it shows), or launch cmux-browser",
            serde_json::json!({"code":"engine_unavailable"}),
        ))
    }

    /// A stand-in cmux-browser provider for `client` that publishes no
    /// target: daemon-rendered tabs wait for theirs, as with a live provider.
    #[cfg(test)]
    #[track_caller]
    pub(crate) fn attach_test_browser_provider(self: &Arc<Self>, client: u64) {
        self.register_browser_provider(
            client,
            BrowserProviderRegistration {
                provider_id: "test-provider".to_string(),
                endpoint: "ws://127.0.0.1:9/devtools/browser/test".to_string(),
                authentication: crate::browser_provider::BrowserProviderAuthentication::None,
                hosting: Default::default(),
                targets: Default::default(),
            },
        )
        .unwrap();
    }

    #[track_caller]
    pub(super) fn reconcile_provider_browser_surfaces(self: &Arc<Self>) {
        let surfaces = {
            let state = self.state.lock().recover_poison();
            state
                .surfaces
                .values()
                .filter_map(|surface| {
                    let identity = surface.resource_identity()?;
                    matches!(&identity.content_id, ContentPublicId::Browser(_))
                        .then(|| (surface.clone(), identity.tab_id.clone()))
                })
                .collect::<Vec<_>>()
        };
        for (surface, tab_id) in surfaces {
            let lease = self.browser_providers.target(&tab_id);
            let Surface::Browser(browser) = surface.as_ref() else { continue };
            if browser.prepare_provider_lease_replacement(lease.as_ref()) {
                self.restart_provider_browser_surface(surface);
            }
        }
    }

    pub(super) fn browser_runtime_for_provider(
        &self,
        lease: &BrowserProviderTargetLease,
    ) -> anyhow::Result<Arc<BrowserRuntime>> {
        let mut runtime = self.browser_runtime.lock().recover_poison();
        if let Some(existing) = runtime.as_ref().filter(|existing| {
            !existing.is_closed()
                && existing.matches_provider(&lease.endpoint, &lease.authentication, lease.hosting)
        }) {
            return Ok(existing.clone());
        }
        let created = BrowserRuntime::connect_provider(
            &lease.endpoint,
            &lease.authentication,
            lease.hosting,
        )?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    #[track_caller]
    pub(super) fn start_browser_bootstrap(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        runtime: Option<Arc<BrowserRuntime>>,
    ) {
        if let BrowserBootstrap::Provider { tab_id, url } = bootstrap {
            // The frontend renders this page itself; the daemon never waits
            // for or attaches a CDP target for it, so it is live now.
            if self.is_frontend_browser_surface(&surface) {
                surface.mark_browser_frontend_rendered();
                return;
            }
            // A provider bootstrap's CDP runtime is the provider's own.
            if runtime.is_some() {
                return;
            }
            // It waits, with no bound, for the provider to publish the
            // tab's target and retries until the surface dies: a lane on the
            // browser pool that parks in the registry between tries, never a
            // thread of its own (p01-process-206).
            let lane = self.browser_lanes().reserve();
            lane.start(ProviderBootstrap {
                surface,
                mux: Arc::downgrade(self),
                providers: self.browser_providers.clone(),
                key: self.browser_providers.watcher_key(),
                tab_id,
                url,
                lane: lane.clone(),
                retry_delay: PROVIDER_RETRY_INITIAL,
                backoff: None,
            });
            lane.wake();
            return;
        }
        let weak_mux = Arc::downgrade(self);
        let id = surface.id;
        let thread_surface = surface.clone();
        // Any other bootstrap is one CDP attach: a request wait
        // (`server/request_wait.rs`).
        let run = move || {
            let result = (|| -> anyhow::Result<()> {
                let mux =
                    weak_mux.upgrade().ok_or_else(|| anyhow::anyhow!("browser mux was dropped"))?;
                let runtime = match runtime {
                    Some(runtime) => runtime,
                    None => mux.browser_runtime()?,
                };
                runtime.bootstrap_surface_sync(thread_surface.clone(), bootstrap, weak_mux.clone())
            })();
            if let Err(err) = result {
                if !thread_surface.is_dead()
                    && let Surface::Browser(browser) = thread_surface.as_ref()
                {
                    browser.abandon_attach(err.to_string());
                }
                if let Some(mux) = weak_mux.upgrade()
                    && !thread_surface.is_dead()
                {
                    mux.emit(MuxEvent::Status(format!("browser failed: {err}")));
                    mux.emit(MuxEvent::TitleChanged {
                        surface: id,
                        title: thread_surface.title().into(),
                    });
                    mux.emit(MuxEvent::SurfaceOutput(id));
                }
            }
        };
        if self.post_request_wait(run).is_err()
            && !surface.is_dead()
            && let Surface::Browser(browser) = surface.as_ref()
        {
            browser.abandon_attach("could not start browser bootstrap: shutting down".to_owned());
        }
    }

    #[track_caller]
    pub(crate) fn restart_provider_browser_surface(self: &Arc<Self>, surface: Arc<Surface>) {
        let Some(identity) = surface.resource_identity() else { return };
        if !matches!(identity.content_id, ContentPublicId::Browser(_)) {
            return;
        }
        let tab_id = identity.tab_id.clone();
        let url = surface.browser_url().unwrap_or_else(|| "about:blank".to_string());
        self.start_browser_bootstrap(surface, BrowserBootstrap::Provider { tab_id, url }, None);
    }
}

const PROVIDER_RETRY_INITIAL: Duration = Duration::from_millis(250);
const PROVIDER_RETRY_MAX: Duration = Duration::from_secs(2);

/// A provider tab's bootstrap, as a lane: each turn attaches the tab once
/// its target is published, or parks (in the provider registry, or until a
/// retry deadline) and returns. It ends once the tab is attached to the
/// current target, or the surface or the mux is gone.
struct ProviderBootstrap {
    surface: Arc<Surface>,
    mux: Weak<Mux>,
    providers: Arc<BrowserProviderRegistry>,
    /// Its watcher's key in `providers`.
    key: u64,
    tab_id: TabPublicId,
    url: String,
    lane: LaneHandle,
    retry_delay: Duration,
    /// After a failed attach: the revision it used, and when to try again
    /// if the registrations do not change first.
    backoff: Option<(u64, Instant)>,
}

impl LaneTask for ProviderBootstrap {
    fn run(&mut self) -> LaneTurn {
        loop {
            // Read before the cancel check: a wake raised after it (the
            // check may drop the last `Arc<Mux>`) moves it, so the watch
            // below reports it instead of parking past it.
            let seen = self.providers.generation();
            if self.canceled() {
                return self.finish();
            }
            if let Some((revision, retry_at)) = self.backoff {
                if seen.0 != revision || Instant::now() >= retry_at {
                    self.backoff = None;
                    continue;
                }
                let lane = self.lane.clone();
                match self.providers.watch(None, seen, self.key, move || lane.wake()) {
                    ProviderWatch::Parked => return LaneTurn::WakeAt(retry_at),
                    ProviderWatch::Target(_) | ProviderWatch::Moved => continue,
                }
            }
            let lane = self.lane.clone();
            let lease =
                match self.providers.watch(Some(&self.tab_id), seen, self.key, move || lane.wake())
                {
                    ProviderWatch::Target(lease) => lease,
                    ProviderWatch::Moved => continue,
                    ProviderWatch::Parked => return LaneTurn::Idle,
                };
            let Surface::Browser(browser) = self.surface.as_ref() else {
                return self.finish();
            };
            match self.attempt(&lease) {
                Ok(()) => {
                    // Registration can change while CDP setup is in flight.
                    // Never publish a now-stale target merely because its
                    // attach finished after the provider revision advanced.
                    let current_lease = self.providers.target(&self.tab_id);
                    if browser.prepare_provider_lease_replacement(current_lease.as_ref()) {
                        self.retry_delay = PROVIDER_RETRY_INITIAL;
                        continue;
                    }
                    return self.finish();
                }
                Err(error) if !self.canceled() => {
                    let message = error.to_string();
                    if browser.status() != crate::BrowserStatus::Failed(message.clone()) {
                        browser.mark_failed(message.clone());
                        if let Some(mux) = self.mux.upgrade() {
                            let id = self.surface.id;
                            mux.emit(MuxEvent::Status(format!(
                                "cmux-browser provider unavailable: {message}"
                            )));
                            mux.emit(MuxEvent::TitleChanged {
                                surface: id,
                                title: self.surface.title().into(),
                            });
                            mux.emit(MuxEvent::SurfaceOutput(id));
                        }
                    }
                    self.backoff = Some((lease.revision, Instant::now() + self.retry_delay));
                    self.retry_delay = self.retry_delay.saturating_mul(2).min(PROVIDER_RETRY_MAX);
                }
                Err(_) => return self.finish(),
            }
        }
    }
}

impl ProviderBootstrap {
    fn canceled(&self) -> bool {
        self.surface.is_dead()
            || self.mux.upgrade().is_none_or(|mux| mux.shutting_down.load(Ordering::Acquire))
    }

    fn attempt(&self, lease: &BrowserProviderTargetLease) -> anyhow::Result<()> {
        let mux = self.mux.upgrade().ok_or_else(|| anyhow::anyhow!("browser mux was dropped"))?;
        let runtime = mux.browser_runtime_for_provider(lease)?;
        let Surface::Browser(browser) = self.surface.as_ref() else {
            anyhow::bail!("browser bootstrap got a non-browser surface");
        };
        anyhow::ensure!(
            browser.prepare_provider_bootstrap_attempt(),
            "browser provider wait was canceled"
        );
        runtime.bootstrap_surface_sync(
            self.surface.clone(),
            BrowserBootstrap::ExistingTarget {
                target_id: lease.target_id.clone(),
                url: self.url.clone(),
            },
            self.mux.clone(),
        )
    }

    fn finish(&self) -> LaneTurn {
        self.providers.unwatch(self.key);
        LaneTurn::Done
    }
}
