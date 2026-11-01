//! `workspace.open_url {workspace?, url}` (`workspace-open-url-v1`,
//! cx-ebm.59.3): a web link opens on the right side of a workspace, for
//! every client (the Chief chat in Home, a page, the CLI). The one rule:
//!
//! 1. Only an `http` or `https` URL with a host and no user name or
//!    password, at most 8192 bytes, with no control, space, or invisible
//!    format character (bidi overrides, zero-width marks); anything else is
//!    `validation.invalid` (field `url`). An omitted workspace is the home
//!    workspace.
//! 2. The target screen is the workspace's focused screen. Its right side is
//!    every pane outside a docked column that is the agent chat dock (role
//!    `agent_chat`) or pinned to the left edge.
//! 3. Reuse: the selected browser tab of the focused right-side pane, else of
//!    the right-side pane focused most recently (then layout order), else any
//!    browser tab on the right side. It navigates and becomes its pane's
//!    selected tab; the keyboard focus stays. A frontend-rendered tab
//!    navigates through its frontend record (`update-frontend-browser-tab`
//!    URL semantics: the hosting app loads the new URL), a daemon-rendered
//!    one through the browser's navigation queue (raw `browser-navigate`
//!    semantics). The answer means the navigation is queued, not that the
//!    page loaded, so a slow or stuck page cannot hold the caller (the CLI
//!    gives up after 10 seconds). A browser still starting loads the link
//!    when it attaches; a navigation that fails after the answer shows as
//!    the browser's status, not as an error of this request; a newer
//!    open-url or navigation of the same browser supersedes one still
//!    pending (latest wins).
//! 4. Else a new browser tab in the first of those panes. When a connected
//!    client renders browser tabs itself (it declared
//!    `frontend-browser-tabs-v1`: the cmux app), the daemon makes a frontend
//!    browser tab through the `new-frontend-browser-tab` commit (selected,
//!    right after the pane's selected tab), and reuse takes only frontend
//!    tabs. Else `tab.create_browser` makes a cmux-browser tab. A workspace
//!    with no screen (a fresh Home) gets the screen and pane that
//!    `tab.create_browser` makes for it, holding a frontend tab when the app
//!    renders browsers.
//! 5. Else (only the dock) a browser in a new viewport column right of the
//!    dock (`pane-browser-kind-v1`'s `pane.split`; a frontend tab when the
//!    app renders browsers), and the focus goes back to the pane that had
//!    it. A frontend tab made with its pane registers its record under the
//!    create step's key first, as `new-frontend-browser-tab` does.
//!
//! The request's key records its result in the session's mutation ledger:
//! a retry with the same key and request answers the first result (the
//! same tab, no second navigation) even after the selection changed, and the
//! same key with another workspace or URL is `idempotency.conflict`. Each
//! creation, split, focus and tab selection step also runs under a key
//! derived from the request's key, so a retry after a step that committed
//! before the ledger did replays that step. The daemon navigation has no
//! step key: a retry after a queued navigation that the ledger missed
//! queues the same URL again.
//! Errors of a step (`engine_unavailable` with no browser provider, a
//! browser that failed for good) are returned as they are and record
//! nothing.

use std::cmp::Reverse;
use std::sync::Arc;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::{
    ParsedResourceRequest, dispatch_resource_request, required_string, resource_operation_error,
    validate_resource_envelope,
};
use crate::history_ops::ledger;
use crate::model::{DockEdge, DockRole};
use crate::mux::{FrontendTabPlacement, PANE_BROWSER_URL_FIELD};
use crate::resource::{
    BrowserPublicId, ContentPublicId, PanePublicId, RequestEnvelope, ResourceError,
    ResourceOperation, ScreenPublicId, TabPublicId, WorkspacePublicId,
};
use crate::server::FRONTEND_BROWSER_TABS_CAPABILITY;
use crate::workspace_registry::FrontendBrowserRecord;
use crate::{Mux, PaneId, ResourceSelectors, ResourceTarget, Surface, SurfaceId, SurfaceKind};
use cmux_json::JsonSet as _;

