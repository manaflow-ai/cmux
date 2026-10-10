//! Client registry, attach side: attaching and committing surfaces, view
//! leases (status, streams, resize, restore, release, retired leases),
//! detaching surfaces, recorded client sizes and report order, removal, and
//! attach observation for the detach waker.

use super::ClientAnnouncement;
use super::ClientRecord;
use super::ClientRegistry;
use super::ClientSizeUpdate;
use super::DaemonHandoffReservation;
use super::DetachedSurface;
use super::OutboundStream;
use super::RETIRED_VIEW_LEASE_CAPACITY;
use super::VIEW_ATTACHMENT_LEASE_CAPABILITY;
use super::ViewLeaseStatus;
use super::ViewReleasePreparation;
use super::ViewResizePreparation;
use super::mint_view_lease;
use crate::SurfaceId;
use std::collections::HashMap;
use std::collections::HashSet;

impl ClientRegistry {
    pub(super) fn attach_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
    ) -> anyhow::Result<Option<String>> {
        self.attach_surface_with_lease_policy(client, surface, stream, false)
    }

    pub(super) fn attach_surface_with_required_lease(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
    ) -> anyhow::Result<String> {
        self.attach_surface_with_lease_policy(client, surface, stream, true)?
            .ok_or_else(|| anyhow::anyhow!("required view attachment lease was not minted"))
    }

    pub(super) fn attach_surface_with_lease_policy(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
        require_lease: bool,
    ) -> anyhow::Result<Option<String>> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let lease =
            if require_lease || record.capabilities.contains(VIEW_ATTACHMENT_LEASE_CAPABILITY) {
                let mut lease = mint_view_lease()?;
                while record.view_leases.contains_key(&lease)
                    || record.retired_view_leases.contains_key(&lease)
                {
                    lease = mint_view_lease()?;
                }
                Some(lease)
            } else {
                None
            };
        let stream_id = stream.id;
        let attached = record.attached.entry(surface).or_default();
        attached.pending_streams.insert(stream_id, stream);
        if let Some(lease) = &lease {
            attached.lease_by_stream.insert(stream_id, lease.clone());
            attached.view_sizes.insert(lease.clone(), None);
            if attached.geometry_lease.is_none() {
                attached.geometry_lease = Some(lease.clone());
            }
            record.view_leases.insert(lease.clone(), (surface, stream_id));
        }
        state.attached_by_surface.entry(surface).or_default().insert(client);
        state.next_attach_epoch += 1;
        let epoch = state.next_attach_epoch;
        state.attach_epochs.insert(surface, epoch);
        Ok(lease)
    }

    pub(super) fn commit_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: u64,
        rollback: Option<crate::mux::ClientSizeRollback>,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let attached = record
            .attached
            .get_mut(&surface)
            .ok_or_else(|| anyhow::anyhow!("client {client} has no pending surface {surface}"))?;
        let outbound = attached.pending_streams.remove(&stream).ok_or_else(|| {
            anyhow::anyhow!("client {client} has no pending stream {stream} for surface {surface}")
        })?;
        attached.streams.insert(stream, outbound);
        if let Some(lease) = attached.lease_by_stream.get(&stream)
            && let Some(current) = record.view_leases.get_mut(lease)
        {
            current.1 = stream;
        }
        if let Some(rollback) = rollback {
            attached.size_rollbacks.insert(stream, rollback);
        }
        attached.committed_size = attached.size;
        Ok(())
    }

    pub(super) fn view_lease_status(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
    ) -> anyhow::Result<ViewLeaseStatus> {
        let state = self.state.lock().unwrap();
        let record =
            state.clients.get(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some((lease_surface, _)) = record.view_leases.get(lease) {
            anyhow::ensure!(
                *lease_surface == surface,
                "view attachment lease belongs to surface {lease_surface}, not {surface}"
            );
            let geometry_owner = record
                .attached
                .get(&surface)
                .and_then(|attached| attached.geometry_lease.as_deref())
                == Some(lease);
            return Ok(ViewLeaseStatus::Current { geometry_owner });
        }
        if let Some(lease_surface) = record.retired_view_leases.get(lease) {
            anyhow::ensure!(
                *lease_surface == surface,
                "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
            );
            return Ok(ViewLeaseStatus::Superseded);
        }
        anyhow::bail!("invalid or foreign view attachment lease")
    }

    pub(super) fn view_stream(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
    ) -> anyhow::Result<Option<(u64, OutboundStream)>> {
        let state = self.state.lock().unwrap();
        let record =
            state.clients.get(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some((lease_surface, stream)) = record.view_leases.get(lease).copied() else {
            if let Some(lease_surface) = record.retired_view_leases.get(lease) {
                anyhow::ensure!(
                    *lease_surface == surface,
                    "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
                );
                return Ok(None);
            }
            anyhow::bail!("invalid or foreign view attachment lease");
        };
        anyhow::ensure!(
            lease_surface == surface,
            "view attachment lease belongs to surface {lease_surface}, not {surface}"
        );
        let Some(attached) = record.attached.get(&surface) else { return Ok(None) };
        Ok(attached
            .streams
            .get(&stream)
            .or_else(|| attached.pending_streams.get(&stream))
            .cloned()
            .map(|outbound| (stream, outbound)))
    }

    pub(super) fn prepare_view_resize(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
        size: (u16, u16),
    ) -> anyhow::Result<ViewResizePreparation> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some((lease_surface, _)) = record.view_leases.get(lease).copied() else {
            if let Some(lease_surface) = record.retired_view_leases.get(lease) {
                anyhow::ensure!(
                    *lease_surface == surface,
                    "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
                );
                return Ok(ViewResizePreparation::Superseded);
            }
            anyhow::bail!("invalid or foreign view attachment lease");
        };
        anyhow::ensure!(
            lease_surface == surface,
            "view attachment lease belongs to surface {lease_surface}, not {surface}"
        );
        let Some(attached) = record.attached.get_mut(&surface) else {
            return Ok(ViewResizePreparation::Superseded);
        };
        let previous_view_size = attached.view_sizes.get(lease).copied().flatten();
        let changed = previous_view_size != Some(size);
        attached.view_sizes.insert(lease.to_string(), Some(size));
        if attached.geometry_lease.as_deref() != Some(lease) {
            return Ok(ViewResizePreparation::Passive {
                changed,
                name: record.name.clone(),
                kind: record.kind.clone(),
            });
        }
        let previous = attached.size;
        attached.size = Some(size);
        if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
            attached.committed_size = attached.size;
        }
        Ok(ViewResizePreparation::GeometryOwner {
            update: (previous != Some(size), record.name.clone(), record.kind.clone(), previous),
            previous_view_size,
        })
    }

    pub(super) fn restore_view_size(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
        size: Option<(u16, u16)>,
    ) {
        let mut state = self.state.lock().unwrap();
        let Some(record) = state.clients.get_mut(&client) else { return };
        let Some(attached) = record.attached.get_mut(&surface) else { return };
        if !attached.view_sizes.contains_key(lease) {
            return;
        }
        attached.view_sizes.insert(lease.to_string(), size);
        if attached.geometry_lease.as_deref() == Some(lease) {
            attached.size = size;
            if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
                attached.committed_size = size;
            }
        }
    }

    pub(super) fn release_view_size(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
    ) -> anyhow::Result<ViewReleasePreparation> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some((lease_surface, _)) = record.view_leases.get(lease).copied() else {
            if let Some(lease_surface) = record.retired_view_leases.get(lease) {
                anyhow::ensure!(
                    *lease_surface == surface,
                    "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
                );
                return Ok(ViewReleasePreparation::Superseded);
            }
            anyhow::bail!("invalid or foreign view attachment lease");
        };
        anyhow::ensure!(
            lease_surface == surface,
            "view attachment lease belongs to surface {lease_surface}, not {surface}"
        );
        let Some(attached) = record.attached.get_mut(&surface) else {
            return Ok(ViewReleasePreparation::Superseded);
        };
        let changed = attached.view_sizes.insert(lease.to_string(), None).flatten().is_some();
        if attached.geometry_lease.as_deref() != Some(lease) {
            return Ok(ViewReleasePreparation::Passive);
        }
        attached.size = None;
        attached.committed_size = None;
        attached.current_report_order = None;
        Ok(ViewReleasePreparation::GeometryOwner {
            changed,
            name: record.name.clone(),
            kind: record.kind.clone(),
        })
    }

    pub(super) fn announce_attached(
        &self,
        client: u64,
    ) -> anyhow::Result<Option<ClientAnnouncement>> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if record.announced_attached {
            return Ok(None);
        }
        anyhow::ensure!(
            record.attached.values().any(|attached| !attached.streams.is_empty()),
            "client {client} has no attached surfaces"
        );
        record.announced_attached = true;
        Ok(Some((record.transport.as_str().to_string(), record.name.clone(), record.kind.clone())))
    }

    pub(super) fn retain_retired_view_lease(
        record: &mut ClientRecord,
        lease: String,
        surface: SurfaceId,
    ) {
        record.retired_view_leases.insert(lease.clone(), surface);
        record.retired_view_lease_order.push_back(lease);
        while record.retired_view_lease_order.len() > RETIRED_VIEW_LEASE_CAPACITY {
            if let Some(expired) = record.retired_view_lease_order.pop_front() {
                record.retired_view_leases.remove(&expired);
            }
        }
    }

    pub(super) fn retain_retired_surface(record: &mut ClientRecord, surface: SurfaceId) {
        if record.retired_surfaces.insert(surface) {
            record.retired_surface_order.push_back(surface);
        }
        while record.retired_surface_order.len() > RETIRED_VIEW_LEASE_CAPACITY {
            if let Some(expired) = record.retired_surface_order.pop_front() {
                record.retired_surfaces.remove(&expired);
            }
        }
    }

    pub(super) fn detach_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: u64,
    ) -> DetachedSurface {
        let mut state = self.state.lock().unwrap();
        let Some(record) = state.clients.get_mut(&client) else {
            return DetachedSurface {
                final_stream: false,
                rollback: None,
                geometry_replacement: None,
            };
        };
        let Some(attached) = record.attached.get_mut(&surface) else {
            return DetachedSurface {
                final_stream: false,
                rollback: None,
                geometry_replacement: None,
            };
        };
        attached.streams.remove(&stream);
        attached.pending_streams.remove(&stream);
        let removed_lease = attached.lease_by_stream.remove(&stream);
        let removed_geometry_owner = removed_lease
            .as_deref()
            .is_some_and(|lease| attached.geometry_lease.as_deref() == Some(lease));
        if let Some(lease) = &removed_lease {
            attached.view_sizes.remove(lease);
        }
        let rollback = attached.size_rollbacks.remove(&stream);
        if let Some(removed) = rollback {
            for remaining in attached.size_rollbacks.values_mut() {
                if remaining.previous_report_order == Some(removed.applied_report_order) {
                    remaining.previous_size = removed.previous_size;
                    remaining.previous_report_order = removed.previous_report_order;
                    remaining.previous_geometry = removed.previous_geometry;
                }
            }
        }
        let final_stream = attached.streams.is_empty() && attached.pending_streams.is_empty();
        let geometry_replacement = if removed_geometry_owner && !final_stream {
            let replacement = attached
                .lease_by_stream
                .iter()
                .find(|(stream, _)| attached.streams.contains_key(stream))
                .or_else(|| attached.lease_by_stream.iter().next())
                .map(|(_, lease)| lease.clone());
            attached.geometry_lease = replacement.clone();
            let size = replacement
                .as_ref()
                .and_then(|lease| attached.view_sizes.get(lease).copied().flatten());
            attached.size = size;
            attached.committed_size = size;
            attached.current_report_order = None;
            Some(size)
        } else {
            None
        };
        let rollback = rollback.filter(|rollback| {
            geometry_replacement.is_none()
                && attached.current_report_order == Some(rollback.applied_report_order)
        });
        if let Some(lease) = removed_lease {
            record.view_leases.remove(&lease);
            Self::retain_retired_view_lease(record, lease, surface);
        }
        if final_stream {
            record.attached.remove(&surface);
            Self::retain_retired_surface(record, surface);
            if let Some(clients) = state.attached_by_surface.get_mut(&surface) {
                clients.remove(&client);
                if clients.is_empty() {
                    state.attached_by_surface.remove(&surface);
                    self.notify_detach();
                }
            }
            return DetachedSurface {
                final_stream: true,
                rollback,
                geometry_replacement: Some(None),
            };
        }
        DetachedSurface { final_stream: false, rollback, geometry_replacement }
    }

    pub(crate) fn record_size(
        &self,
        client: u64,
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<ClientSizeUpdate>> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some(attached) = record.attached.get_mut(&surface) else { return Ok(None) };
        let previous = attached.size;
        let changed = previous != Some((cols, rows));
        attached.size = Some((cols, rows));
        if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
            attached.committed_size = attached.size;
        }
        Ok(Some((changed, record.name.clone(), record.kind.clone(), previous)))
    }

    pub(crate) fn set_report_order(&self, client: u64, surface: SurfaceId, report_order: u64) {
        if let Some(attached) = self
            .state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.current_report_order = Some(report_order);
        }
    }

    pub(crate) fn restore_size(&self, client: u64, surface: SurfaceId, size: Option<(u16, u16)>) {
        if let Some(attached) = self
            .state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.size = size;
            if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
                attached.committed_size = size;
            }
        }
    }

    pub(crate) fn restore_size_and_report_order(
        &self,
        client: u64,
        surface: SurfaceId,
        size: Option<(u16, u16)>,
        report_order: Option<u64>,
    ) {
        self.restore_size(client, surface, size);
        if let Some(attached) = self
            .state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.current_report_order = report_order;
        }
    }

    pub(super) fn clear_size(
        &self,
        client: u64,
        surface: SurfaceId,
    ) -> Option<(bool, Option<String>, Option<String>)> {
        let mut state = self.state.lock().unwrap();
        let record = state.clients.get_mut(&client)?;
        let attached = record.attached.get_mut(&surface)?;
        let changed = attached.size.take().is_some();
        attached.committed_size = None;
        attached.current_report_order = None;
        Some((changed, record.name.clone(), record.kind.clone()))
    }

    pub(super) fn remove(&self, client: u64) -> Option<ClientRecord> {
        self.url_opens.disconnect(client);
        self.clipboard_reads.disconnect(client);
        self.loopback.disconnect(client);
        #[cfg(unix)]
        self.agent_sessions.disconnect(client);
        self.apps.disconnect(client);
        self.scripts.disconnect(client);
        // Safety: a removal never grants access; on a poisoned registry the
        // record still goes, so a fail-closed close never panics here.
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let record = state.clients.remove(&client)?;
        // After the record goes: a start that ends later sees the connection gone.
        #[cfg(unix)]
        self.browser_runtimes.disconnect(client);
        if state.daemon_handoff == Some(DaemonHandoffReservation::Pending(client)) {
            state.daemon_handoff = None;
        }
        let mut detached = false;
        for surface in record.attached.keys() {
            if let Some(clients) = state.attached_by_surface.get_mut(surface) {
                clients.remove(&client);
                if clients.is_empty() {
                    state.attached_by_surface.remove(surface);
                    detached = true;
                }
            }
        }
        drop(state);
        if detached {
            self.notify_detach();
        }
        self.notify_client_presence();
        Some(record)
    }

    pub(crate) fn contains(&self, client: u64) -> bool {
        self.state.lock().unwrap().clients.contains_key(&client)
    }

    pub(crate) fn client_info(&self, client: u64) -> Option<(Option<String>, Option<String>)> {
        self.state
            .lock()
            .unwrap()
            .clients
            .get(&client)
            .map(|record| (record.name.clone(), record.kind.clone()))
    }

    #[cfg(test)]
    pub(crate) fn attached_client_ids(&self) -> HashSet<u64> {
        self.state
            .lock()
            .unwrap()
            .clients
            .iter()
            .filter_map(|(client, record)| (!record.attached.is_empty()).then_some(*client))
            .collect()
    }

    pub(crate) fn attached_client_ids_by_surface(&self) -> HashMap<SurfaceId, HashSet<u64>> {
        self.state.lock().unwrap().attached_by_surface.clone()
    }

    /// Query one surface without walking every client's retained attachments.
    pub(crate) fn attached_client_ids_for_surface(&self, surface: SurfaceId) -> HashSet<u64> {
        self.state.lock().unwrap().attached_by_surface.get(&surface).cloned().unwrap_or_default()
    }

    /// Whether any client holds an attach stream on one of `surfaces`, and
    /// the newest attach epoch among them (0 when none was ever attached).
    pub(crate) fn set_detach_waker(&self, waker: impl Fn() + Send + Sync + 'static) {
        *self.detach_waker.lock().unwrap() = Some(Box::new(waker));
    }

    pub(super) fn notify_detach(&self) {
        if let Some(waker) = self.detach_waker.lock().unwrap().as_ref() {
            waker();
        }
    }

    pub(crate) fn attach_observation(&self, surfaces: &[SurfaceId]) -> (bool, u64) {
        let state = self.state.lock().unwrap();
        let attached =
            surfaces.iter().any(|surface| state.attached_by_surface.contains_key(surface));
        let epoch = surfaces
            .iter()
            .filter_map(|surface| state.attach_epochs.get(surface).copied())
            .max()
            .unwrap_or(0);
        (attached, epoch)
    }

    /// Drop the attach epoch of a surface that no longer exists.
    pub(crate) fn forget_surface_attach_epoch(&self, surface: SurfaceId) {
        self.state.lock().unwrap().attach_epochs.remove(&surface);
    }
}
