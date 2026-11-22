//! Where a git read looks: an explicit path, or the working directory of the
//! terminal a selector names. A workspace, screen, pane or tab names its
//! current terminal.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;
use crate::{Mux, ResourceSelectors, ResourceTarget, SurfaceKind};

pub(super) fn directory(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
    operation: &'static str,
) -> Result<PathBuf, ResourceError> {
    let selectors = &request.selectors;
    let selected = selectors.workspace.is_some()
        || selectors.screen.is_some()
        || selectors.pane.is_some()
        || selectors.tab.is_some()
        || selectors.terminal.is_some();
    if let Some(path) = request.fields.get("path").and_then(Value::as_str) {
        if selected {
            return Err(ResourceError::validation_invalid(
                Some("path"),
                "give a path or a selector, not both",
            ));
        }
        mux.resolve_resource_path(ResourceTarget::Session, selectors)?;
        return explicit_path(path, operation);
    }
    if !selected {
        return Err(ResourceError::validation_invalid(
            Some("path"),
            "give a path or a workspace, screen, pane, tab or terminal selector",
        ));
    }
    let resolved =
        mux.resolve_resource_path(ResourceTarget::Terminal, &terminal(mux, selectors)?)?;
    let terminal_id =
        resolved.terminal.ok_or_else(|| ResourceError::not_found("terminal", "<resolved>"))?;
    let surface = mux
        .resource_surface_for_terminal(&terminal_id)
        .and_then(|surface| mux.surface(surface))
        .filter(|surface| surface.kind() == SurfaceKind::Pty)
        .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))?;
    let cwd = surface.local_cwd().ok_or_else(|| {
        ResourceError::operation_failed(
            operation,
            "the terminal has no working directory on this machine",
            json!({"code":"no_working_directory","terminal":terminal_id.as_str()}),
        )
    })?;
    Ok(PathBuf::from(cwd))
}

/// Selectors for the terminal that `selectors` names: itself, or the
/// current terminal under the deepest scope given.
fn terminal(
    mux: &Arc<Mux>,
    selectors: &ResourceSelectors,
) -> Result<ResourceSelectors, ResourceError> {
    if selectors.terminal.is_some() {
        return Ok(selectors.clone());
    }
    let scope = if selectors.tab.is_some() {
        ResourceTarget::Tab
    } else if selectors.pane.is_some() {
        ResourceTarget::Pane
    } else if selectors.screen.is_some() {
        ResourceTarget::Screen
    } else {
        ResourceTarget::Workspace
    };
    // Resolve to ids first: a `current` selector needs every parent present.
    let path = mux.resolve_resource_path(scope, selectors)?;
    let current = || Some("current".to_string());
    Ok(ResourceSelectors {
        workspace: path.workspace.map(|id| id.as_str().to_string()).or_else(current),
        screen: path.screen.map(|id| id.as_str().to_string()).or_else(current),
        pane: path.pane.map(|id| id.as_str().to_string()).or_else(current),
        tab: path.tab.map(|id| id.as_str().to_string()).or_else(current),
        terminal: current(),
        ..selectors.clone()
    })
}

fn explicit_path(raw: &str, operation: &'static str) -> Result<PathBuf, ResourceError> {
    let path = Path::new(raw);
    if !path.is_absolute() {
        return Err(ResourceError::validation_invalid(Some("path"), "path must be absolute"));
    }
    let metadata = std::fs::metadata(path).map_err(|error| {
        ResourceError::operation_failed(
            operation,
            format!("{raw}: {error}"),
            json!({"code":"target_not_found"}),
        )
    })?;
    if metadata.is_dir() {
        return Ok(path.to_path_buf());
    }
    Ok(path.parent().map_or_else(|| path.to_path_buf(), Path::to_path_buf))
}
