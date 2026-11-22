//! Browser providers: the browser runtime, provider registration, provider surface reconciliation, browser bootstrap and provider surface restart.

use super::*;

impl Mux {
    pub(super) fn browser_runtime(&self) -> anyhow::Result<Arc<BrowserRuntime>> {
        let mut runtime = self.browser_runtime.lock().unwrap();
        if let Some(existing) = runtime.as_ref().filter(|existing| {
            !existing.is_closed() && existing.source() != crate::BrowserSource::Provider
        }) {
            return Ok(existing.clone());
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let created = BrowserRuntime::connect(&opts)?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    pub(crate) fn register_browser_provider(
        self: &Arc<Self>,
        client: u64,
        registration: BrowserProviderRegistration,
    ) -> anyhow::Result<BrowserProviderSnapshot> {
        let snapshot = self.browser_providers.register(client, registration)?;
        self.reconcile_provider_browser_surfaces();
        Ok(snapshot)
    }

    pub(crate) fn unregister_browser_provider(self: &Arc<Self>, client: u64) -> bool {
        let removed = self.browser_providers.unregister(client);
        if removed {
            self.reconcile_provider_browser_surfaces();
        }
        removed
    }

    pub(crate) fn browser_provider_snapshot(&self) -> Option<BrowserProviderSnapshot> {
        self.browser_providers.snapshot()
    }

    pub(super) fn reconcile_provider_browser_surfaces(self: &Arc<Self>) {
        let surfaces = {
            let state = self.state.lock().unwrap();
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
        let mut runtime = self.browser_runtime.lock().unwrap();
        if let Some(existing) = runtime.as_ref().filter(|existing| {
            !existing.is_closed()
                && existing.matches_provider(&lease.endpoint, &lease.authentication)
        }) {
            return Ok(existing.clone());
        }
        let created = BrowserRuntime::connect_provider(&lease.endpoint, &lease.authentication)?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    pub(super) fn start_browser_bootstrap(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        runtime: Option<Arc<BrowserRuntime>>,
    ) {
        let provider_bootstrap = matches!(&bootstrap, BrowserBootstrap::Provider { .. });
        // The frontend renders this page itself; the daemon never waits for
        // or attaches a CDP target for it.
        if provider_bootstrap && self.is_frontend_browser_surface(&surface) {
            return;
        }
        let weak_mux = Arc::downgrade(self);
        let providers = self.browser_providers.clone();
        let id = surface.id;
        let thread_surface = surface.clone();
        let spawn = std::thread::Builder::new()
            .name(format!("browser-surface-{id}-bootstrap"))
            .spawn(move || {
                let result = (|| -> anyhow::Result<()> {
                    match bootstrap {
                        BrowserBootstrap::Provider { tab_id, url } => {
                            anyhow::ensure!(
                                runtime.is_none(),
                                "provider bootstrap cannot override its CDP runtime"
                            );
                            let mut retry_delay = Duration::from_millis(250);
                            loop {
                                let canceled = || {
                                    thread_surface.is_dead()
                                        || weak_mux.upgrade().is_none_or(|mux| {
                                            mux.shutting_down.load(Ordering::Acquire)
                                        })
                                };
                                let lease =
                                    providers.wait_for_target(&tab_id, canceled).ok_or_else(
                                        || anyhow::anyhow!("browser provider wait was canceled"),
                                    )?;
                                let attempt = (|| -> anyhow::Result<()> {
                                    let mux = weak_mux.upgrade().ok_or_else(|| {
                                        anyhow::anyhow!("browser mux was dropped")
                                    })?;
                                    let runtime = mux.browser_runtime_for_provider(&lease)?;
                                    let Surface::Browser(browser) = thread_surface.as_ref() else {
                                        anyhow::bail!(
                                            "browser bootstrap got a non-browser surface"
                                        );
                                    };
                                    anyhow::ensure!(
                                        browser.prepare_provider_bootstrap_attempt(),
                                        "browser provider wait was canceled"
                                    );
                                    runtime.bootstrap_surface_sync(
                                        thread_surface.clone(),
                                        BrowserBootstrap::ExistingTarget {
                                            target_id: lease.target_id.clone(),
                                            url: url.clone(),
                                        },
                                        weak_mux.clone(),
                                    )
                                })();
                                match attempt {
                                    Ok(()) => {
                                        let current_lease = providers.target(&tab_id);
                                        let Surface::Browser(browser) = thread_surface.as_ref()
                                        else {
                                            anyhow::bail!(
                                                "browser bootstrap got a non-browser surface"
                                            );
                                        };
                                        // Registration can change while CDP
                                        // setup is in flight. Never publish a
                                        // now-stale target merely because its
                                        // attach finished after the provider
                                        // revision advanced.
                                        if browser.prepare_provider_lease_replacement(
                                            current_lease.as_ref(),
                                        ) {
                                            retry_delay = Duration::from_millis(250);
                                            continue;
                                        }
                                        return Ok(());
                                    }
                                    Err(error) if !canceled() => {
                                        let message = error.to_string();
                                        let Surface::Browser(browser) = thread_surface.as_ref()
                                        else {
                                            return Err(error);
                                        };
                                        let changed = browser.status()
                                            != crate::BrowserStatus::Failed(message.clone());
                                        if changed {
                                            browser.mark_failed(message.clone());
                                            if let Some(mux) = weak_mux.upgrade() {
                                                mux.emit(MuxEvent::Status(format!(
                                                    "cmux-browser provider unavailable: {message}"
                                                )));
                                                mux.emit(MuxEvent::TitleChanged {
                                                    surface: id,
                                                    title: thread_surface.title().into(),
                                                });
                                                mux.emit(MuxEvent::SurfaceOutput(id));
                                            }
                                        }
                                        if !providers.wait_for_revision_change(
                                            lease.revision,
                                            canceled,
                                            retry_delay,
                                        ) {
                                            anyhow::bail!("browser provider wait was canceled");
                                        }
                                        retry_delay = retry_delay
                                            .saturating_mul(2)
                                            .min(Duration::from_secs(2));
                                    }
                                    Err(error) => return Err(error),
                                }
                            }
                        }
                        bootstrap => {
                            let mux = weak_mux
                                .upgrade()
                                .ok_or_else(|| anyhow::anyhow!("browser mux was dropped"))?;
                            let runtime = match runtime {
                                Some(runtime) => runtime,
                                None => mux.browser_runtime()?,
                            };
                            runtime.bootstrap_surface_sync(
                                thread_surface.clone(),
                                bootstrap,
                                weak_mux.clone(),
                            )
                        }
                    }
                })();
                if let Err(err) = result {
                    if !thread_surface.is_dead()
                        && !provider_bootstrap
                        && let Surface::Browser(browser) = thread_surface.as_ref()
                    {
                        browser.abandon_attach(err.to_string());
                    }
                    if !provider_bootstrap
                        && let Some(mux) = weak_mux.upgrade()
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
            });
        if let Err(error) = spawn
            && !surface.is_dead()
            && let Surface::Browser(browser) = surface.as_ref()
        {
            browser.abandon_attach(format!("could not start browser bootstrap: {error}"));
        }
    }

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
