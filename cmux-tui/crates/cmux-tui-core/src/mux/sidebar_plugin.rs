//! Sidebar plugin: configuration, ensure/reload of the plugin surface, its status, and the resource resize of the sidebar.

use super::*;

impl Mux {
    pub fn configure_sidebar_plugin(&self, options: Option<SidebarPluginOptions>) {
        let old_surface = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            if runtime.options == options {
                return;
            }
            runtime.options = options;
            runtime.last_error = None;
            runtime.failures = 0;
            runtime.retry_at = None;
            runtime.surface.take()
        };
        if let Some(surface) =
            old_surface.and_then(|id| self.state.lock().unwrap().surfaces.remove(&id))
        {
            surface.kill();
            self.emit(MuxEvent::SurfaceExited(surface.id));
        }
    }

    pub fn ensure_sidebar_plugin(
        self: &Arc<Self>,
        cols: u16,
        rows: u16,
        relaunch: bool,
    ) -> SidebarPluginStatus {
        let now = Instant::now();
        let size = (cols.max(1), rows.max(1));
        let spawn_options = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            let Some(options) = runtime.options.clone() else {
                return SidebarPluginStatus { surface: None, error: None, retry_after: None };
            };
            runtime.last_size = Some(size);
            if let Some(surface_id) = runtime.surface {
                if let Some(surface) = self.surface(surface_id).filter(|surface| !surface.is_dead())
                {
                    drop(runtime);
                    let _ = self.resize_surface(surface_id, size.0, size.1);
                    drop(surface);
                    return SidebarPluginStatus {
                        surface: Some(surface_id),
                        error: None,
                        retry_after: None,
                    };
                }
                runtime.surface = None;
            }
            if let Some(error) = runtime.last_error.clone() {
                let retry_after = runtime.retry_at.and_then(|retry_at| {
                    (retry_at > now).then_some(retry_at.saturating_duration_since(now))
                });
                if !relaunch || retry_after.is_some() {
                    return SidebarPluginStatus { surface: None, error: Some(error), retry_after };
                }
            }
            options
        };
        match self.spawn_sidebar_plugin_surface(&spawn_options, size) {
            Ok(surface) => {
                let surface_id = surface.id;
                {
                    let mut runtime = self.sidebar_plugin.lock().unwrap();
                    runtime.surface = Some(surface_id);
                    runtime.last_error = None;
                    runtime.failures = 0;
                    runtime.retry_at = None;
                }
                self.reap_if_dead(&surface);
                SidebarPluginStatus { surface: Some(surface_id), error: None, retry_after: None }
            }
            Err(err) => {
                let mut runtime = self.sidebar_plugin.lock().unwrap();
                runtime.surface = None;
                runtime.failures = runtime.failures.saturating_add(1);
                let delay = sidebar_retry_delay(runtime.failures);
                let message = format!("sidebar plugin failed to start: {err}");
                runtime.last_error = Some(message.clone());
                runtime.retry_at = Some(now + delay);
                SidebarPluginStatus {
                    surface: None,
                    error: Some(message),
                    retry_after: Some(delay),
                }
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn sidebar_plugin_status(&self) -> SidebarPluginStatus {
        let runtime = self.sidebar_plugin.lock().unwrap();
        let now = Instant::now();
        let surface = runtime
            .surface
            .filter(|surface| self.surface(*surface).is_some_and(|surface| !surface.is_dead()));
        SidebarPluginStatus {
            surface,
            error: runtime.last_error.clone(),
            retry_after: runtime
                .retry_at
                .and_then(|retry_at| (retry_at > now).then(|| retry_at.duration_since(now))),
        }
    }

    pub(crate) fn sidebar_plugin_surface(&self) -> Option<Arc<Surface>> {
        let surface = self.sidebar_plugin.lock().unwrap().surface?;
        self.surface(surface)
    }

    pub(crate) fn sidebar_plugin_resource_status(
        &self,
    ) -> (SidebarPluginStatus, Option<(u16, u16)>, bool) {
        let runtime = self.sidebar_plugin.lock().unwrap();
        let now = Instant::now();
        let surface = runtime
            .surface
            .filter(|surface| self.surface(*surface).is_some_and(|surface| !surface.is_dead()));
        (
            SidebarPluginStatus {
                surface,
                error: runtime.last_error.clone(),
                retry_after: runtime
                    .retry_at
                    .and_then(|retry_at| (retry_at > now).then(|| retry_at.duration_since(now))),
            },
            runtime.last_size,
            runtime.options.is_some(),
        )
    }

    pub(crate) fn reload_sidebar_plugin(
        self: &Arc<Self>,
        cols: u16,
        rows: u16,
    ) -> SidebarPluginStatus {
        let old_surface = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            runtime.last_size = Some((cols.max(1), rows.max(1)));
            runtime.last_error = None;
            runtime.failures = 0;
            runtime.retry_at = None;
            runtime.surface.take()
        };
        if let Some(surface) =
            old_surface.and_then(|id| self.state.lock().unwrap().surfaces.remove(&id))
        {
            self.purge_surface_side_tables(surface.id);
            surface.kill();
            self.emit(MuxEvent::SurfaceExited(surface.id));
        }
        self.ensure_sidebar_plugin(cols, rows, true)
    }

    pub(crate) fn resource_resize_sidebar_selected(
        &self,
        selectors: crate::ResourceSelectors,
        sidebar_id: &SidebarViewPublicId,
        cols: u16,
        rows: u16,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let fingerprint = serde_json::json!({
            "operation":"sidebar_view.resize",
            "selectors":selectors,
            "sidebar_view":sidebar_id,
            "cols":cols,
            "rows":rows,
        });
        if let Some(replay) = self.workspace_registry.lock().unwrap().replay_resource_patch(
            mutation,
            "sidebar_view.resize",
            &fingerprint,
        )? {
            return Ok(replay);
        }
        let raw = selectors.sidebar_view.as_deref().ok_or_else(|| {
            anyhow::Error::new(ResourceError::selector_invalid(
                "sidebar_view",
                "<missing>",
                "missing required sidebar_view selector",
            ))
        })?;
        match Selector::parse(raw).map_err(anyhow::Error::new)? {
            Selector::Current => {}
            Selector::Id(id) if id == sidebar_id.as_str() => {}
            Selector::Name(name) if matches!(name.as_str(), "sidebar" | "default") => {}
            Selector::Id(_) | Selector::Name(_) => {
                return Err(anyhow::Error::new(ResourceError::not_found("sidebar_view", raw)));
            }
        }
        let mut runtime = self.sidebar_plugin.lock().unwrap();
        anyhow::ensure!(runtime.options.is_some(), "sidebar view is not configured");
        let surface_id = runtime.surface.context("sidebar view is not running")?;
        let surface = self
            .state
            .lock()
            .unwrap()
            .surfaces
            .get(&surface_id)
            .cloned()
            .context("sidebar view surface disappeared")?;
        anyhow::ensure!(!surface.is_dead(), "sidebar view is not running");
        let mut session_selectors = selectors.clone();
        session_selectors.sidebar_view = None;
        let sidebar_id = sidebar_id.clone();
        let commit = self.commit_resource_mutation_plan(
            mutation,
            "sidebar_view.resize",
            &fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                self.resolve_resource_path_in_state(
                    state,
                    registry,
                    crate::ResourceTarget::Session,
                    &session_selectors,
                )
                .map_err(anyhow::Error::new)?;
                let value = serde_json::json!({
                    "id":sidebar_id,
                    "session_id":registry.session_id(),
                    "cols":cols,
                    "rows":rows,
                    "running":true,
                });
                let deltas = serde_json::json!([{
                    "kind":"upsert",
                    "sequence":0,
                    "resource":"sidebar_view",
                    "id":sidebar_id,
                    "value":value,
                }]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: Vec::new() },
                    value,
                    deltas,
                    move |_state| {
                        let _ = surface.resize(cols, rows);
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries: 0,
                    terminal_queries: 0,
                    changed_rows: 0,
                }))
            },
        )?;
        if !commit.replayed {
            runtime.last_size = Some((cols, rows));
        }
        Ok(commit)
    }
}
