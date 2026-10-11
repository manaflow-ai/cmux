//! Surface attach, cell pixel geometry, overflow recovery, and retirement.

use super::*;

impl RemoteSession {
    pub fn set_cell_pixel_size(
        &self,
        width_px: u16,
        height_px: u16,
    ) -> anyhow::Result<RemoteCellPixelUpdate> {
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let next = (width_px.max(1), height_px.max(1));
        let previous_global = *self.cell_pixels.lock().unwrap();
        let surfaces = self.surfaces.lock().unwrap().values().cloned().collect::<Vec<_>>();
        let snapshots = surfaces
            .iter()
            .map(|surface| (surface.clone(), surface.cell_pixel_size()))
            .collect::<Vec<_>>();
        for (index, surface) in surfaces.iter().enumerate() {
            if let Err(error) = surface.set_cell_pixel_size(next.0, next.1) {
                let rollback = Self::restore_cell_pixels(&snapshots[..index]);
                return match rollback {
                    Ok(()) => Err(anyhow::anyhow!(
                        "could not update cell pixels for remote mirror {}: {error}",
                        surface.id
                    )),
                    Err(rollback_error) => Err(anyhow::anyhow!(
                        "could not update cell pixels for remote mirror {}: {error}; \
                         local rollback also failed: {rollback_error}",
                        surface.id
                    )),
                };
            }
        }
        let response = match self.request(json!({
            "cmd": "set-cell-pixels",
            "width_px": next.0,
            "height_px": next.1,
        })) {
            Ok(response) => response,
            Err(error) => {
                let known_not_applied = matches!(
                    error.downcast_ref::<RemoteRequestError>(),
                    Some(RemoteRequestError::Encode(_) | RemoteRequestError::Rejected { .. })
                );
                if known_not_applied {
                    *self.cell_pixels.lock().unwrap() = previous_global;
                    return match Self::restore_cell_pixels(&snapshots) {
                        Ok(()) => Err(error),
                        Err(rollback_error) => Err(anyhow::anyhow!(
                            "{error}; local cell-pixel rollback also failed: {rollback_error}"
                        )),
                    };
                }
                *self.cell_pixels.lock().unwrap() = next;
                let _ = self.reconcile_cell_pixels_from_remote();
                return Err(error);
            }
        };
        let resizes = response
            .get("resizes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|resize| {
                Some((
                    resize.get("surface")?.as_u64()?,
                    (
                        u16::try_from(resize.get("cols")?.as_u64()?).ok()?,
                        u16::try_from(resize.get("rows")?.as_u64()?).ok()?,
                    ),
                    resize.get("reservation_id").and_then(Value::as_u64),
                ))
            })
            .collect::<Vec<_>>();
        let failures = response
            .get("failures")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|failure| {
                Some((
                    failure.get("surface")?.as_u64()?,
                    failure.get("error")?.as_str()?.to_string(),
                    failure.get("deferred").and_then(Value::as_bool).unwrap_or(false),
                ))
            })
            .collect::<Vec<_>>();
        let failed_surfaces = failures
            .iter()
            .filter_map(|(surface, _, deferred)| (!deferred).then_some(*surface))
            .collect::<HashSet<_>>();
        let use_target_for_creation =
            failures.is_empty() || failures.iter().all(|(_, _, deferred)| *deferred);
        let failed_snapshots = snapshots
            .iter()
            .filter(|(surface, _)| failed_surfaces.contains(&surface.id))
            .cloned()
            .collect::<Vec<_>>();
        Self::restore_cell_pixels(&failed_snapshots)?;
        if use_target_for_creation {
            *self.cell_pixels.lock().unwrap() = next;
        }
        let failures =
            failures.into_iter().map(|(surface, error, _)| (surface, error)).collect::<Vec<_>>();
        Ok(RemoteCellPixelUpdate { resizes, failures })
    }

    fn reconcile_cell_pixels_from_remote(&self) -> anyhow::Result<()> {
        let response = self.request(json!({"cmd": "get-cell-pixels"}))?;
        let width_px = response
            .get("width_px")
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .filter(|value| *value > 0)
            .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted width_px"))?;
        let height_px = response
            .get("height_px")
            .and_then(Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .filter(|value| *value > 0)
            .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted height_px"))?;
        let surface_metrics = response
            .get("surfaces")
            .and_then(Value::as_array)
            .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted surfaces"))?
            .iter()
            .map(|surface| {
                let id = surface
                    .get("surface")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| anyhow::anyhow!("remote cell-pixel query omitted surface id"))?;
                let width_px = surface
                    .get("width_px")
                    .and_then(Value::as_u64)
                    .and_then(|value| u16::try_from(value).ok())
                    .filter(|value| *value > 0)
                    .ok_or_else(|| {
                        anyhow::anyhow!("remote cell-pixel query omitted surface width_px")
                    })?;
                let height_px = surface
                    .get("height_px")
                    .and_then(Value::as_u64)
                    .and_then(|value| u16::try_from(value).ok())
                    .filter(|value| *value > 0)
                    .ok_or_else(|| {
                        anyhow::anyhow!("remote cell-pixel query omitted surface height_px")
                    })?;
                Ok((id, (width_px, height_px)))
            })
            .collect::<anyhow::Result<HashMap<_, _>>>()?;
        let surfaces = self.surfaces.lock().unwrap().values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            if let Some(metric) = surface_metrics.get(&surface.id) {
                surface.set_cell_pixel_size(metric.0, metric.1)?;
            }
        }
        *self.cell_pixels.lock().unwrap() = (width_px, height_px);
        Ok(())
    }

    fn restore_cell_pixels(snapshots: &[(Arc<RemoteSurface>, (u16, u16))]) -> anyhow::Result<()> {
        let mut failures = Vec::new();
        for (surface, previous) in snapshots {
            if let Err(error) = surface.set_cell_pixel_size(previous.0, previous.1) {
                failures.push(format!("surface {}: {error}", surface.id));
            }
        }
        if failures.is_empty() { Ok(()) } else { anyhow::bail!("{}", failures.join("; ")) }
    }

    pub fn supports_browser_attach(&self) -> bool {
        self.supports_capability(GUARDED_BROWSER_POINTER_CAPABILITY)
    }

    pub(super) fn record_surface_overflow(&self, id: SurfaceId) -> (Option<Duration>, bool) {
        let now = Instant::now();
        let mut recoveries = self.surface_overflow_recovery.lock().unwrap();
        recoveries.retain(|_, recovery| {
            !recovery.attached_at.is_some_and(|attached| {
                now.saturating_duration_since(attached) >= SURFACE_OVERFLOW_STABLE
            })
        });
        if self.surface_overflow_reconnect_required.load(Ordering::Acquire)
            || (!recoveries.contains_key(&id)
                && recoveries.len() >= MAX_SURFACE_OVERFLOW_RECOVERIES)
        {
            self.surface_overflow_reconnect_required.store(true, Ordering::Release);
            return (None, true);
        }
        let recovery = recoveries.entry(id).or_insert(SurfaceOverflowRecovery {
            attempts: 0,
            retry_after: None,
            attached_at: None,
            stopped: false,
        });
        if recovery
            .attached_at
            .is_some_and(|attached| now.duration_since(attached) >= SURFACE_OVERFLOW_STABLE)
        {
            recovery.attempts = 0;
        }
        recovery.attached_at = None;
        let delay = SURFACE_OVERFLOW_RETRY_DELAYS.get(usize::from(recovery.attempts)).copied();
        recovery.attempts = recovery.attempts.saturating_add(1);
        recovery.stopped = delay.is_none();
        recovery.retry_after = delay.map(|delay| now + delay);
        (delay, recovery.stopped)
    }

    pub fn can_attach_after_overflow(&self, id: SurfaceId) -> bool {
        if self.surface_overflow_reconnect_required.load(Ordering::Acquire) {
            return false;
        }
        self.surface_overflow_recovery.lock().unwrap().get(&id).is_none_or(|recovery| {
            !recovery.stopped
                && recovery.retry_after.is_none_or(|retry_after| Instant::now() >= retry_after)
        })
    }

    pub fn surface_overflow_retry_due(&self) -> bool {
        if self.surface_overflow_reconnect_required.load(Ordering::Acquire) {
            return false;
        }
        self.surface_overflow_recovery.lock().unwrap().values().any(|recovery| {
            !recovery.stopped
                && recovery.retry_after.is_some_and(|retry_after| Instant::now() >= retry_after)
        })
    }

    /// Mirror for a surface, attaching on first use. Servers advertising
    /// initial attach sizing receive the first viewer claim atomically with
    /// the attach, so the initial replay already has its final geometry.
    pub(in crate::session) fn try_ensure_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RemoteSurfaceAttach> {
        let kind = {
            let tree = self.tree.lock().unwrap();
            tree.view.surface_kind(id)
        };
        self.try_ensure_surface_with_kind(id, kind, size)
    }

    pub(in crate::session) fn try_ensure_surface_with_kind(
        self: &Arc<Self>,
        id: SurfaceId,
        kind: SurfaceKind,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RemoteSurfaceAttach> {
        if self.retired_surfaces.lock().unwrap().contains(&id) {
            return Ok(RemoteSurfaceAttach::Retired);
        }
        if !self.can_attach_after_overflow(id) {
            return Ok(RemoteSurfaceAttach::Deferred);
        }
        if let Some(surface) = self.surfaces.lock().unwrap().get(&id) {
            return Ok(RemoteSurfaceAttach::Attached(surface.clone()));
        }
        let source = self.browser_sources.lock().unwrap().get(&id).copied().or_else(|| {
            (kind == SurfaceKind::Browser)
                .then(|| {
                    // Before the first tree refresh, preserve the historical lookup
                    // against the current cache rather than losing browser metadata.
                    let tree = self.tree.lock().unwrap();
                    browser_source_from_tree(&tree.view, id)
                })
                .flatten()
        });
        let (cols, rows) = size.unwrap_or((80, 24));
        let initial_size = size.map(|(cols, rows)| (cols.max(1), rows.max(1))).filter(|_| {
            self.supports_capability(cmux_tui_core::server::ATTACH_INITIAL_SIZE_CAPABILITY)
        });
        let surface = {
            // Coordinate only the local mirror commit with cell-metric
            // updates. The remote attach can stream for minutes and must not
            // retain this lifecycle lock while it waits.
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            if self.retired_surfaces.lock().unwrap().contains(&id) {
                return Ok(RemoteSurfaceAttach::Retired);
            }
            if !self.can_attach_after_overflow(id) {
                return Ok(RemoteSurfaceAttach::Deferred);
            }
            if let Some(surface) = self.surfaces.lock().unwrap().get(&id) {
                return Ok(RemoteSurfaceAttach::Attached(surface.clone()));
            }
            let cell_pixels = *self.cell_pixels.lock().unwrap();
            let mut term = Terminal::new(cols, rows, 10_000, Callbacks::default())?;
            term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
            let surface = Arc::new(RemoteSurface {
                id,
                kind,
                term: Mutex::new(term),
                mouse_encoders: Mutex::new(MouseEncoders::new()?),
                cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
                dirty: AtomicBool::new(false),
                geometry_lifecycle: Mutex::new(()),
                cell_pixels: Mutex::new(cell_pixels),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                content_generation: AtomicU64::new(1),
                reported_size: Mutex::new(None),
                browser: Mutex::new(RemoteBrowserState::default()),
            });
            surface.update_browser_source(source);
            self.surfaces.lock().unwrap().insert(id, surface.clone());
            surface
        };
        let mut request = json!({"cmd": "attach-surface", "surface": id});
        if let Some((cols, rows)) = initial_size {
            request["cols"] = json!(cols);
            request["rows"] = json!(rows);
        }
        // The vt-state event that follows fills the mirror.
        let response = match self.request_with_deadline(request, RequestDeadline::Attach) {
            Ok(response) => response,
            Err(error) => {
                {
                    let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
                    let mut surfaces = self.surfaces.lock().unwrap();
                    if surfaces.get(&id).is_some_and(|current| Arc::ptr_eq(current, &surface)) {
                        surfaces.remove(&id);
                    }
                }
                if error
                    .downcast_ref::<RemoteRequestError>()
                    .is_some_and(RemoteRequestError::is_timeout)
                {
                    // The server registers the stream before it queues the attach
                    // response. Closing the connection is the only protocol-level
                    // cancellation that guarantees a timed-out stream is released.
                    self.disconnect_transport();
                }
                return Err(error);
            }
        };
        let attachment_lease = if self.supports_capability(VIEW_ATTACHMENT_LEASE_CAPABILITY) {
            let Some(lease) = response.get("lease").and_then(Value::as_str) else {
                let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
                self.surfaces.lock().unwrap().remove(&id);
                self.disconnect_transport();
                anyhow::bail!(
                    "server advertised {VIEW_ATTACHMENT_LEASE_CAPABILITY} but attach returned no lease"
                );
            };
            Some(lease.to_string())
        } else {
            None
        };
        let superseded = {
            // Retirement can race the remote response. Commit the completed
            // attach only while this exact mirror is still the live entry.
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let current = self
                .surfaces
                .lock()
                .unwrap()
                .get(&id)
                .is_some_and(|candidate| Arc::ptr_eq(candidate, &surface));
            if self.retired_surfaces.lock().unwrap().contains(&id) {
                Some(RemoteSurfaceAttach::Retired)
            } else if !current {
                let overflowed = self.surface_overflow_recovery.lock().unwrap().contains_key(&id)
                    || self.surface_overflow_reconnect_required.load(Ordering::Acquire);
                Some(if overflowed {
                    RemoteSurfaceAttach::Deferred
                } else {
                    RemoteSurfaceAttach::Retired
                })
            } else {
                if let Some(lease) = &attachment_lease {
                    self.surface_leases.lock().unwrap().insert(id, lease.clone());
                }
                if let Some(size) = initial_size {
                    surface.set_reported_size(size);
                }
                if let Some(recovery) = self.surface_overflow_recovery.lock().unwrap().get_mut(&id)
                {
                    recovery.attached_at = Some(Instant::now());
                    recovery.retry_after = None;
                }
                None
            }
        };
        if superseded.is_none() {
            self.adopt_attach_size_state(id, &response);
        }
        if let Some(outcome) = superseded {
            if let Some(lease) = attachment_lease
                && self.supports_capability(VIEW_ATTACHMENT_DETACH_CAPABILITY)
            {
                if let Err(error) = self.request(json!({
                    "cmd": "detach-attached-view",
                    "surface": id,
                    "lease": lease,
                })) {
                    // If the targeted release cannot be confirmed, closing the
                    // transport is the remaining cleanup fence for every
                    // server-side attachment owned by this connection.
                    self.disconnect_transport();
                    return Err(anyhow::anyhow!(
                        "could not release superseded view attachment {id}: {error:#}"
                    ));
                }
            } else {
                // Older peers have no lease-addressed detach operation.
                self.disconnect_transport();
            }
            return Ok(outcome);
        }
        Ok(RemoteSurfaceAttach::Attached(surface))
    }

    pub fn retire_surface(&self, id: SurfaceId) {
        let mut retired_surfaces = self.retired_surfaces.lock().unwrap();
        retired_surfaces.insert(id);
        #[cfg(test)]
        if let Some(sender) = self.retire_surface_test_marker.lock().unwrap().clone() {
            let _ = sender.send(id);
        }
        self.tree.lock().unwrap().remove_agent(id);
        drop(retired_surfaces);
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let surface = self.surfaces.lock().unwrap().remove(&id);
        let mut exited = self.exited_surfaces.lock().unwrap();
        exited.ids.insert(id);
        if let Some(surface) = surface {
            exited.handles.insert(id, Arc::downgrade(&surface));
        }
        self.surface_leases.lock().unwrap().remove(&id);
        self.surface_overflow_recovery.lock().unwrap().remove(&id);
    }

    pub fn drop_surface(&self, id: SurfaceId) {
        self.retire_surface(id);
    }

    pub fn surface_is_exited(&self, id: SurfaceId) -> bool {
        self.exited_surfaces.lock().unwrap().ids.contains(&id)
    }

    pub fn surface_kind(&self, id: SurfaceId) -> SurfaceKind {
        self.tree.lock().unwrap().view.surface_kind(id)
    }
}
