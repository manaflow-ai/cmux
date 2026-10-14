//! `workspace.open_url {workspace?, url}` (`workspace-open-url-v1`,
//! cx-ebm.59.3): a web link opens on the right side of a workspace, for
//! every client (the Chief chat in Home, a page, the CLI). The one rule:
//!
//! 1. Only an `http` or `https` URL with a host, at most 8192 bytes, with no
//!    control or space character; anything else is `validation.invalid`
//!    (field `url`). An omitted workspace is the home workspace.
//! 2. The target screen is the workspace's focused screen. Its right side is
//!    every pane outside a docked column that is the agent chat dock (role
//!    `agent_chat`) or pinned to the left edge.
//! 3. Reuse: the selected browser tab of the focused right-side pane, else of
//!    the right-side pane focused most recently (then layout order), else any
//!    browser tab on the right side. It navigates through `browser.navigate`
//!    and becomes its pane's selected tab; the keyboard focus stays.
//! 4. Else a new browser tab through `tab.create_browser` in the first of
//!    those panes; a workspace with no screen gets the screen that
//!    `tab.create_browser` makes for it.
//! 5. Else (only the dock) a browser in a new viewport column right of the
//!    dock (`pane-browser-kind-v1`'s `pane.split`).
//!
//! Each step runs under a key derived from the request's key, so a retry
//! replays what the first request did. Errors of a step (`engine_unavailable`
//! with no browser provider, a browser still starting) are returned as they
//! are.

use std::cmp::Reverse;
use std::sync::Arc;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::{
    ParsedResourceRequest, dispatch_resource_request, mutation_result, required_string,
    resource_operation_error, validate_resource_envelope,
};
use crate::model::{DockEdge, DockRole};
use crate::mux::PANE_BROWSER_URL_FIELD;
use crate::resource::{
    BrowserPublicId, ContentPublicId, PanePublicId, RequestEnvelope, ResourceError,
    ResourceOperation, ScreenPublicId, TabPublicId, WorkspacePublicId,
};
use crate::{Mux, PaneId, ResourceSelectors, ResourceTarget, Surface, SurfaceKind};

/// Advertised by `identify`: `workspace.open_url`.
pub(crate) const CAPABILITY: &str = "workspace-open-url-v1";
const OPERATION: &str = "workspace.open_url";
const MAX_URL_BYTES: usize = 8192;
/// Width of the column a link opens right of a lone dock.
const NEW_COLUMN_WIDTH: f64 = 0.5;

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let url = required_string(&request.fields, "url")?.to_string();
    if !is_web_url(&url) {
        return Err(ResourceError::validation_invalid(
            Some("url"),
            "the URL must be an http or https URL with a host, at most 8192 bytes",
        ));
    }
    let workspace = target_workspace(mux, &request.selectors)?;
    let key = request
        .envelope
        .idempotency_key
        .clone()
        .ok_or_else(|| ResourceError::validation_invalid(None, "a mutation needs a key"))?;
    let steps = StepKeys::new(&key, &workspace, &url);
    // A retry of a request whose first attempt created the tab replays it.
    if let Some(created) = created_before(mux, &steps)? {
        return Ok(created);
    }
    let candidates = mux.with_state(|state| right_side(state, &workspace));
    let Some(candidates) = candidates else {
        return Err(ResourceError::not_found("workspace", workspace.as_str()));
    };
    let call = Call { mux, request: &request, url: &url };
    if let Some(reuse) = reusable_browser(mux, &candidates) {
        return call.reuse(&steps, &candidates, reuse);
    }
    match (candidates.ranked.first(), candidates.dock) {
        (Some(pane), _) => call.create_browser("pane", pane.id.as_str(), &steps),
        (None, Some(dock)) => call.new_column(&dock, &steps),
        (None, None) => call.create_browser("workspace", workspace.as_str(), &steps),
    }
}

/// An http(s) URL with a host (the rule of the guest URL opener, url_open.rs).
fn is_web_url(raw: &str) -> bool {
    raw.len() <= MAX_URL_BYTES
        && !raw.chars().any(|c| c.is_control() || c.is_whitespace())
        && url::Url::parse(raw).is_ok_and(|url| {
            matches!(url.scheme(), "http" | "https")
                && url.host_str().is_some_and(|h| !h.is_empty())
        })
}

