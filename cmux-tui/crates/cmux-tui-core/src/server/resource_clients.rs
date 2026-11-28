//! Resource-protocol client operations: resolving client and session
//! selectors, client and session snapshots, client metadata updates, client
//! sizing and cell pixels, and terminal and browser viewer resize and
//! release. Each function answers one `client.*`, `session.*` or
//! `*.viewer.*` resource operation for the connection dispatcher.

use std::sync::Arc;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{
    ResourceClientRecord, ViewLeaseStatus, ViewReleasePreparation, ViewResizePreparation,
    conversation_tabs_wire, detached_terminals::accepts_view_sizing,
};
use crate::mux::{Mux, clamp_terminal_size};
use crate::resource::{
    BrowserPublicId, ClientPublicId, ContentPublicId, ResourceError, Selector, SessionPublicId,
    TerminalPublicId,
};
use crate::{MuxEvent, SurfaceId, SurfaceKind};

pub(super) fn resource_session_id(
    mux: &Mux,
    selectors: &crate::ResourceSelectors,
) -> Result<SessionPublicId, ResourceError> {
    let route = crate::ResourceSelectors {
        machine: selectors.machine.clone(),
        session: selectors.session.clone(),
        ..Default::default()
    };
    mux.resolve_resource_path(crate::ResourceTarget::Session, &route)?
        .session
        .ok_or_else(|| ResourceError::not_found("session", "<resolved>"))
}

pub(crate) fn public_client_id(
    session_id: &SessionPublicId,
    client: u64,
) -> Result<ClientPublicId, ResourceError> {
    let mut digest = Sha256::new();
    digest.update(b"cmux.protocol/2/client/");
    digest.update(session_id.as_str().as_bytes());
    digest.update(b"/");
    digest.update(client.to_be_bytes());
    let digest = digest.finalize();
    let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    ClientPublicId::parse(format!("client_{payload}"))
}

fn resolve_resource_client(
    mux: &Mux,
    requesting_client: u64,
    selectors: &crate::ResourceSelectors,
) -> Result<(u64, SessionPublicId), ResourceError> {
    let session_id = resource_session_id(mux, selectors)?;
    let raw = selectors.client.as_deref().ok_or_else(|| {
        ResourceError::selector_invalid("client", "", "missing required client selector")
    })?;
    let records = mux.control_clients.resource_records();
    let selected = match Selector::parse(raw)? {
        Selector::Current => records
            .iter()
            .any(|record| record.client == requesting_client)
            .then_some(requesting_client),
        Selector::Id(id) => {
            let id = ClientPublicId::parse(id)?;
            records.iter().find_map(|record| {
                public_client_id(&session_id, record.client)
                    .ok()
                    .filter(|candidate| candidate == &id)
                    .map(|_| record.client)
            })
        }
        Selector::Name(name) => {
            let matches = records
                .iter()
                .filter(|record| record.name.as_deref() == Some(name.as_str()))
                .collect::<Vec<_>>();
            if matches.len() > 1 {
                return Err(ResourceError::ambiguous(
                    "client",
                    raw,
                    matches
                        .into_iter()
                        .filter_map(|record| public_client_id(&session_id, record.client).ok())
                        .map(|id| id.to_string())
                        .collect(),
                ));
            }
            matches.first().map(|record| record.client)
        }
    };
    selected
        .map(|selected| (selected, session_id))
        .ok_or_else(|| ResourceError::not_found("client", raw))
}

fn resource_client_snapshot(
    mux: &Mux,
    requesting_client: u64,
    session_id: &SessionPublicId,
    record: &ResourceClientRecord,
) -> Result<Value, ResourceError> {
    let mut attached_terminal_ids = Vec::<TerminalPublicId>::new();
    let mut sizes = Vec::<Value>::new();
    for (surface_id, size) in &record.attached {
        let Some(surface) = mux.surface(*surface_id) else {
            continue;
        };
        let Some(identity) = surface.resource_identity() else {
            continue;
        };
        let ContentPublicId::Terminal(terminal_id) = &identity.content_id else {
            continue;
        };
        attached_terminal_ids.push(terminal_id.clone());
        let (cols, rows) =
            size.map_or((Value::Null, Value::Null), |(cols, rows)| (json!(cols), json!(rows)));
        sizes.push(json!({
            "terminal_id":terminal_id,
            "cols":cols,
            "rows":rows,
            "participating":mux.client_size_participates(*surface_id, record.client),
        }));
    }
    attached_terminal_ids.sort_by(|left, right| left.as_str().cmp(right.as_str()));
    attached_terminal_ids.dedup();
    sizes.sort_by(|left, right| {
        left["terminal_id"]
            .as_str()
            .unwrap_or_default()
            .cmp(right["terminal_id"].as_str().unwrap_or_default())
    });
    Ok(json!({
        "id":public_client_id(session_id, record.client)?,
        "session_id":session_id,
        "name":record.name,
        "client_kind":record.kind,
        "transport":record.transport,
        "connected_seconds":record.connected_seconds.to_string(),
        "attached_terminal_ids":attached_terminal_ids,
        "sizes":sizes,
        "self":record.client == requesting_client,
    }))
}

