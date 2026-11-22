//! Shared CDP runtime: endpoint connection, surface creation, the event
//! router that feeds per-surface routes, and runtime shutdown.

use super::*;

impl BrowserRuntime {
    pub fn connect(opts: &SurfaceOptions) -> anyhow::Result<Arc<Self>> {
        let (web_socket_url, source) = runtime_endpoint(opts)?;
        Self::connect_to_endpoint(&web_socket_url, source)
    }

    pub(crate) fn connect_provider(
        endpoint: &str,
        authentication: &BrowserProviderAuthentication,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_to_endpoint_with_bearer(
            endpoint,
            BrowserSource::Provider,
            authentication.bearer_token(),
        )
    }

    pub(super) fn connect_to_endpoint(
        web_socket_url: &str,
        source: BrowserSource,
    ) -> anyhow::Result<Arc<Self>> {
        Self::connect_to_endpoint_with_bearer(web_socket_url, source, None)
    }

    pub(super) fn connect_to_endpoint_with_bearer(
        web_socket_url: &str,
        source: BrowserSource,
        bearer_token: Option<&str>,
    ) -> anyhow::Result<Arc<Self>> {
        let (event_tx, event_rx) = sync_channel(CDP_EVENT_QUEUE_CAPACITY);
        let client = CdpClient::connect_with_bearer(web_socket_url, bearer_token, event_tx)?;
        let stealth_user_agent = if source == BrowserSource::Launched {
            client.browser_version().ok().and_then(|ua| clean_headless_user_agent(&ua))
        } else {
            None
        };
        let runtime = Arc::new(BrowserRuntime {
            client,
            source,
            endpoint: web_socket_url.to_string(),
            bearer_token: bearer_token.map(str::to_string),
            stealth_user_agent,
            routes: Mutex::new(Routes::default()),
            closed: AtomicBool::new(false),
        });
        start_router(Arc::downgrade(&runtime), event_rx)?;
        runtime.client.set_discover_targets(true)?;
        Ok(runtime)
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    pub fn source(&self) -> BrowserSource {
        self.source
    }

    pub(crate) fn matches_provider(
        &self,
        endpoint: &str,
        authentication: &BrowserProviderAuthentication,
    ) -> bool {
        self.source == BrowserSource::Provider
            && self.endpoint == endpoint
            && self.bearer_token.as_deref() == authentication.bearer_token()
    }

    pub(crate) fn bootstrap_surface_sync(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        mux: Weak<Mux>,
    ) -> anyhow::Result<()> {
        if self.is_closed() {
            anyhow::bail!("CDP browser connection is closed");
        }
        let (target_id, normalized_url) = match bootstrap {
            BrowserBootstrap::ExistingTarget { target_id, url } => (target_id, normalize_url(&url)),
            BrowserBootstrap::Provider { .. } => {
                anyhow::bail!("browser provider target was not resolved before CDP bootstrap")
            }
        };
        let session_id = self.client.attach_to_target(&target_id)?;
        let events = self.register(&target_id, &session_id);
        if surface.as_browser().is_none() {
            self.release_bootstrap_session(&target_id, &session_id);
            anyhow::bail!("browser bootstrap got a non-browser surface");
        }
        let setup_result =
            self.setup_attached_surface(&surface, &target_id, &session_id, &normalized_url);
        if let Err(err) = setup_result {
            self.release_bootstrap_session(&target_id, &session_id);
            return Err(err);
        }

        start_surface_thread(surface, events, mux, Arc::downgrade(self), session_id)?;
        Ok(())
    }

    pub(super) fn setup_attached_surface(
        self: &Arc<Self>,
        surface: &Arc<Surface>,
        target_id: &str,
        session_id: &str,
        normalized_url: &str,
    ) -> anyhow::Result<()> {
        let Surface::Browser(browser) = surface.as_ref() else {
            anyhow::bail!("browser bootstrap got a non-browser surface");
        };
        if browser.is_dead() {
            anyhow::bail!("browser surface was closed before it started");
        }
        self.client.register_frame_epoch(session_id, browser.frame_epoch.clone());
        if let Some(user_agent) = self.stealth_user_agent.as_deref() {
            let _ = self.client.set_user_agent(session_id, user_agent);
        }
        self.client.page_enable(session_id)?;
        self.client.set_lifecycle_events_enabled(session_id)?;
        self.client.seed_main_frame(session_id)?;
        let (pixel_w, pixel_h) = browser.pixel_size();
        self.client.set_device_metrics(session_id, pixel_w, pixel_h)?;
        self.client.start_screencast(session_id, pixel_w, pixel_h)?;
        if browser.is_dead() {
            anyhow::bail!("browser surface was closed before it started");
        }
        let session_id = session_id.to_string();
        let target_id = target_id.to_string();
        browser.attach_live(
            BrowserSession { runtime: self.clone(), target_id, session_id },
            normalized_url,
        )
    }

    pub(super) fn register(&self, target_id: &str, session_id: &str) -> Arc<SurfaceRoute> {
        let route = Arc::new(SurfaceRoute::new());
        let mut routes = self.routes.lock().unwrap();
        if self.closed.load(Ordering::Acquire) {
            drop(routes);
            route.close("browser runtime closed".to_string());
            return route;
        }
        routes.by_session.insert(session_id.to_string(), route.clone());
        routes.by_target.insert(target_id.to_string(), route.clone());
        route
    }

    pub(super) fn unregister(&self, target_id: &str, session_id: &str) {
        self.client.unregister_frame_epoch(session_id);
        let route = {
            let mut routes = self.routes.lock().unwrap();
            let by_session = routes.by_session.remove(session_id);
            let by_target = routes.by_target.remove(target_id);
            by_session.or(by_target)
        };
        if let Some(route) = route {
            route.close("browser surface closed".to_string());
        }
    }

    pub(super) fn remove_route(&self, route: &Arc<SurfaceRoute>) {
        let mut routes = self.routes.lock().unwrap();
        routes.by_session.retain(|_, candidate| !Arc::ptr_eq(candidate, route));
        routes.by_target.retain(|_, candidate| !Arc::ptr_eq(candidate, route));
    }

    pub(super) fn close_surface_detached(&self, target_id: &str, session_id: &str) {
        self.unregister(target_id, session_id);
        if self.is_closed() {
            return;
        }
        if self.source == BrowserSource::Provider {
            let _ = self.client.detach_from_target_detached(session_id);
        } else {
            let _ = self.client.close_target_detached(target_id);
        }
    }

    pub(super) fn release_bootstrap_session(&self, target_id: &str, session_id: &str) {
        self.unregister(target_id, session_id);
        if self.is_closed() {
            return;
        }
        if self.source == BrowserSource::Provider {
            let _ = self.client.detach_from_target_detached(session_id);
        } else {
            let _ = self.client.close_target(target_id);
        }
    }

    pub fn shutdown(&self) {
        close_browser_runtime(self, "browser runtime shut down".to_string());
        let _ = self.client.flush_outbound(Duration::from_secs(1));
    }
}

pub(crate) fn new_surface(
    id: SurfaceId,
    url: String,
    size: (u16, u16),
    cell_pixels: (u16, u16),
    opts: &SurfaceOptions,
    mux: Weak<Mux>,
) -> anyhow::Result<Arc<Surface>> {
    new_surface_with_resource_identity(
        id,
        url,
        size,
        cell_pixels,
        opts,
        mux,
        TabResourceIdentity::browser()?,
    )
}

pub(crate) fn new_surface_with_resource_identity(
    id: SurfaceId,
    url: String,
    size: (u16, u16),
    cell_pixels: (u16, u16),
    opts: &SurfaceOptions,
    mux: Weak<Mux>,
    resource_identity: TabResourceIdentity,
) -> anyhow::Result<Arc<Surface>> {
    if !matches!(resource_identity.content_id, crate::resource::ContentPublicId::Browser(_)) {
        anyhow::bail!("browser surface cannot use a terminal resource identity");
    }
    let normalized_url = normalize_url(&url);
    let (cols, rows) = (size.0.max(1), size.1.max(1));
    let (cell_w, cell_h) = (cell_pixels.0.max(1), cell_pixels.1.max(1));
    let pixel_w = cols as u32 * cell_w as u32;
    let pixel_h = rows as u32 * cell_h as u32;
    let capture_options = BrowserCaptureOptions::from_options(opts);
    let capture_scale = capture_scale_for(pixel_w, pixel_h, capture_options);
    let capture_pixels = scaled_pixels(pixel_w, pixel_h, capture_scale);
    let (command_tx, command_rx) = sync_channel(BROWSER_COMMAND_QUEUE_CAPACITY);
    let command_order = Arc::new(Mutex::new(BrowserCommandOrder::default()));
    let latest_nav = Arc::new(Mutex::new(None));
    let latest_authority = Arc::new(Mutex::new(None));
    let frame_epoch = Arc::new(FrameEpoch::default());
    #[cfg(test)]
    let (worker_done_tx, worker_done_rx) = std::sync::mpsc::channel();
    #[cfg(test)]
    let worker_done_tx = Some(worker_done_tx);
    #[cfg(not(test))]
    let worker_done_tx = None;
    let surface = Arc::new(Surface::Browser(BrowserSurface {
        meta: SurfaceMeta {
            id,
            resource_identity: Some(resource_identity),
            name: Mutex::new(None),
            selection: Mutex::new(None),
        },
        session: Mutex::new(None),
        state: Mutex::new(Box::new(BrowserState {
            latest_frame: None,
            accepted_frame_epoch: frame_epoch.current(),
            accepted_navigation_epoch: frame_epoch.latest_navigation(),
            handled_navigation_epoch: frame_epoch.latest_navigation(),
            handled_same_document_navigation_epoch: frame_epoch.latest_same_document_navigation(),
            pending_frame_epoch: None,
            pending_navigation_epoch: None,
            pending_document_epoch: None,
            pending_authority_deadline: None,
            pending_same_document_navigation: false,
            pending_failure_recovery: false,
            pending_navigation_rollback: None,
            pending_screencast_capture: None,
            failed_screencast_capture_epoch: None,
            pending_frame: None,
            pointer_frame_seq: None,
            pointer_frame_floor_seq: None,
            presented_pointer_frames: HashMap::new(),
            pointer_frame_revision: 0,
            pointer_capture_generation: 0,
            pointer_motion_generation: 0,
            taps: Vec::new(),
            title: normalized_url.clone(),
            url: normalized_url,
            size: (cols, rows),
            pane_pixels: (pixel_w, pixel_h),
            capture_pixels,
            capture_scale,
            pending_reconfigures: VecDeque::new(),
            reconfigure_waiters: HashMap::new(),
            next_reconfigure_id: 1,
            reconfigure_failure: None,
            page_viewport: None,
            status: BrowserStatus::Starting,
            failure_kind: None,
            source: None,
            next_frame_seq: 1,
            live_since: None,
            last_frame_at: None,
            stall_nudged: false,
            not_responding_reported: false,
        })),
        frame_epoch,
        dirty: AtomicBool::new(true),
        dead: AtomicBool::new(false),
        cell_pixels: Mutex::new((cell_w, cell_h)),
        capture_options,
        command_tx: Mutex::new(Some(command_tx)),
        command_order: command_order.clone(),
        latest_nav: latest_nav.clone(),
        latest_authority: latest_authority.clone(),
        navigation_hold: Mutex::default(),
        #[cfg(test)]
        worker_done: Mutex::new(Some(worker_done_rx)),
        #[cfg(test)]
        navigation_commit_wait_timeouts: AtomicUsize::new(0),
    }));
    start_browser_worker(
        surface.clone(),
        command_rx,
        command_order,
        latest_nav,
        latest_authority,
        mux,
        worker_done_tx,
    );
    Ok(surface)
}

impl BrowserCaptureOptions {
    pub(super) fn from_options(opts: &SurfaceOptions) -> Self {
        let max_capture_megapixels = if opts.browser_max_capture_megapixels.is_finite()
            && opts.browser_max_capture_megapixels > 0.0
        {
            opts.browser_max_capture_megapixels
        } else {
            DEFAULT_CAPTURE_MEGAPIXELS
        }
        .min(TRANSPORT_SAFE_CAPTURE_MEGAPIXELS);
        let fixed_capture_scale = opts
            .browser_capture_scale
            .filter(|scale| scale.is_finite() && *scale > 0.0 && *scale <= 1.0);
        BrowserCaptureOptions { max_capture_megapixels, fixed_capture_scale }
    }
}

pub(super) fn browser_geometry_locked(state: &BrowserState) -> BrowserGeometry {
    BrowserGeometry {
        size: state.size,
        pane_pixels: state.pane_pixels,
        capture_pixels: state.capture_pixels,
        capture_scale: state.capture_scale,
    }
}

pub(super) fn capture_scale_for(
    pane_px_w: u32,
    pane_px_h: u32,
    opts: BrowserCaptureOptions,
) -> f64 {
    let area = f64::from(pane_px_w.max(1)) * f64::from(pane_px_h.max(1));
    let budget = opts.max_capture_megapixels.max(f64::MIN_POSITIVE) * 1_000_000.0;
    let budget_scale =
        if area <= budget { 1.0 } else { (budget / area).sqrt().clamp(f64::MIN_POSITIVE, 1.0) };
    opts.fixed_capture_scale.map_or(budget_scale, |scale| scale.min(budget_scale))
}

pub(super) fn scaled_pixels(pane_px_w: u32, pane_px_h: u32, scale: f64) -> (u32, u32) {
    let width = (f64::from(pane_px_w.max(1)) * scale).round().max(1.0) as u32;
    let height = (f64::from(pane_px_h.max(1)) * scale).round().max(1.0) as u32;
    (width, height)
}

pub(super) fn runtime_endpoint(opts: &SurfaceOptions) -> anyhow::Result<(String, BrowserSource)> {
    if let Ok(url) = std::env::var("CMUX_MUX_CDP_URL")
        && !url.trim().is_empty()
    {
        return Ok((resolve_browser_ws_url(&url)?, BrowserSource::External));
    }
    if let Some(url) = opts.cdp_url.as_deref().filter(|url| !url.trim().is_empty()) {
        return Ok((resolve_browser_ws_url(url)?, BrowserSource::External));
    }
    anyhow::bail!(
        "no cmux-browser provider is attached; launch cmux-browser or set CMUX_MUX_CDP_URL for an explicit development endpoint"
    )
}

pub(super) fn clean_headless_user_agent(user_agent: &str) -> Option<String> {
    user_agent.contains("HeadlessChrome").then(|| user_agent.replace("HeadlessChrome", "Chrome"))
}

pub(super) fn start_router(
    runtime: Weak<BrowserRuntime>,
    events: Receiver<CdpEvent>,
) -> anyhow::Result<()> {
    std::thread::Builder::new().name("browser-runtime-events".into()).spawn(move || {
        while let Ok(event) = events.recv() {
            let Some(runtime) = runtime.upgrade() else { break };
            match event {
                CdpEvent::ScreencastFrame(frame) => {
                    let tx = {
                        runtime.routes.lock().unwrap().by_session.get(&frame.session_id).cloned()
                    };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::ScreencastFrame(frame))
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::ScreencastFrameCaptureRequested {
                    session_id,
                    frame_id,
                    loader_id,
                    request_id,
                    frame_epoch,
                    navigation_epoch,
                } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::ScreencastFrameCaptureRequested {
                            session_id,
                            frame_id,
                            loader_id,
                            request_id,
                            frame_epoch,
                            navigation_epoch,
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::FrameNavigated { params, session_id, frame_epoch } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::FrameNavigated { params, session_id, frame_epoch })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::DocumentPainted { session_id, frame_id, loader_id, navigation_epoch } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::DocumentPainted {
                            session_id,
                            frame_id,
                            loader_id,
                            navigation_epoch,
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::NavigatedWithinDocument {
                    params,
                    session_id,
                    frame_id,
                    loader_id,
                    frame_epoch,
                } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::NavigatedWithinDocument {
                            params,
                            session_id,
                            frame_id,
                            loader_id,
                            frame_epoch,
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::TargetCreated(created) => {
                    let tx = created.opener_id.as_ref().and_then(|opener_id| {
                        runtime.routes.lock().unwrap().by_target.get(opener_id).cloned()
                    });
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::TargetCreated(created))
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::TargetInfoChanged(info) => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_target.get(&info.target_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::TargetInfoChanged(info))
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::Other { method, params, session_id: Some(session_id) } => {
                    let tx =
                        { runtime.routes.lock().unwrap().by_session.get(&session_id).cloned() };
                    if let Some(tx) = tx
                        && tx.deliver(CdpEvent::Other {
                            method,
                            params,
                            session_id: Some(session_id),
                        })
                    {
                        runtime.remove_route(&tx);
                    }
                }
                CdpEvent::Closed(reason) => {
                    close_browser_runtime(&runtime, reason);
                    break;
                }
                CdpEvent::Other { .. } => {}
            }
        }
        if let Some(runtime) = runtime.upgrade() {
            close_browser_runtime(&runtime, "CDP event channel closed".to_string());
        }
    })?;
    Ok(())
}

pub(super) fn close_browser_runtime(runtime: &BrowserRuntime, reason: String) {
    let senders = {
        let mut routes = runtime.routes.lock().unwrap();
        runtime.closed.store(true, Ordering::Release);
        let senders = routes.by_session.values().cloned().collect::<Vec<_>>();
        routes.by_session.clear();
        routes.by_target.clear();
        senders
    };
    for tx in senders {
        tx.close(reason.clone());
    }
}