/// Advertised by `identify`: `workspace.open_url`.
pub(crate) const CAPABILITY: &str = "workspace-open-url-v1";
const OPERATION: &str = "workspace.open_url";
const MAX_URL_BYTES: usize = 8192;
/// Width of the column a link opens right of a lone dock.
const NEW_COLUMN_WIDTH: f32 = crate::mux::LONE_DOCK_NEIGHBOR_WIDTH;

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
    let fingerprint = ledger::fingerprint(
        OPERATION,
        &Map::from_iter([
            ("workspace".to_string(), json!(workspace.as_str())),
            ("url".to_string(), json!(url)),
        ]),
    );
    // A retry answers the first result, or refuses another request.
    if ledger::seen(mux, &key, OPERATION)? {
        return ledger::commit(mux, &key, OPERATION, &fingerprint, &Value::Null, &request.actor);
    }
    let value = open(mux, &request, &workspace, &url, &key)?;
    ledger::commit(mux, &key, OPERATION, &fingerprint, &value, &request.actor)
}

/// Open `url` in `workspace`: the value of the result.
fn open(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
    workspace: &WorkspacePublicId,
    url: &str,
    key: &str,
) -> Result<Value, ResourceError> {
    let steps = StepKeys::new(key, workspace, url);
    // A request whose create step committed before its ledger entry.
    if let Some(created) = created_before(mux, &steps)? {
        return Ok(created);
    }
    if let Some(created) = frontend_created_before(mux, &steps, workspace)? {
        return Ok(created);
    }
    let frontend = mux.control_clients.any_client_supports(FRONTEND_BROWSER_TABS_CAPABILITY);
    let candidates = mux.with_state(|state| right_side(state, workspace));
    let Some(candidates) = candidates else {
        return Err(ResourceError::not_found("workspace", workspace.as_str()));
    };
    let call = Call { mux, request, url, workspace };
    if let Some(reuse) = reusable_browser(mux, &candidates, frontend) {
        return call.reuse(&steps, &candidates, reuse);
    }
    match (candidates.ranked.first(), candidates.dock.as_ref()) {
        (Some(pane), _) if frontend => call.create_frontend_browser(pane, &candidates, &steps),
        (Some(pane), _) => call.create_browser("pane", pane.id.as_str(), &steps),
        (None, Some(dock)) => call.new_column(dock, candidates.focused.as_ref(), &steps, frontend),
        (None, None) if frontend => call.create_frontend_in_workspace(&steps),
        (None, None) => call.create_browser("workspace", workspace.as_str(), &steps),
    }
}

/// An http(s) URL with a host and no credentials (the guest URL opener's
/// rule, url_open.rs, plus invisible characters and user info: a link must
/// look like the page it opens).
pub(crate) fn is_web_url(raw: &str) -> bool {
    raw.len() <= MAX_URL_BYTES
        && !raw.chars().any(|c| c.is_control() || c.is_whitespace() || is_invisible_format(c))
        && url::Url::parse(raw).is_ok_and(|url| {
            matches!(url.scheme(), "http" | "https")
                && url.host_str().is_some_and(|h| !h.is_empty())
                && url.username().is_empty()
                && url.password().is_none()
        })
}

/// Unicode format characters that change how a URL reads without showing:
/// bidi marks and overrides, zero-width characters, the byte order mark.
fn is_invisible_format(c: char) -> bool {
    matches!(
        c,
        '\u{00AD}'
            | '\u{061C}'
            | '\u{180E}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}'
    )
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
            select: format!("open-url-select-{hash}"),
        }
    }
}

/// One pane of the right side and its tabs, in strip order.
struct RightPane {
    pane: PaneId,
    id: PanePublicId,
    active: Option<SurfaceId>,
    tabs: Vec<(SurfaceId, Arc<Surface>)>,
}

