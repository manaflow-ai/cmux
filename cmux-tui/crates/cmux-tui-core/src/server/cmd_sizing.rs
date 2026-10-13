//! Terminal sizing command handlers: attached-view resize and release,
//! surface resize and release, client sizing participation, size counts and
//! policy, size activity, size state, and cell pixel metrics. Each function
//! is one `Command` arm of `handle_command_with_cancellation`.

use super::size_state_for_client;

use super::ClientIdentityWire;
use super::SHARED_SIZING_CAPABILITY;
use super::ViewLeaseStatus;
use super::ViewReleasePreparation;
use super::ViewResizePreparation;
use super::detached_terminals::accepts_view_sizing;
use super::get_surface;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
use crate::WorkspaceId;
use crate::mux::clamp_terminal_size;
use crate::sizing_policy::TerminalSizingPolicy;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn set_client_sizing(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    target: Option<u64>,
    enabled: bool,
    exclusive: bool,
) -> anyhow::Result<Value> {
    if exclusive && !enabled {
        anyhow::bail!("exclusive client sizing must be enabled");
    }
    get_surface(mux, surface)?;
    if exclusive && target.is_none() {
        mux.use_only_client_size(surface, client).ok_or_else(|| {
            anyhow::anyhow!(
                "client {client} is not attached with a reported size for surface {surface}"
            )
        })?;
        return Ok(json!({}));
    }
    if let Some(target) = target {
        if exclusive {
            mux.use_only_client_size(surface, target).ok_or_else(|| {
                anyhow::anyhow!(
                    "client {target} is not attached with a reported size for surface {surface}"
                )
            })?;
        } else {
            mux.set_client_size_participation(surface, target, enabled).ok_or_else(|| {
                anyhow::anyhow!("client {target} is not attached to surface {surface}")
            })?;
        }
    } else if enabled {
        mux.use_all_client_sizes(surface)
            .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
    } else {
        anyhow::bail!("client is required when disabling sizing");
    }
    Ok(json!({}))
}