/// The selected workspace, else the home workspace (`workspace-kind-v1`).
fn target_workspace(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<WorkspacePublicId, ResourceError> {
    if selectors.workspace.is_some() {
        let path = mux.resolve_resource_path(ResourceTarget::Workspace, selectors)?;
        return path.workspace.ok_or_else(|| ResourceError::not_found("workspace", "selected"));
    }
    mux.resolve_resource_path(ResourceTarget::Session, selectors)?;
    let home = mux
        .read_registry_state(crate::state::home_store::live_home)
        .map_err(resource_operation_error)?;
    let Some((id, _)) = home else {
        return Err(ResourceError::new(
            "selector.not_found",
            "no home workspace: name the workspace to open the URL in",
            json!({"scope":"workspace","selector":"home"}),
            false,
        ));
    };
    WorkspacePublicId::parse(id).map_err(|_| ResourceError::not_found("workspace", "home"))
}

/// The keys of the steps, derived from the request's key, workspace and URL
/// (at most 128 bytes): a retry replays, and the same key with another link
/// never replays this one.
struct StepKeys {
    create: String,
    navigate: String,
    select: String,
}

impl StepKeys {
    fn new(key: &str, workspace: &WorkspacePublicId, url: &str) -> Self {
        let mut digest = Sha256::new();
        for part in [key, workspace.as_str(), url] {
            digest.update(part.as_bytes());
            digest.update([0]);
        }
        let digest = digest.finalize();
        let hash: String = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect();
        Self {
            create: format!("open-url-create-{hash}"),
            navigate: format!("open-url-navigate-{hash}"),
            select: format!("open-url-select-{hash}"),
        }
    }
}

/// One pane of the right side and its tabs, in strip order.
struct RightPane {
    id: PanePublicId,
    active: Option<crate::SurfaceId>,
    tabs: Vec<(crate::SurfaceId, Arc<Surface>)>,
}

/// The target screen's right side, best pane first, and its dock pane.
struct RightSide {
    screen: Option<ScreenPublicId>,
    ranked: Vec<RightPane>,
    dock: Option<PanePublicId>,
}

/// Read under the state lock; conversation and remote tabs are filtered
/// after it (their records live in the registry, locked before the state).
fn right_side(state: &crate::State, workspace: &WorkspacePublicId) -> Option<RightSide> {
    let workspace = state.workspaces.iter().find(|candidate| candidate.public_id == *workspace)?;
    let Some(screen) = workspace.active_screen_ref().or_else(|| workspace.screens.first()) else {
        return Some(RightSide { screen: None, ranked: Vec::new(), dock: None });
    };
    let left_dock = |dock: &crate::ColumnDock| {
        dock.role == Some(DockRole::AgentChat) || dock.edge == DockEdge::Left
    };
    let docked = screen
        .layout_columns
        .iter()
        .filter(|column| column.dock.as_ref().is_some_and(left_dock))
        .flat_map(|column| column.root.pane_ids_vec())
        .collect::<Vec<_>>();
    let public = |pane: PaneId| state.resource_indexes.pane_ids.get(&pane).cloned();
    let mut right = screen
        .root
        .pane_ids_vec()
        .into_iter()
        .filter(|pane| !docked.contains(pane))
        .filter_map(|pane| Some((pane, state.panes.get(&pane)?)))
        .collect::<Vec<_>>();
    // Stable: equal recency keeps the layout order.
    right.sort_by_key(|(id, pane)| (Reverse(*id == screen.active_pane), Reverse(pane.focused_at)));
    let ranked = right
        .into_iter()
        .filter_map(|(id, pane)| {
            Some(RightPane {
                id: public(id)?,
                active: pane.active_surface(),
                tabs: pane
                    .tabs
                    .iter()
                    .filter_map(|tab| Some((*tab, state.surfaces.get(tab)?.clone())))
                    .collect(),
            })
        })
        .collect();
    let dock = docked
        .iter()
        .find(|pane| **pane == screen.active_pane)
        .or_else(|| docked.first())
        .and_then(|pane| public(*pane));
    Some(RightSide { screen: Some(screen.public_id.clone()), ranked, dock })
}

/// A browser tab the link may reuse: its pane, tab and browser.
struct Reuse {
    pane: PanePublicId,
    tab: TabPublicId,
    browser: BrowserPublicId,
}

fn browser_page(mux: &Mux, surface: &Surface) -> Option<(TabPublicId, BrowserPublicId)> {
    if surface.kind() != SurfaceKind::Browser || mux.refuse_conversation_browser(surface).is_err() {
        return None;
    }
    let identity = surface.resource_identity()?;
    let ContentPublicId::Browser(browser) = &identity.content_id else { return None };
    Some((identity.tab_id.clone(), browser.clone()))
}

fn reusable_browser(mux: &Mux, side: &RightSide) -> Option<Reuse> {
    let reuse = |pane: &RightPane, surface: &Surface| {
        browser_page(mux, surface).map(|(tab, browser)| Reuse {
            pane: pane.id.clone(),
            tab,
            browser,
        })
    };
    let selected = side.ranked.iter().find_map(|pane| {
        let (_, surface) = pane.tabs.iter().find(|(id, _)| Some(*id) == pane.active)?;
        reuse(pane, surface)
    });
    selected.or_else(|| {
        side.ranked
            .iter()
            .find_map(|pane| pane.tabs.iter().find_map(|(_, surface)| reuse(pane, surface)))
    })
}

/// A created step's result, when this request's create step already ran.
fn created_before(mux: &Arc<Mux>, steps: &StepKeys) -> Result<Option<Value>, ResourceError> {
    let resolution =
        mux.resource_creation_resolution(&steps.create).map_err(resource_operation_error)?;
    if resolution["state"] != "created" || resolution["created_path"]["kind"] != "browser" {
        return Ok(None);
    }
    let mut value = resolution["created_path"].clone();
    value["reused"] = json!(false);
    let revision = resolution["revision"].as_str().and_then(|revision| revision.parse().ok());
    mutation_result(mux, value, revision.unwrap_or_default(), true).map(Some)
}

struct Call<'a> {
    mux: &'a Arc<Mux>,
    request: &'a ParsedResourceRequest,
    url: &'a str,
}