/// The pane a new tab of `workspace` goes to when the request names no pane
/// or screen and the workspace's focused pane is its left chat dock: the
/// right-side pane a link would open in (focused most recently, then layout
/// order), so a tab never lands in the chat dock (cx-ebm.59.5). `None` keeps
/// the focused pane (no dock focused, no right side, or a request that names
/// anything below the workspace).
pub(crate) fn right_pane_beside_focused_dock(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Option<PanePublicId> {
    let below = [
        &selectors.screen,
        &selectors.pane,
        &selectors.tab,
        &selectors.terminal,
        &selectors.browser,
        &selectors.frontend_projection,
    ];
    if selectors.workspace.is_none() || below.iter().any(|selector| selector.is_some()) {
        return None;
    }
    let workspace =
        mux.resolve_resource_path(ResourceTarget::Workspace, selectors).ok()?.workspace?;
    mux.with_state(|state| {
        let side = right_side(state, &workspace)?;
        let dock_focused = side.dock.is_some() && side.dock == side.focused;
        dock_focused.then(|| side.ranked.first().map(|pane| pane.id.clone())).flatten()
    })
}

/// The target screen's right side, best pane first, its dock pane, and the
/// pane that has the screen's focus.
struct RightSide {
    screen: Option<ScreenPublicId>,
    ranked: Vec<RightPane>,
    dock: Option<PanePublicId>,
    focused: Option<PanePublicId>,
}

/// Read under the state lock; conversation and remote tabs are filtered
/// after it (their records live in the registry, locked before the state).
fn right_side(state: &crate::State, workspace: &WorkspacePublicId) -> Option<RightSide> {
    let workspace = state.workspaces.iter().find(|candidate| candidate.public_id == *workspace)?;
    let Some(screen) = workspace.active_screen_ref().or_else(|| workspace.screens.first()) else {
        return Some(RightSide { screen: None, ranked: Vec::new(), dock: None, focused: None });
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
                pane: id,
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
    Some(RightSide {
        screen: Some(screen.public_id.clone()),
        ranked,
        dock,
        focused: public(screen.active_pane),
    })
}

/// A browser tab the link may reuse: its pane, surface, tab and browser,
/// and whether a frontend renders it.
struct Reuse {
    pane: PanePublicId,
    surface: SurfaceId,
    tab: TabPublicId,
    browser: BrowserPublicId,
    frontend: bool,
}

fn browser_page(mux: &Mux, surface: &Surface) -> Option<(TabPublicId, BrowserPublicId)> {
    if surface.kind() != SurfaceKind::Browser || mux.refuse_conversation_browser(surface).is_err() {
        return None;
    }
    let identity = surface.resource_identity()?;
    let ContentPublicId::Browser(browser) = &identity.content_id else { return None };
    Some((identity.tab_id.clone(), browser.clone()))
}

/// With `frontend_only` (a frontend renders browser tabs), only a
/// frontend-rendered tab: the app cannot show a cmux-browser page.
fn reusable_browser(mux: &Mux, side: &RightSide, frontend_only: bool) -> Option<Reuse> {
    let reuse = |pane: &RightPane, surface: &Surface| {
        let frontend = mux.is_frontend_browser_surface(surface);
        if frontend_only && !frontend {
            return None;
        }
        browser_page(mux, surface).map(|(tab, browser)| Reuse {
            pane: pane.id.clone(),
            surface: surface.id,
            tab,
            browser,
            frontend,
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

/// A created step's value, when this request's `tab.create_browser` step
/// already ran.
fn created_before(mux: &Arc<Mux>, steps: &StepKeys) -> Result<Option<Value>, ResourceError> {
    let resolution =
        mux.resource_creation_resolution(&steps.create).map_err(resource_operation_error)?;
    if resolution["state"] != "created" || resolution["created_path"]["kind"] != "browser" {
        return Ok(None);
    }
    let mut value = resolution["created_path"].clone();
    value.set("reused", json!(false));
    Ok(Some(value))
}

/// A created frontend tab's value, when this request's frontend create step
/// already ran and its tab is still placed.
fn frontend_created_before(
    mux: &Mux,
    steps: &StepKeys,
    workspace: &WorkspacePublicId,
) -> Result<Option<Value>, ResourceError> {
    let surface =
        mux.keyed_frontend_browser_tab(&steps.create).map_err(resource_operation_error)?;
    let Some(surface) = surface else { return Ok(None) };
    let Some((tab, browser)) = browser_page(mux, &surface) else { return Ok(None) };
    let place = mux.with_state(|state| {
        let pane = state.pane_of(surface.id)?;
        let pane_id = state.resource_indexes.pane_ids.get(&pane)?.clone();
        let screen = state
            .workspaces
            .iter()
            .flat_map(|candidate| candidate.screens.iter())
            .find(|screen| screen.root.pane_ids_vec().contains(&pane))?;
        Some((pane_id, screen.public_id.clone()))
    });
    let Some((pane, screen)) = place else { return Ok(None) };
    Ok(Some(json!({
        "kind": "browser",
        "workspace_id": workspace.as_str(),
        "screen_id": screen.as_str(),
        "pane_id": pane.as_str(),
        "tab_id": tab.as_str(),
        "browser_id": browser.as_str(),
        "reused": false,
    })))
}

struct Call<'a> {
    mux: &'a Arc<Mux>,
    request: &'a ParsedResourceRequest,
    url: &'a str,
    workspace: &'a WorkspacePublicId,
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
        let mut value = created["value"].clone();
        value.set("reused", json!(false));
        Ok(value)
    }

    /// A frontend browser tab in `pane` (the `new-frontend-browser-tab`
    /// commit, under the create step's key): the pane's selected tab, right
    /// after the tab that was selected; the keyboard focus stays.
    fn create_frontend_browser(
        &self,
        pane: &RightPane,
        side: &RightSide,
        steps: &StepKeys,
    ) -> Result<Value, ResourceError> {
        let record = self.frontend_record();
        let placement = FrontendTabPlacement { activate: true, after: pane.active, index: None };
        let outcome = self
            .mux
            .new_frontend_browser_tab_keyed_as(
                &self.request.actor,
                Some(pane.pane),
                record,
                None,
                &steps.create,
                placement,
            )
            .map_err(resource_operation_error)?;
        let Some((tab, browser)) = browser_page(self.mux, &outcome.surface) else {
            return Err(ResourceError::operation_failed(
                OPERATION,
                "the new browser tab has no public tab or browser id",
                json!({}),
            ));
        };
        Ok(json!({
            "kind": "browser",
            "workspace_id": self.workspace.as_str(),
            "screen_id": side.screen.as_ref().map(ScreenPublicId::as_str),
            "pane_id": pane.id.as_str(),
            "tab_id": tab.as_str(),
            "browser_id": browser.as_str(),
            "reused": false,
        }))
    }

    fn frontend_record(&self) -> FrontendBrowserRecord {
        FrontendBrowserRecord {
            // The person's `browser.siteEngines` rule for the URL, else
            // `browser.defaultEngine` (Chromium unless set to WebKit), as for a
            // tab the person opens.
            engine: crate::browser_profile_ops::default_engine_for(self.mux, self.url).to_string(),
            url: self.url.to_string(),
            title: None,
            favicon_url: None,
            profile_id: None,
            owner: None,
        }
    }

    /// A frontend browser tab in a workspace with no screen: the screen and
    /// pane that `tab.create_browser` makes for it.
    fn create_frontend_in_workspace(&self, steps: &StepKeys) -> Result<Value, ResourceError> {
        let selectors = ResourceSelectors {
            machine: self.request.selectors.machine.clone(),
            session: self.request.selectors.session.clone(),
            workspace: Some(self.workspace.as_str().to_string()),
            ..Default::default()
        };
        let fields = Map::from_iter([("url".to_string(), json!(self.url))]);
        self.commit_create(ResourceOperation::TabCreateBrowser, selectors, fields, steps, true)
    }

    /// Commit the create step `operation` under its key. With `frontend`,
    /// the browser it makes is a frontend tab whose record is registered
    /// under the step's key first (`new-frontend-browser-tab`'s keyed path),
    /// and the value is that tab's place.
    fn commit_create(
        &self,
        operation: ResourceOperation,
        selectors: ResourceSelectors,
        fields: Map<String, Value>,
        steps: &StepKeys,
        frontend: bool,
    ) -> Result<Value, ResourceError> {
        let mutation = crate::WorkspaceMutation::new(
            steps.create.clone(),
            "resource-api",
            self.request.actor.clone(),
        )
        .map_err(resource_operation_error)?;
        let commit = |fields| {
            self.mux
                .resource_topology_operation(operation, selectors, fields, None, &mutation)
                .map(|commit| commit.result)
        };
        if !frontend {
            let mut value = commit(fields).map_err(resource_operation_error)?;
            value.set("reused", json!(false));
            return Ok(value);
        }
        let fingerprint = json!({
            "operation": OPERATION,
            "step": super::operation_name(operation),
            "workspace": self.workspace.as_str(),
            "url": self.url,
        });
        self.mux
            .keyed_frontend_browser(&steps.create, self.frontend_record(), fingerprint, |id| {
                let mut fields = fields;
                fields.insert("frontend_browser_id".to_string(), json!(id.as_str()));
                commit(fields)
            })
            .map_err(resource_operation_error)?;
        frontend_created_before(self.mux, steps, self.workspace)?.ok_or_else(|| {
            ResourceError::operation_failed(
                OPERATION,
                "the new browser tab is not placed",
                json!({}),
            )
        })
    }

    /// A browser in a new viewport column right of the lone dock pane; with
    /// `frontend`, a frontend browser tab.
    fn new_column(
        &self,
        dock: &PanePublicId,
        focused: Option<&PanePublicId>,
        steps: &StepKeys,
        frontend: bool,
    ) -> Result<Value, ResourceError> {
        if !frontend && let Some(error) = self.mux.browser_engine_unavailable(OPERATION) {
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
        let value =
            self.commit_create(ResourceOperation::PaneSplit, selectors, fields, steps, frontend)?;
        // A new pane takes the focus; it goes back to the pane that had it.
        if let Some(focused) = focused.filter(|pane| value["pane_id"] != pane.as_str()) {
            self.inner(
                ResourceOperation::PaneFocus,
                Map::from_iter([("pane".to_string(), json!(focused.as_str()))]),
                json!({}),
                Some(&steps.select),
            )?;
        }
        Ok(value)
    }

    /// Navigate the reused browser, then select its tab in its pane.
    fn reuse(
        &self,
        steps: &StepKeys,
        side: &RightSide,
        reuse: Reuse,
    ) -> Result<Value, ResourceError> {
        if reuse.frontend {
            // The hosting app loads the URL its record now names.
            self.mux
                .update_frontend_browser_tab_with_owner_as(
                    &self.request.actor,
                    reuse.surface,
                    Some(self.url.to_string()),
                    None,
                    None,
                    None,
                )
                .map_err(resource_operation_error)?;
        } else {
            // Queued, not confirmed: a confirmed `browser.navigate` waits for
            // the page's answer (up to the CDP timeout), longer than any
            // caller waits for this request.
            let surface = self
                .mux
                .surface(reuse.surface)
                .ok_or_else(|| ResourceError::not_found("browser", reuse.browser.as_str()))?;
            self.mux.navigate_browser_surface(&surface, self.url).map_err(|error| {
                ResourceError::operation_failed(
                    "browser.navigate",
                    error.to_string(),
                    json!({"browser_id": reuse.browser.as_str()}),
                )
            })?;
        }
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
        self.mux
            .commit_tab_selection_keeping_focus(selectors, &mutation)
            .map_err(resource_operation_error)?;
        Ok(json!({
            "kind": "browser",
            "workspace_id": self.workspace.as_str(),
            "screen_id": side.screen.as_ref().map(ScreenPublicId::as_str),
            "pane_id": reuse.pane.as_str(),
            "tab_id": reuse.tab.as_str(),
            "browser_id": reuse.browser.as_str(),
            "reused": true,
        }))
    }
}