pub(super) fn set_size_policy(
    mux: &Arc<Mux>,
    client: u64,
    surface: Option<SurfaceId>,
    workspace: Option<WorkspaceId>,
    policy: Option<TerminalSizingPolicy>,
) -> anyhow::Result<Value> {
    match (surface, workspace) {
        (Some(surface), None) => {
            get_surface(mux, surface)?;
            let state = mux
                .set_terminal_size_policy(surface, policy)
                .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?;
            Ok(json!({"state": size_state_for_client(mux, client, &state)}))
        }
        (None, Some(workspace)) => {
            mux.set_workspace_size_policy(workspace, policy)?;
            Ok(json!({}))
        }
        _ => {
            anyhow::bail!("bad request: set-size-policy needs exactly one of surface or workspace")
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn set_size_counts(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    target: Option<u64>,
    lease: Option<String>,
    view: Option<String>,
    participant: Option<String>,
    counts: Option<bool>,
) -> anyhow::Result<Value> {
    get_surface(mux, surface)?;
    let selectors = usize::from(target.is_some())
        + usize::from(lease.is_some())
        + usize::from(view.is_some())
        + usize::from(participant.is_some());
    anyhow::ensure!(
        selectors <= 1,
        "bad request: set-size-counts takes at most one of client, lease, view or participant"
    );
    let participant = if let Some(participant) = participant {
        participant
    } else if let Some(view) = view {
        crate::mux::sub_view_participant_id(client, &view)
    } else {
        if let Some(lease) = &lease {
            match mux.control_clients.view_lease_status(client, surface, lease)? {
                ViewLeaseStatus::Current { .. } => {}
                ViewLeaseStatus::Superseded => return Ok(json!({"outcome": "superseded"})),
            }
        }
        mux.terminal_view_participant_id(surface, target.unwrap_or(client))
            .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?
    };
    let changed = mux
        .set_terminal_size_counts(surface, &participant, counts)
        .ok_or_else(|| anyhow::anyhow!("unknown participant {participant}"))?;
    Ok(json!({"outcome": "applied", "changed": changed, "participant": participant}))
}

pub(super) fn note_size_activity(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    view: Option<String>,
) -> anyhow::Result<Value> {
    anyhow::ensure!(
        mux.control_clients.supports_capability(client, SHARED_SIZING_CAPABILITY),
        "note-size-activity requires client capability {SHARED_SIZING_CAPABILITY}"
    );
    get_surface(mux, surface)?;
    let participant = match view.as_deref() {
        Some(view) => crate::mux::sub_view_participant_id(client, view),
        None => mux
            .terminal_view_participant_id(surface, client)
            .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?,
    };
    let changed = mux
        .note_terminal_activity(surface, client, view.as_deref())
        .ok_or_else(|| anyhow::anyhow!("unknown participant {participant}"))?;
    Ok(json!({"participant": participant, "changed": changed}))
}

pub(super) fn get_size_state(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
) -> anyhow::Result<Value> {
    get_surface(mux, surface)?;
    let state = mux
        .terminal_size_state(surface)
        .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?;
    let self_participant = mux
        .terminal_view_participant_id(surface, client)
        .filter(|id| state.participant(id).is_some());
    Ok(json!({
        "state": size_state_for_client(mux, client, &state),
        "self_participant": self_participant,
    }))
}

pub(super) fn get_cell_pixels(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    let (width_px, height_px) = mux.cell_pixel_creation_size();
    let surfaces = mux.with_state(|state| {
        state
            .surfaces
            .values()
            .map(|surface| {
                let (width_px, height_px) = surface.cell_pixel_size();
                json!({
                    "surface": surface.id,
                    "width_px": width_px,
                    "height_px": height_px,
                })
            })
            .collect::<Vec<_>>()
    });
    Ok(json!({
        "width_px": width_px,
        "height_px": height_px,
        "surfaces": surfaces,
    }))
}

pub(super) fn set_cell_pixels(
    mux: &Arc<Mux>,
    width_px: u16,
    height_px: u16,
) -> anyhow::Result<Value> {
    let update = mux.set_cell_pixel_size(width_px, height_px);
    let resizes = update
        .resizes
        .into_iter()
        .map(|(surface, (cols, rows), reservation_id)| {
            json!({
                "surface": surface,
                "cols": cols,
                "rows": rows,
                "reservation_id": reservation_id,
            })
        })
        .collect::<Vec<_>>();
    let failures = update
        .failures
        .into_iter()
        .map(|failure| {
            json!({
                "surface": failure.surface,
                "error": failure.error,
                "deferred": failure.deferred,
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({"resizes": resizes, "failures": failures}))
}

pub(super) fn resize_surface(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    cols: u16,
    rows: u16,
) -> anyhow::Result<Value> {
    let (cols, rows) = clamp_terminal_size(cols, rows);
    if mux.control_clients.surface_attachment_is_retired_without_current(client, surface)
        || (!accepts_view_sizing(mux, surface)
            && mux.control_clients.surface_attachment_is_current_or_retired(client, surface))
    {
        return Ok(json!({
            "accepted": false,
            "reservation_id": null,
            "outcome": "superseded",
        }));
    }
    // Every live control connection participates through the same
    // client-size reducer. An unattached one-shot resize is removed
    // when its connection closes, so it cannot bypass visible viewers.
    // Recording and reducing happen under the sizing lock so a
    // concurrent detach cannot finish cleanup before this lease exists.
    let resize =
        match mux.resize_surface_for_control_client_with_reservation(surface, client, cols, rows) {
            Ok(resize) => resize,
            Err(_)
                if mux
                    .control_clients
                    .surface_attachment_is_retired_without_current(client, surface)
                    || (!accepts_view_sizing(mux, surface)
                        && mux
                            .control_clients
                            .surface_attachment_is_current_or_retired(client, surface)) =>
            {
                return Ok(json!({
                    "accepted": false,
                    "reservation_id": null,
                    "outcome": "superseded",
                }));
            }
            Err(error) => return Err(error),
        };
    if let Some((true, name, kind, _)) = resize.attached {
        mux.emit(MuxEvent::ClientChanged { client, name, kind });
    }
    Ok(json!({
        "accepted": resize.accepted,
        "reservation_id": resize.reservation_id,
        "outcome": "applied",
    }))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn resize_attached_view(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    lease: Option<String>,
    view: Option<String>,
    identity: Option<ClientIdentityWire>,
    cols: u16,
    rows: u16,
) -> anyhow::Result<Value> {
    let (cols, rows) = clamp_terminal_size(cols, rows);
    let lease = match (lease, view) {
        (Some(lease), None) => lease,
        (None, Some(view)) => {
            validate_relay_view(&view)?;
            let (participant, accepted) = mux.report_terminal_sub_view(
                surface,
                client,
                &view,
                identity.map(ClientIdentityWire::into_identity),
                Some((cols, rows)),
            )?;
            return Ok(json!({
                "accepted": accepted,
                "reservation_id": null,
                "outcome": "applied",
                "participant": participant,
            }));
        }
        _ => anyhow::bail!("bad request: resize-attached-view needs exactly one of lease or view"),
    };
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    match mux.control_clients.view_lease_status(client, surface, &lease)? {
        ViewLeaseStatus::Superseded => {
            return Ok(json!({
                "accepted": false,
                "reservation_id": null,
                "outcome": "superseded",
            }));
        }
        ViewLeaseStatus::Current { .. } if !accepts_view_sizing(mux, surface) => {
            return Ok(json!({
                "accepted": false,
                "reservation_id": null,
                "outcome": "superseded",
            }));
        }
        ViewLeaseStatus::Current { .. } => {}
    }
    match mux.control_clients.prepare_view_resize(client, surface, &lease, (cols, rows))? {
        ViewResizePreparation::Superseded => Ok(json!({
            "accepted": false,
            "reservation_id": null,
            "outcome": "superseded",
        })),
        ViewResizePreparation::Passive { .. } => Ok(json!({
            "accepted": false,
            "reservation_id": null,
            "outcome": "passive",
        })),
        ViewResizePreparation::GeometryOwner { update, previous_view_size } => {
            let resize = match mux.resize_surface_for_prepared_control_client_with_completion(
                surface,
                client,
                (cols, rows),
                None,
                Some(update),
            ) {
                Ok(resize) => resize,
                Err(error) => {
                    mux.control_clients.restore_view_size(
                        client,
                        surface,
                        &lease,
                        previous_view_size,
                    );
                    if !accepts_view_sizing(mux, surface) {
                        return Ok(json!({
                            "accepted": false,
                            "reservation_id": null,
                            "outcome": "superseded",
                        }));
                    }
                    return Err(error);
                }
            };
            if let Some((true, name, kind, _)) = resize.attached {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({
                "accepted": resize.accepted,
                "reservation_id": resize.reservation_id,
                "outcome": "applied",
            }))
        }
    }
}

pub(super) fn release_surface_size(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
) -> anyhow::Result<Value> {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    if mux.control_clients.surface_attachment_is_retired_without_current(client, surface)
        || (!accepts_view_sizing(mux, surface)
            && mux.control_clients.surface_attachment_is_current_or_retired(client, surface))
    {
        return Ok(json!({"outcome": "superseded"}));
    }
    let attached = mux.control_clients.clear_size(client, surface);
    let had_report = mux.client_surface_size(surface, client).is_some();
    if had_report {
        mux.remove_surface_size_client(surface, client);
    }
    let attached_changed = attached.as_ref().is_some_and(|(changed, _, _)| *changed);
    if attached_changed || (attached.is_none() && had_report) {
        let (name, kind) = attached
            .map(|(_, name, kind)| (name, kind))
            .or_else(|| mux.control_clients.client_info(client))
            .unwrap_or((None, None));
        mux.emit(MuxEvent::ClientChanged { client, name, kind });
    }
    Ok(json!({"outcome": "applied"}))
}

pub(super) fn release_attached_view_size(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    lease: Option<String>,
    view: Option<String>,
) -> anyhow::Result<Value> {
    let lease = match (lease, view) {
        (Some(lease), None) => lease,
        (None, Some(view)) => {
            return Ok(match mux.release_terminal_sub_view(surface, client, &view) {
                Some(_) => json!({"outcome": "applied"}),
                None => json!({"outcome": "superseded"}),
            });
        }
        _ => anyhow::bail!(
            "bad request: release-attached-view-size needs exactly one of lease or view"
        ),
    };
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    match mux.control_clients.view_lease_status(client, surface, &lease)? {
        ViewLeaseStatus::Superseded => {
            return Ok(json!({"outcome": "superseded"}));
        }
        ViewLeaseStatus::Current { .. } if !accepts_view_sizing(mux, surface) => {
            return Ok(json!({"outcome": "superseded"}));
        }
        ViewLeaseStatus::Current { .. } => {}
    }
    match mux.control_clients.release_view_size(client, surface, &lease)? {
        ViewReleasePreparation::Superseded => Ok(json!({"outcome": "superseded"})),
        ViewReleasePreparation::Passive => Ok(json!({"outcome": "passive"})),
        ViewReleasePreparation::GeometryOwner { changed, name, kind } => {
            let had_report = mux.client_surface_size(surface, client).is_some();
            if had_report {
                mux.remove_surface_size_client(surface, client);
            }
            if changed || had_report {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({"outcome": "applied"}))
        }
    }
}

fn validate_relay_view(view: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !view.is_empty() && view.len() <= 128 && !view.chars().any(char::is_control),
        "bad request: view must be 1-128 printable characters"
    );
    Ok(())
}

pub(super) fn optional_surface_size(cols: Option<u16>, rows: Option<u16>) -> Option<(u16, u16)> {
    cols.zip(rows).map(|(cols, rows)| (cols.max(1), rows.max(1)))
}

pub(super) fn paired_surface_size(
    command: &str,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Option<(u16, u16)>> {
    match (cols, rows) {
        (Some(cols), Some(rows)) => Ok(Some((cols.max(1), rows.max(1)))),
        (None, None) => Ok(None),
        _ => anyhow::bail!("{command} cols and rows must be supplied together"),
    }
}