pub(super) fn resource_client_list(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let session_id = resource_session_id(mux, &request.selectors)?;
    Ok(Value::Array(resource_client_snapshots(mux, requesting_client, &session_id)?))
}

fn resource_client_snapshots(
    mux: &Mux,
    requesting_client: u64,
    session_id: &SessionPublicId,
) -> Result<Vec<Value>, ResourceError> {
    let mut clients = mux
        .control_clients
        .resource_records()
        .iter()
        .map(|record| resource_client_snapshot(mux, requesting_client, session_id, record))
        .collect::<Result<Vec<_>, _>>()?;
    clients.sort_by(|left, right| {
        left["id"].as_str().unwrap_or_default().cmp(right["id"].as_str().unwrap_or_default())
    });
    Ok(clients)
}

pub(super) fn resource_session_snapshot(
    mux: &Mux,
    requesting_client: u64,
    selectors: &crate::ResourceSelectors,
) -> Result<Value, ResourceError> {
    let session_id = resource_session_id(mux, selectors)?;
    let mut snapshot = crate::resource_api::public_session_snapshot(mux)?;
    snapshot["clients"] =
        Value::Array(resource_client_snapshots(mux, requesting_client, &session_id)?);
    Ok(snapshot)
}

pub(super) fn resource_client_get(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| ResourceError::not_found("client", target.to_string().as_str()))?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

pub(super) fn resource_client_metadata_update(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    conversation_tabs_wire::set_resource_capabilities(mux, requesting_client, target, request)?;
    let name = request.fields.get("name").map(|value| value.as_str().map(str::to_string));
    let kind = request.fields.get("kind").map(|value| value.as_str().map(str::to_string));
    let (name, kind) = mux.control_clients.set_resource_info(target, name, kind)?;
    mux.emit(MuxEvent::ClientChanged { client: target, name, kind });
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| {
            ResourceError::not_found(
                "client",
                request.selectors.client.as_deref().unwrap_or("<missing>"),
            )
        })?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

pub(super) fn resource_terminal_surface(
    mux: &Mux,
    selectors: &crate::ResourceSelectors,
) -> Result<(TerminalPublicId, Arc<crate::Surface>), ResourceError> {
    let mut route = selectors.clone();
    route.client = None;
    let terminal_id = mux
        .resolve_resource_path(crate::ResourceTarget::Terminal, &route)?
        .terminal
        .ok_or_else(|| ResourceError::not_found("terminal", "<resolved>"))?;
    let surface_id = mux
        .resource_surface_for_terminal(&terminal_id)
        .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))?;
    let surface = mux
        .surface(surface_id)
        .filter(|surface| surface.kind() == SurfaceKind::Pty)
        .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))?;
    Ok((terminal_id, surface))
}

pub(super) fn resource_browser_surface(
    mux: &Mux,
    selectors: &crate::ResourceSelectors,
) -> Result<(BrowserPublicId, Arc<crate::Surface>), ResourceError> {
    let browser_id = mux
        .resolve_resource_path(crate::ResourceTarget::Browser, selectors)?
        .browser
        .ok_or_else(|| ResourceError::not_found("browser", "<resolved>"))?;
    let surface = mux
        .with_state(|state| {
            state
                .single_placement_of_content(&ContentPublicId::Browser(browser_id.clone()))
                .and_then(|surface| state.surfaces.get(&surface))
                .cloned()
        })
        .filter(|surface| surface.kind() == SurfaceKind::Browser)
        .ok_or_else(|| ResourceError::not_found("browser", browser_id.as_str()))?;
    Ok((browser_id, surface))
}

