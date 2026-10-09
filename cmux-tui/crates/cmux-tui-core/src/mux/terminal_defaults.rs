//! Terminal defaults and direct resizes: default colors and their durable override, the resource terminal defaults update, and resize_surface*.

use super::*;

impl Mux {
    pub fn default_colors(&self) -> DefaultColors {
        *self.default_colors.lock().unwrap()
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        let surfaces = {
            let state = self.state.lock().unwrap();
            let mut current = self.default_colors.lock().unwrap();
            if *current == colors {
                return;
            }
            *current = colors;
            unique_surface_runtimes(&state)
        };
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit_terminal_output(surface.id);
        }
    }

    pub fn seed_default_colors_if_no_durable_override(&self, colors: DefaultColors) {
        let surfaces = {
            let state = self.state.lock().unwrap();
            let mut current = self.default_colors.lock().unwrap();
            if self.durable_terminal_defaults.load(Ordering::Acquire) || *current == colors {
                return;
            }
            *current = colors;
            unique_surface_runtimes(&state)
        };
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit_terminal_output(surface.id);
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn resource_update_terminal_defaults_selected(
        &self,
        selectors: crate::ResourceSelectors,
        fields: &Value,
        colors: DefaultColors,
        value: &Value,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut intent_fields = fields.clone();
        if let Some(fields) = intent_fields.as_object_mut() {
            fields.remove("expected_revision");
        }
        let fingerprint = serde_json::json!({
            "operation":"session.terminal_defaults.update",
            "selectors":selectors,
            "fields":intent_fields,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(
            mutation,
            "session.terminal_defaults.update",
            &fingerprint,
        )? {
            return Ok(replay);
        }
        let mut state = self.state.lock().unwrap();
        self.resolve_resource_path_in_state(
            &state,
            &registry,
            crate::ResourceTarget::Session,
            &selectors,
        )
        .map_err(anyhow::Error::new)?;
        let surfaces = unique_surface_runtimes(&state);
        let commit = registry.commit_resource_patch(
            mutation,
            "session.terminal_defaults.update",
            &fingerprint,
            None,
            expected_revision,
            &ResourcePatch { changes: Vec::new() },
            value,
            &Value::Array(Vec::new()),
        )?;
        state.resource_revision = commit.revision;
        self.durable_terminal_defaults.store(true, Ordering::Release);
        *self.default_colors.lock().unwrap() = colors;
        for surface in &surfaces {
            surface.set_default_colors(colors);
        }
        drop(state);
        drop(registry);
        for surface in surfaces {
            self.emit_terminal_output(surface.id);
        }
        if !commit.replayed {
            self.publish_resource_event();
        }
        Ok(commit)
    }

    /// Resize a surface and broadcast the final clamped size when it actually
    /// changes. Browser workers broadcast after their asynchronous CDP work.
    pub fn resize_surface(&self, id: SurfaceId, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_surface_with_reservation(id, cols, rows).map(|(accepted, _)| accepted)
    }

    pub fn resize_surface_with_reservation(
        &self,
        id: SurfaceId,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        self.resize_surface_with_completion(id, cols, rows, None)
    }

    pub(super) fn resize_surface_with_completion(
        &self,
        id: SurfaceId,
        cols: u16,
        rows: u16,
        completion: Option<SurfaceResizeCompletion>,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        let Some(surface) = self.surface(id) else {
            anyhow::bail!("unknown surface {id}");
        };
        // Not recorded as a client size here: internal resizes (e.g. the
        // sidebar plugin surface tracking the TUI rect every frame) also land
        // in this method and must not become the default for new surfaces.
        // Client interactions record explicitly at the protocol/TUI layers.
        let (cols, rows) = clamp_terminal_size(cols, rows);
        if surface.as_browser().is_some() {
            let reservation_id =
                surface.resize_reporting_completion(cols, rows, Box::new(|_| {}), completion)?;
            return Ok((reservation_id.is_some(), reservation_id));
        }
        let reports_asynchronously = surface.resize_reports_asynchronously();
        if !surface.resize(cols, rows)? {
            if let Some(completion) = completion {
                let _ = completion.send(Ok(()));
            }
            return Ok((false, None));
        }
        if reports_asynchronously {
            return Ok((true, None));
        }
        if let Some(completion) = completion {
            let _ = completion.send(Ok(()));
        }
        let (cols, rows) = surface.size();
        self.emit_terminal_resized(id, cols, rows, None);
        Ok((true, None))
    }
}