impl Call<'_> {
    /// One catalog operation of this request's actor, with the request's
    /// machine and session and `selectors`, under `key`.
    fn inner(
        &self,
        operation: ResourceOperation,
        selectors: Map<String, Value>,
        fields: Value,
        key: Option<&str>,
    ) -> Result<Value, ResourceError> {
        let mut params = selectors;
        params.insert("machine".into(), json!(self.request.selectors.machine));
        params.insert("session".into(), json!(self.request.selectors.session));
        params.extend(fields.as_object().cloned().unwrap_or_default());
        let id = self.request.envelope.id.clone();
        let envelope =
            RequestEnvelope::request(id, operation, Value::Object(params), key.map(str::to_string));
        let parsed = validate_resource_envelope(envelope, self.request.actor.clone())?;
        dispatch_resource_request(self.mux, parsed)
    }

    fn create_browser(
        &self,
        scope: &str,
        id: &str,
        steps: &StepKeys,
    ) -> Result<Value, ResourceError> {
        let created = self.inner(
            ResourceOperation::TabCreateBrowser,
            Map::from_iter([(scope.to_string(), json!(id))]),
            json!({"url": self.url}),
            Some(&steps.create),
        )?;
        Ok(with_reused(created, false))
    }

    /// A browser in a new viewport column right of the lone dock pane.
    fn new_column(&self, dock: &PanePublicId, steps: &StepKeys) -> Result<Value, ResourceError> {
        if let Some(error) = self.mux.browser_engine_unavailable(OPERATION) {
            return Err(error);
        }
        let selectors = ResourceSelectors {
            machine: self.request.selectors.machine.clone(),
            session: self.request.selectors.session.clone(),
            pane: Some(dock.as_str().to_string()),
            ..Default::default()
        };
        let fields = Map::from_iter([
            ("direction".to_string(), json!("right")),
            ("viewport_width".to_string(), json!(NEW_COLUMN_WIDTH)),
            (PANE_BROWSER_URL_FIELD.to_string(), json!(self.url)),
        ]);
        let mutation = crate::WorkspaceMutation::new(
            steps.create.clone(),
            "resource-api",
            self.request.actor.clone(),
        )
        .map_err(resource_operation_error)?;
        let commit = self
            .mux
            .resource_topology_operation(
                ResourceOperation::PaneSplit,
                selectors,
                fields,
                None,
                &mutation,
            )
            .map_err(resource_operation_error)?;
        // A new pane takes the focus; it goes back to the dock (the chat).
        let focused = self.inner(
            ResourceOperation::PaneFocus,
            Map::from_iter([("pane".to_string(), json!(dock.as_str()))]),
            json!({}),
            Some(&steps.select),
        )?;
        let mut value = commit.result.clone();
        value["reused"] = json!(false);
        let revision = focused["revision"].as_str().and_then(|revision| revision.parse().ok());
        mutation_result(self.mux, value, revision.unwrap_or(commit.revision), commit.replayed)
    }

    /// Navigate the reused browser, then select its tab in its pane.
    fn reuse(
        &self,
        steps: &StepKeys,
        side: &RightSide,
        reuse: Reuse,
    ) -> Result<Value, ResourceError> {
        let navigated = self.inner(
            ResourceOperation::BrowserNavigate,
            Map::from_iter([("browser".to_string(), json!(reuse.browser.as_str()))]),
            json!({"url": self.url}),
            Some(&steps.navigate),
        )?;
        let selectors = ResourceSelectors {
            machine: self.request.selectors.machine.clone(),
            session: self.request.selectors.session.clone(),
            tab: Some(reuse.tab.as_str().to_string()),
            ..Default::default()
        };
        let mutation = crate::WorkspaceMutation::new(
            steps.select.clone(),
            "resource-api",
            self.request.actor.clone(),
        )
        .map_err(resource_operation_error)?;
        let selected = self
            .mux
            .commit_tab_selection_keeping_focus(selectors, &mutation)
            .map_err(resource_operation_error)?;
        let workspace = navigated["value"]["workspace_id"].clone();
        let value = json!({
            "kind": "browser",
            "workspace_id": workspace,
            "screen_id": side.screen.as_ref().map(ScreenPublicId::as_str),
            "pane_id": reuse.pane.as_str(),
            "tab_id": reuse.tab.as_str(),
            "browser_id": reuse.browser.as_str(),
            "reused": true,
        });
        let replayed = navigated["replayed"] == true && selected.replayed;
        mutation_result(self.mux, value, selected.revision, replayed)
    }
}

fn with_reused(mut result: Value, reused: bool) -> Value {
    result["value"]["reused"] = json!(reused);
    result
}