pub(super) fn resource_client_sizing_set(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "client.sizing.set";
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let enabled =
        request.fields["enabled"].as_bool().expect("catalog validates client sizing enabled");
    let exclusive = request.fields.get("exclusive").and_then(Value::as_bool).unwrap_or(false);
    if exclusive && !enabled {
        return Err(ResourceError::validation_invalid(
            Some("exclusive"),
            "exclusive client sizing must be enabled",
        ));
    }
    let changed = if exclusive {
        mux.use_only_client_size(surface.id, target)
    } else {
        mux.set_client_size_participation(surface.id, target, enabled)
    }
    .ok_or_else(|| {
        ResourceError::operation_failed(
            operation,
            "the selected client has no size lease for the terminal",
            json!({}),
        )
    })?;
    let _ = changed;
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| {
            ResourceError::not_found(
                "client",
                request.selectors.client.as_deref().unwrap_or("<missing>"),
            )
        })?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

pub(super) fn resource_client_sizing_release(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let attached = mux.control_clients.clear_size(target, surface.id);
    let had_report = mux.client_surface_size(surface.id, target).is_some();
    if had_report {
        mux.remove_surface_size_client(surface.id, target);
    }
    if attached.as_ref().is_some_and(|(changed, _, _)| *changed) || had_report {
        let (name, kind) = attached
            .map(|(_, name, kind)| (name, kind))
            .or_else(|| mux.control_clients.client_info(target))
            .unwrap_or((None, None));
        mux.emit(MuxEvent::ClientChanged { client: target, name, kind });
    }
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| {
            ResourceError::not_found(
                "client",
                request.selectors.client.as_deref().unwrap_or("<missing>"),
            )
        })?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

fn checked_resource_u16(
    operation: &'static str,
    fields: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<u16, ResourceError> {
    let value = fields[field].as_u64().expect("catalog validates integer fields");
    u16::try_from(value).map_err(|_| {
        ResourceError::operation_failed(
            operation,
            format!("{field} exceeds the runtime uint16 limit"),
            json!({"field":field,"value":value}),
        )
    })
}

fn surface_public_content_id(mux: &Mux, surface: SurfaceId) -> Option<String> {
    let surface = mux.surface(surface)?;
    surface.resource_identity().map(|identity| identity.content_id.as_str().to_string())
}

pub(super) fn resource_client_cell_pixels_set(
    mux: &Arc<Mux>,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "client.cell_pixels.set";
    let _ = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let width_px = checked_resource_u16(operation, &request.fields, "width_px")?;
    let height_px = checked_resource_u16(operation, &request.fields, "height_px")?;
    let update = mux.set_cell_pixel_size(width_px, height_px);
    let mut resized_terminals = update
        .resizes
        .into_iter()
        .filter_map(|(surface, _, _)| {
            let surface = mux.surface(surface)?;
            let identity = surface.resource_identity()?;
            let ContentPublicId::Terminal(terminal_id) = &identity.content_id else {
                return None;
            };
            Some(terminal_id.clone())
        })
        .collect::<Vec<_>>();
    resized_terminals.sort_by(|left, right| left.as_str().cmp(right.as_str()));
    resized_terminals.dedup();
    let failures = update
        .failures
        .into_iter()
        .filter_map(|failure| {
            surface_public_content_id(mux, failure.surface)
                .map(|id| (id, Value::String(failure.error)))
        })
        .collect::<serde_json::Map<_, _>>();
    Ok(json!({
        "width_px":u32::from(width_px),
        "height_px":u32::from(height_px),
        "resized_terminals":resized_terminals,
        "failures":failures,
    }))
}

pub(super) fn resource_terminal_viewer_resize(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "terminal.viewer.resize";
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let cols = checked_resource_u16(operation, &request.fields, "cols")?;
    let rows = checked_resource_u16(operation, &request.fields, "rows")?;
    let (cols, rows) = clamp_terminal_size(cols, rows);
    let (accepted, outcome) =
        resize_resource_view(mux, client, surface.id, lease, (cols, rows), operation)?;
    Ok(json!({
        "accepted":accepted,
        "size":{"cols":cols,"rows":rows},
        "outcome":outcome,
    }))
}

fn invalid_resource_view_lease(operation: &'static str) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        "attachment lease is invalid for this resource",
        json!({"reason_code":"invalid_attachment_lease"}),
    )
}

fn resize_resource_view(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    lease: &str,
    size: (u16, u16),
    operation: &'static str,
) -> Result<(bool, &'static str), ResourceError> {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    match mux
        .control_clients
        .view_lease_status(client, surface, lease)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewLeaseStatus::Superseded => return Ok((false, "superseded")),
        ViewLeaseStatus::Current { .. } if !accepts_view_sizing(mux, surface) => {
            return Ok((false, "superseded"));
        }
        ViewLeaseStatus::Current { .. } => {}
    }
    match mux
        .control_clients
        .prepare_view_resize(client, surface, lease, size)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewResizePreparation::Superseded => Ok((false, "superseded")),
        ViewResizePreparation::Passive { .. } => Ok((false, "passive")),
        ViewResizePreparation::GeometryOwner { update, previous_view_size } => {
            let resize = match mux.resize_surface_for_prepared_control_client_with_completion(
                surface,
                client,
                size,
                None,
                Some(update),
            ) {
                Ok(resize) => resize,
                Err(error) => {
                    mux.control_clients.restore_view_size(
                        client,
                        surface,
                        lease,
                        previous_view_size,
                    );
                    if !accepts_view_sizing(mux, surface) {
                        return Ok((false, "superseded"));
                    }
                    return Err(ResourceError::operation_failed(
                        operation,
                        error.to_string(),
                        json!({}),
                    ));
                }
            };
            if let Some((true, name, kind, _)) = resize.attached {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok((resize.accepted, "applied"))
        }
    }
}

fn release_resource_view(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    lease: &str,
    operation: &'static str,
) -> Result<&'static str, ResourceError> {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    match mux
        .control_clients
        .view_lease_status(client, surface, lease)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewLeaseStatus::Superseded => return Ok("superseded"),
        ViewLeaseStatus::Current { .. } if !accepts_view_sizing(mux, surface) => {
            return Ok("superseded");
        }
        ViewLeaseStatus::Current { .. } => {}
    }
    match mux
        .control_clients
        .release_view_size(client, surface, lease)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewReleasePreparation::Superseded => Ok("superseded"),
        ViewReleasePreparation::Passive => Ok("passive"),
        ViewReleasePreparation::GeometryOwner { changed, name, kind } => {
            let had_report = mux.client_surface_size(surface, client).is_some();
            if had_report {
                mux.remove_surface_size_client(surface, client);
            }
            if changed || had_report {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok("applied")
        }
    }
}

pub(super) fn resource_terminal_viewer_release(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let outcome = release_resource_view(mux, client, surface.id, lease, "terminal.viewer.release")?;
    Ok(json!({"outcome":outcome}))
}

pub(super) fn browser_cells_for_pixels(mux: &Mux, width_px: u32, height_px: u32) -> (u16, u16) {
    let (cell_width, cell_height) = mux.cell_pixel_size();
    let cols = width_px.div_ceil(u32::from(cell_width.max(1)));
    let rows = height_px.div_ceil(u32::from(cell_height.max(1)));
    clamp_terminal_size(
        u16::try_from(cols).unwrap_or(u16::MAX),
        u16::try_from(rows).unwrap_or(u16::MAX),
    )
}

pub(super) fn browser_pixels_for_cells(mux: &Mux, cols: u16, rows: u16) -> (u32, u32) {
    let (cell_width, cell_height) = mux.cell_pixel_size();
    (
        u32::from(cols) * u32::from(cell_width.max(1)),
        u32::from(rows) * u32::from(cell_height.max(1)),
    )
}

pub(super) fn resource_browser_viewer_resize(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "browser.viewer.resize";
    let (_, surface) = resource_browser_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let width_px =
        u32::try_from(request.fields["width_px"].as_u64().expect("catalog validates width_px"))
            .expect("catalog validates uint32");
    let height_px =
        u32::try_from(request.fields["height_px"].as_u64().expect("catalog validates height_px"))
            .expect("catalog validates uint32");
    let (cols, rows) = browser_cells_for_pixels(mux, width_px, height_px);
    let (accepted, outcome) =
        resize_resource_view(mux, client, surface.id, lease, (cols, rows), operation)?;
    let (width_px, height_px) = browser_pixels_for_cells(mux, cols, rows);
    Ok(json!({
        "accepted":accepted,
        "size":{"width_px":width_px,"height_px":height_px},
        "outcome":outcome,
    }))
}

pub(super) fn resource_browser_viewer_release(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resource_browser_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let outcome = release_resource_view(mux, client, surface.id, lease, "browser.viewer.release")?;
    Ok(json!({"outcome":outcome}))
}

pub(super) fn prepare_resource_client_detach(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<u64, ResourceError> {
    resolve_resource_client(mux, requesting_client, &request.selectors).map(|(target, _)| target)
}
