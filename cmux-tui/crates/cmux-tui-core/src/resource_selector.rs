use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::model::State;
use crate::resource::{
    BrowserPublicId, ContentPublicId, MachinePublicId, PanePublicId, ResourceError, ScreenPublicId,
    Selector, SessionPublicId, TabPublicId, TerminalPublicId, WorkspacePublicId, resolve_name,
};
use crate::{PaneId, ScreenId, SurfaceId, WorkspaceId};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceTarget {
    Machine,
    Session,
    Workspace,
    Screen,
    Pane,
    Tab,
    Terminal,
    Browser,
}

impl ResourceTarget {
    fn depth(self) -> usize {
        match self {
            Self::Machine => 0,
            Self::Session => 1,
            Self::Workspace => 2,
            Self::Screen => 3,
            Self::Pane => 4,
            Self::Tab => 5,
            Self::Terminal | Self::Browser => 6,
        }
    }

    fn kind(self) -> &'static str {
        match self {
            Self::Machine => "machine",
            Self::Session => "session",
            Self::Workspace => "workspace",
            Self::Screen => "screen",
            Self::Pane => "pane",
            Self::Tab => "tab",
            Self::Terminal => "terminal",
            Self::Browser => "browser",
        }
    }
}

/// Flat selectors from one `cmux.protocol/2` request. Machine and session are
/// optional here because machine-list and machine-scoped operations have
/// shallower routing requirements. Structural session resources require both.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ResourceSelectors {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screen: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tab: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub browser: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub split: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notification: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frontend_projection: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pairing_request: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sidebar_view: Option<String>,
}

impl ResourceSelectors {
    fn at_depth(&self, target: ResourceTarget, depth: usize) -> Option<&str> {
        match depth {
            0 => self.machine.as_deref(),
            1 => self.session.as_deref(),
            2 => self.workspace.as_deref(),
            3 => self.screen.as_deref(),
            4 => self.pane.as_deref(),
            5 => self.tab.as_deref(),
            6 if target == ResourceTarget::Terminal => self.terminal.as_deref(),
            6 if target == ResourceTarget::Browser => self.browser.as_deref(),
            _ => None,
        }
    }

    fn unexpected_below(&self, target: ResourceTarget) -> Option<&'static str> {
        let fields = [
            ("machine", self.machine.is_some()),
            ("session", self.session.is_some()),
            ("workspace", self.workspace.is_some()),
            ("screen", self.screen.is_some()),
            ("pane", self.pane.is_some()),
            ("tab", self.tab.is_some()),
        ];
        fields
            .into_iter()
            .enumerate()
            .find_map(|(depth, (kind, present))| {
                (present && depth > target.depth()).then_some(kind)
            })
            .or_else(|| {
                (self.terminal.is_some() && target != ResourceTarget::Terminal)
                    .then_some("terminal")
            })
            .or_else(|| {
                (self.browser.is_some() && target != ResourceTarget::Browser).then_some("browser")
            })
            .or_else(|| self.client.is_some().then_some("client"))
            .or_else(|| self.split.is_some().then_some("split"))
            .or_else(|| self.stream.is_some().then_some("stream"))
            .or_else(|| self.notification.is_some().then_some("notification"))
            .or_else(|| self.agent.is_some().then_some("agent"))
            .or_else(|| self.frontend_projection.is_some().then_some("frontend_projection"))
            .or_else(|| self.pairing_request.is_some().then_some("pairing_request"))
            .or_else(|| self.sidebar_view.is_some().then_some("sidebar_view"))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolvedResourcePath {
    pub machine: MachinePublicId,
    pub session: Option<SessionPublicId>,
    pub workspace: Option<WorkspacePublicId>,
    pub screen: Option<ScreenPublicId>,
    pub pane: Option<PanePublicId>,
    pub tab: Option<TabPublicId>,
    pub terminal: Option<TerminalPublicId>,
    pub browser: Option<BrowserPublicId>,
}

#[derive(Debug, Clone)]
pub(crate) struct ResourceSelectorContext<'a> {
    pub machine_id: &'a MachinePublicId,
    pub machine_name: Option<&'a str>,
    pub session_id: &'a SessionPublicId,
    pub session_name: &'a str,
}

#[derive(Debug, Clone)]
pub(crate) struct ResolvedResourceSlots {
    pub path: ResolvedResourcePath,
    pub workspace: Option<WorkspaceId>,
    pub screen: Option<ScreenId>,
    pub pane: Option<PaneId>,
    pub tab: Option<SurfaceId>,
}

pub(crate) fn resolve_resource_selectors(
    state: &State,
    context: ResourceSelectorContext<'_>,
    target: ResourceTarget,
    selectors: &ResourceSelectors,
) -> Result<ResolvedResourceSlots, ResourceError> {
    if let Some(unexpected) = selectors.unexpected_below(target) {
        return Err(invalid_selector(
            target.kind(),
            format!("selector {unexpected:?} is below the {target:?} target"),
            json!({"target":target.kind(),"unexpected":unexpected}),
        ));
    }
    if selectors.terminal.is_some() && selectors.browser.is_some() {
        return Err(invalid_selector(
            target.kind(),
            "terminal and browser selectors are mutually exclusive",
            json!({"target":target.kind()}),
        ));
    }

    let machine_raw = require_selector(selectors.machine.as_deref(), "machine")?;
    let machine = resolve_singleton(
        "machine",
        machine_raw,
        context.machine_id,
        context.machine_name,
        MachinePublicId::parse,
    )?;
    if target == ResourceTarget::Machine {
        require_target_selector(selectors, target)?;
        return Ok(ResolvedResourceSlots {
            path: ResolvedResourcePath {
                machine,
                session: None,
                workspace: None,
                screen: None,
                pane: None,
                tab: None,
                terminal: None,
                browser: None,
            },
            workspace: None,
            screen: None,
            pane: None,
            tab: None,
        });
    }

    let session_raw = require_selector(selectors.session.as_deref(), "session")?;
    let session = resolve_singleton(
        "session",
        session_raw,
        context.session_id,
        Some(context.session_name),
        SessionPublicId::parse,
    )?;
    if target == ResourceTarget::Session {
        require_target_selector(selectors, target)?;
        return Ok(ResolvedResourceSlots {
            path: ResolvedResourcePath {
                machine,
                session: Some(session),
                workspace: None,
                screen: None,
                pane: None,
                tab: None,
                terminal: None,
                browser: None,
            },
            workspace: None,
            screen: None,
            pane: None,
            tab: None,
        });
    }

    require_target_selector(selectors, target)?;
    validate_contiguous_name_current_chains(selectors, target)?;

    let mut supplied_workspace = None;
    let mut supplied_screen = None;
    let mut supplied_pane = None;
    let mut supplied_tab = None;

    if let Some(raw) = selectors.workspace.as_deref() {
        supplied_workspace = Some(resolve_workspace(state, raw)?);
    }
    if let Some(raw) = selectors.screen.as_deref() {
        supplied_screen = Some(resolve_screen(state, raw, supplied_workspace)?);
    }
    if let Some(raw) = selectors.pane.as_deref() {
        supplied_pane = Some(resolve_pane(state, raw, supplied_screen)?);
    }
    if let Some(raw) = selectors.tab.as_deref() {
        supplied_tab = Some(resolve_tab(state, raw, supplied_pane)?);
    }

    let mut target_terminal = None;
    let mut target_browser = None;
    let target_tab = match target {
        ResourceTarget::Terminal => {
            let raw = selectors.terminal.as_deref().expect("target selector checked");
            let (slot, id) = resolve_terminal(
                state,
                raw,
                supplied_tab,
                supplied_pane,
                supplied_screen,
                supplied_workspace,
            )?;
            target_terminal = Some(id);
            Some(slot)
        }
        ResourceTarget::Browser => {
            let raw = selectors.browser.as_deref().expect("target selector checked");
            let (slot, id) = resolve_browser(state, raw, supplied_tab)?;
            target_browser = Some(id);
            Some(slot)
        }
        ResourceTarget::Tab => supplied_tab,
        _ => None,
    };
    let target_pane = match target {
        ResourceTarget::Terminal | ResourceTarget::Browser | ResourceTarget::Tab => {
            target_tab.and_then(|tab| state.resource_indexes.tab_pane.get(&tab).copied())
        }
        ResourceTarget::Pane => supplied_pane,
        _ => None,
    };
    let target_screen = match target {
        ResourceTarget::Terminal
        | ResourceTarget::Browser
        | ResourceTarget::Tab
        | ResourceTarget::Pane => {
            target_pane.and_then(|pane| state.resource_indexes.pane_screen.get(&pane).copied())
        }
        ResourceTarget::Screen => supplied_screen,
        _ => None,
    };
    let target_workspace = match target {
        ResourceTarget::Terminal
        | ResourceTarget::Browser
        | ResourceTarget::Tab
        | ResourceTarget::Pane
        | ResourceTarget::Screen => target_screen
            .and_then(|screen| state.resource_indexes.screen_workspace.get(&screen).copied()),
        ResourceTarget::Workspace => supplied_workspace,
        _ => None,
    };

    // A terminal is a session-owned content resource, so it remains
    // addressable after its last tab has been detached. Topology ancestors
    // are present only when this resolution selected a concrete view.
    if target == ResourceTarget::Terminal && target_pane.is_none() {
        let terminal_id =
            target_terminal.as_ref().expect("resolved terminal target omitted its public identity");
        if let Some(pane) = supplied_pane {
            return Err(wrong_parent(
                "target",
                terminal_id.as_str(),
                "pane",
                public_pane_id(state, pane)?.to_string(),
                None,
            ));
        }
        if let Some(screen) = supplied_screen {
            return Err(wrong_parent(
                "target",
                terminal_id.as_str(),
                "screen",
                public_screen_id(state, screen)?.to_string(),
                None,
            ));
        }
        if let Some(workspace) = supplied_workspace {
            return Err(wrong_parent(
                "target",
                terminal_id.as_str(),
                "workspace",
                public_workspace_id(state, workspace)?.to_string(),
                None,
            ));
        }
        return Ok(ResolvedResourceSlots {
            path: ResolvedResourcePath {
                machine,
                session: Some(session),
                workspace: None,
                screen: None,
                pane: None,
                tab: None,
                terminal: target_terminal,
                browser: None,
            },
            workspace: None,
            screen: None,
            pane: None,
            tab: None,
        });
    }

    let target_workspace = require_resolved_slot(target_workspace, "workspace")?;
    validate_supplied_parent(
        state,
        "workspace",
        supplied_workspace,
        target_workspace,
        target_public_id(state, target, target_workspace, target_screen, target_pane, target_tab)?,
        |slot| public_workspace_id(state, slot).map(ToString::to_string),
    )?;
    if target.depth() >= ResourceTarget::Screen.depth() {
        let target_screen = require_resolved_slot(target_screen, "screen")?;
        validate_supplied_parent(
            state,
            "screen",
            supplied_screen,
            target_screen,
            target_public_id(
                state,
                target,
                target_workspace,
                Some(target_screen),
                target_pane,
                target_tab,
            )?,
            |slot| public_screen_id(state, slot).map(ToString::to_string),
        )?;
    }
    if target.depth() >= ResourceTarget::Pane.depth() {
        let target_pane = require_resolved_slot(target_pane, "pane")?;
        validate_supplied_parent(
            state,
            "pane",
            supplied_pane,
            target_pane,
            target_public_id(
                state,
                target,
                target_workspace,
                target_screen,
                Some(target_pane),
                target_tab,
            )?,
            |slot| public_pane_id(state, slot).map(ToString::to_string),
        )?;
    }
    if target.depth() >= ResourceTarget::Tab.depth() {
        let target_tab = require_resolved_slot(target_tab, "tab")?;
        validate_supplied_parent(
            state,
            "tab",
            supplied_tab,
            target_tab,
            target_public_id(
                state,
                target,
                target_workspace,
                target_screen,
                target_pane,
                Some(target_tab),
            )?,
            |slot| public_tab_id(state, slot).map(ToString::to_string),
        )?;
    }

    let workspace_id = state
        .resource_indexes
        .workspace_ids
        .get(&target_workspace)
        .cloned()
        .ok_or_else(|| ResourceError::not_found("workspace", "<resolved>"))?;
    let screen_id = target_screen
        .map(|slot| {
            state
                .resource_indexes
                .screen_ids
                .get(&slot)
                .cloned()
                .ok_or_else(|| ResourceError::not_found("screen", "<resolved>"))
        })
        .transpose()?;
    let pane_id = target_pane
        .map(|slot| {
            state
                .resource_indexes
                .pane_ids
                .get(&slot)
                .cloned()
                .ok_or_else(|| ResourceError::not_found("pane", "<resolved>"))
        })
        .transpose()?;
    let tab_id = target_tab
        .map(|slot| {
            state
                .resource_indexes
                .tab_ids
                .get(&slot)
                .cloned()
                .ok_or_else(|| ResourceError::not_found("tab", "<resolved>"))
        })
        .transpose()?;
    Ok(ResolvedResourceSlots {
        path: ResolvedResourcePath {
            machine,
            session: Some(session),
            workspace: Some(workspace_id),
            screen: screen_id,
            pane: pane_id,
            tab: tab_id,
            terminal: target_terminal,
            browser: target_browser,
        },
        workspace: Some(target_workspace),
        screen: target_screen,
        pane: target_pane,
        tab: target_tab,
    })
}

fn validate_contiguous_name_current_chains(
    selectors: &ResourceSelectors,
    target: ResourceTarget,
) -> Result<(), ResourceError> {
    let structural = [
        ("workspace", selectors.workspace.as_deref()),
        ("screen", selectors.screen.as_deref()),
        ("pane", selectors.pane.as_deref()),
        ("tab", selectors.tab.as_deref()),
    ];
    for (index, (kind, raw)) in structural.iter().enumerate() {
        let Some(raw) = raw else { continue };
        if matches!(Selector::parse(raw)?, Selector::Id(_)) {
            continue;
        }
        for (missing, parent) in structural[..index].iter().rev() {
            if parent.is_none() {
                return Err(incomplete_chain(kind, missing));
            }
        }
    }
    if target.depth() == 6 {
        let raw = selectors.at_depth(target, 6).expect("target selector checked");
        if !matches!(Selector::parse(raw)?, Selector::Id(_)) {
            for (missing, parent) in structural.iter().rev() {
                if parent.is_none() {
                    return Err(incomplete_chain(target.kind(), missing));
                }
            }
        }
    }
    Ok(())
}

fn require_target_selector(
    selectors: &ResourceSelectors,
    target: ResourceTarget,
) -> Result<(), ResourceError> {
    if selectors.at_depth(target, target.depth()).is_none() {
        return Err(invalid_selector(
            target.kind(),
            format!("missing required {} selector", target.kind()),
            json!({"missing":target.kind()}),
        ));
    }
    Ok(())
}

fn require_selector<'a>(selector: Option<&'a str>, kind: &str) -> Result<&'a str, ResourceError> {
    selector.ok_or_else(|| {
        invalid_selector(
            kind,
            format!("missing required {kind} routing selector"),
            json!({"missing":kind}),
        )
    })
}

fn require_resolved_slot<T>(slot: Option<T>, kind: &str) -> Result<T, ResourceError> {
    slot.ok_or_else(|| {
        invalid_selector(
            kind,
            format!("could not derive the target {kind} scope"),
            json!({"kind":kind}),
        )
    })
}

fn invalid_selector(
    kind: &str,
    message: impl Into<String>,
    details: serde_json::Value,
) -> ResourceError {
    let selector = details
        .get("selector")
        .or_else(|| details.get("unexpected"))
        .or_else(|| details.get("missing"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("<invalid>");
    ResourceError::selector_invalid(kind, selector, message)
}

fn incomplete_chain(kind: &str, parent: &str) -> ResourceError {
    invalid_selector(
        kind,
        format!("{kind} current/name selector requires a {parent} selector"),
        json!({"selector_kind":kind,"missing_parent":parent}),
    )
}

fn resolve_singleton<T: Clone + PartialEq + ToString>(
    kind: &str,
    raw: &str,
    expected: &T,
    expected_name: Option<&str>,
    parse_id: impl Fn(String) -> Result<T, ResourceError>,
) -> Result<T, ResourceError> {
    match Selector::parse(raw)? {
        Selector::Current => Ok(expected.clone()),
        Selector::Id(id) => {
            let id = parse_id(id)?;
            if &id == expected { Ok(id) } else { Err(ResourceError::not_found(kind, raw)) }
        }
        Selector::Name(name) if expected_name == Some(name.as_str()) => Ok(expected.clone()),
        Selector::Name(_) => Err(ResourceError::not_found(kind, raw)),
    }
}

fn resolve_workspace(state: &State, raw: &str) -> Result<WorkspaceId, ResourceError> {
    match Selector::parse(raw)? {
        Selector::Current => state
            .workspaces
            .get(state.active_workspace)
            .map(|workspace| workspace.id)
            .ok_or_else(|| ResourceError::not_found("workspace", raw)),
        Selector::Id(id) => {
            let id = WorkspacePublicId::parse(id)?;
            state
                .resource_indexes
                .workspaces
                .get(&id)
                .copied()
                .ok_or_else(|| ResourceError::not_found("workspace", raw))
        }
        Selector::Name(name) => resolve_name(
            "workspace",
            &name,
            state.workspaces.iter().map(|workspace| {
                (workspace.public_id.to_string(), Some(workspace.name.clone()), workspace.id)
            }),
        ),
    }
}

fn resolve_screen(
    state: &State,
    raw: &str,
    parent: Option<WorkspaceId>,
) -> Result<ScreenId, ResourceError> {
    let selector = Selector::parse(raw)?;
    let screen = match selector {
        Selector::Id(id) => {
            let id = ScreenPublicId::parse(id)?;
            state
                .resource_indexes
                .screens
                .get(&id)
                .copied()
                .ok_or_else(|| ResourceError::not_found("screen", raw))?
        }
        Selector::Current => {
            let parent = parent.ok_or_else(|| incomplete_chain("screen", "workspace"))?;
            let workspace = workspace_by_slot(state, parent)?;
            workspace
                .active_screen_ref()
                .map(|screen| screen.id)
                .ok_or_else(|| ResourceError::not_found("screen", raw))?
        }
        Selector::Name(name) => {
            let parent = parent.ok_or_else(|| incomplete_chain("screen", "workspace"))?;
            let workspace = workspace_by_slot(state, parent)?;
            resolve_name(
                "screen",
                &name,
                workspace
                    .screens
                    .iter()
                    .map(|screen| (screen.public_id.to_string(), screen.name.clone(), screen.id)),
            )?
        }
    };
    validate_immediate_parent(
        state,
        "screen",
        public_screen_id(state, screen)?.as_str(),
        "workspace",
        parent,
        state.resource_indexes.screen_workspace.get(&screen).copied(),
        |slot| public_workspace_id(state, slot).map(ToString::to_string),
    )?;
    Ok(screen)
}

fn resolve_pane(
    state: &State,
    raw: &str,
    parent: Option<ScreenId>,
) -> Result<PaneId, ResourceError> {
    let selector = Selector::parse(raw)?;
    let pane = match selector {
        Selector::Id(id) => {
            let id = PanePublicId::parse(id)?;
            state
                .resource_indexes
                .panes
                .get(&id)
                .copied()
                .ok_or_else(|| ResourceError::not_found("pane", raw))?
        }
        Selector::Current => {
            let parent = parent.ok_or_else(|| incomplete_chain("pane", "screen"))?;
            screen_by_slot(state, parent)?.active_pane
        }
        Selector::Name(name) => {
            let parent = parent.ok_or_else(|| incomplete_chain("pane", "screen"))?;
            resolve_name(
                "pane",
                &name,
                state
                    .panes
                    .values()
                    .filter(|pane| {
                        state.resource_indexes.pane_screen.get(&pane.id).copied() == Some(parent)
                    })
                    .map(|pane| (pane.public_id.to_string(), pane.name.clone(), pane.id)),
            )?
        }
    };
    validate_immediate_parent(
        state,
        "pane",
        public_pane_id(state, pane)?.as_str(),
        "screen",
        parent,
        state.resource_indexes.pane_screen.get(&pane).copied(),
        |slot| public_screen_id(state, slot).map(ToString::to_string),
    )?;
    Ok(pane)
}

fn resolve_tab(
    state: &State,
    raw: &str,
    parent: Option<PaneId>,
) -> Result<SurfaceId, ResourceError> {
    let selector = Selector::parse(raw)?;
    let tab = match selector {
        Selector::Id(id) => {
            let id = TabPublicId::parse(id)?;
            state
                .resource_indexes
                .tabs
                .get(&id)
                .copied()
                .ok_or_else(|| ResourceError::not_found("tab", raw))?
        }
        Selector::Current => {
            let parent = parent.ok_or_else(|| incomplete_chain("tab", "pane"))?;
            state
                .panes
                .get(&parent)
                .and_then(|pane| pane.active_surface())
                .ok_or_else(|| ResourceError::not_found("tab", raw))?
        }
        Selector::Name(name) => {
            let parent = parent.ok_or_else(|| incomplete_chain("tab", "pane"))?;
            let pane = state
                .panes
                .get(&parent)
                .ok_or_else(|| ResourceError::not_found("pane", "<resolved>"))?;
            resolve_name(
                "tab",
                &name,
                pane.tabs.iter().filter_map(|tab| {
                    let id = state.resource_indexes.tab_ids.get(tab)?;
                    let name = state.surfaces.get(tab).and_then(|surface| surface.name());
                    Some((id.to_string(), name, *tab))
                }),
            )?
        }
    };
    validate_immediate_parent(
        state,
        "tab",
        public_tab_id(state, tab)?.as_str(),
        "pane",
        parent,
        state.resource_indexes.tab_pane.get(&tab).copied(),
        |slot| public_pane_id(state, slot).map(ToString::to_string),
    )?;
    Ok(tab)
}

fn resolve_terminal(
    state: &State,
    raw: &str,
    parent: Option<SurfaceId>,
    pane: Option<PaneId>,
    screen: Option<ScreenId>,
    workspace: Option<WorkspaceId>,
) -> Result<(SurfaceId, TerminalPublicId), ResourceError> {
    match Selector::parse(raw)? {
        Selector::Id(id) => {
            let id = TerminalPublicId::parse(id)?;
            let content_id = ContentPublicId::Terminal(id.clone());
            let slot = parent
                .filter(|parent| {
                    state.resource_indexes.content_ids.get(parent) == Some(&content_id)
                })
                .or_else(|| {
                    state.resource_indexes.content_placements.get(&content_id).and_then(
                        |placements| {
                            placements
                                .iter()
                                .copied()
                                .find(|placement| {
                                    placement_matches_scope(
                                        state, *placement, pane, screen, workspace,
                                    )
                                })
                                // Keep a concrete out-of-scope placement so
                                // the normal parent validator reports
                                // selector.wrong_parent instead of hiding a
                                // live terminal as not found.
                                .or_else(|| placements.first().copied())
                        },
                    )
                })
                .or_else(|| state.terminal_catalog.get(&id).map(|surface| surface.id))
                .ok_or_else(|| ResourceError::not_found("terminal", raw))?;
            validate_content_parent(state, "terminal", id.as_str(), parent, slot)?;
            Ok((slot, id))
        }
        Selector::Current => {
            let parent = parent.ok_or_else(|| incomplete_chain("terminal", "tab"))?;
            match state.resource_indexes.content_ids.get(&parent) {
                Some(ContentPublicId::Terminal(id)) => Ok((parent, id.clone())),
                _ => Err(ResourceError::not_found("terminal", raw)),
            }
        }
        Selector::Name(name) => {
            let parent = parent.ok_or_else(|| incomplete_chain("terminal", "tab"))?;
            let id = match state.resource_indexes.content_ids.get(&parent) {
                Some(ContentPublicId::Terminal(id)) => id.clone(),
                _ => return Err(ResourceError::not_found("terminal", raw)),
            };
            let title =
                state.surfaces.get(&parent).map(|surface| surface.title()).unwrap_or_default();
            if title == name {
                Ok((parent, id))
            } else {
                Err(ResourceError::not_found("terminal", &name))
            }
        }
    }
}

fn placement_matches_scope(
    state: &State,
    placement: SurfaceId,
    pane: Option<PaneId>,
    screen: Option<ScreenId>,
    workspace: Option<WorkspaceId>,
) -> bool {
    let actual_pane = state.resource_indexes.tab_pane.get(&placement).copied();
    if pane.is_some_and(|pane| actual_pane != Some(pane)) {
        return false;
    }
    let actual_screen =
        actual_pane.and_then(|pane| state.resource_indexes.pane_screen.get(&pane).copied());
    if screen.is_some_and(|screen| actual_screen != Some(screen)) {
        return false;
    }
    let actual_workspace = actual_screen
        .and_then(|screen| state.resource_indexes.screen_workspace.get(&screen).copied());
    workspace.is_none_or(|workspace| actual_workspace == Some(workspace))
}

fn resolve_browser(
    state: &State,
    raw: &str,
    parent: Option<SurfaceId>,
) -> Result<(SurfaceId, BrowserPublicId), ResourceError> {
    match Selector::parse(raw)? {
        Selector::Id(id) => {
            let id = BrowserPublicId::parse(id)?;
            let slot = state
                .single_placement_of_content(&ContentPublicId::Browser(id.clone()))
                .ok_or_else(|| ResourceError::not_found("browser", raw))?;
            validate_content_parent(state, "browser", id.as_str(), parent, slot)?;
            Ok((slot, id))
        }
        Selector::Current => {
            let parent = parent.ok_or_else(|| incomplete_chain("browser", "tab"))?;
            match state.resource_indexes.content_ids.get(&parent) {
                Some(ContentPublicId::Browser(id)) => Ok((parent, id.clone())),
                _ => Err(ResourceError::not_found("browser", raw)),
            }
        }
        Selector::Name(name) => {
            let parent = parent.ok_or_else(|| incomplete_chain("browser", "tab"))?;
            let id = match state.resource_indexes.content_ids.get(&parent) {
                Some(ContentPublicId::Browser(id)) => id.clone(),
                _ => return Err(ResourceError::not_found("browser", raw)),
            };
            let title =
                state.surfaces.get(&parent).map(|surface| surface.title()).unwrap_or_default();
            if title == name {
                Ok((parent, id))
            } else {
                Err(ResourceError::not_found("browser", &name))
            }
        }
    }
}

fn validate_content_parent(
    state: &State,
    kind: &str,
    public_id: &str,
    parent: Option<SurfaceId>,
    actual: SurfaceId,
) -> Result<(), ResourceError> {
    validate_immediate_parent(state, kind, public_id, "tab", parent, Some(actual), |slot| {
        public_tab_id(state, slot).map(ToString::to_string)
    })
}

fn validate_immediate_parent<T: Copy + PartialEq>(
    _state: &State,
    child_kind: &str,
    child_id: &str,
    parent_kind: &str,
    selected: Option<T>,
    actual: Option<T>,
    render: impl Fn(T) -> Result<String, ResourceError>,
) -> Result<(), ResourceError> {
    if let Some(selected) = selected
        && Some(selected) != actual
    {
        return Err(wrong_parent(
            child_kind,
            child_id,
            parent_kind,
            render(selected)?,
            actual.map(&render).transpose()?,
        ));
    }
    Ok(())
}

fn validate_supplied_parent<T: Copy + PartialEq>(
    _state: &State,
    parent_kind: &str,
    supplied: Option<T>,
    actual: T,
    target_id: String,
    render: impl Fn(T) -> Result<String, ResourceError>,
) -> Result<(), ResourceError> {
    if let Some(supplied) = supplied
        && supplied != actual
    {
        return Err(wrong_parent(
            "target",
            &target_id,
            parent_kind,
            render(supplied)?,
            Some(render(actual)?),
        ));
    }
    Ok(())
}

fn wrong_parent(
    child_kind: &str,
    child_id: &str,
    parent_kind: &str,
    expected: String,
    actual: Option<String>,
) -> ResourceError {
    let child_scope = if child_kind == "target" {
        if child_id.starts_with("ws_") {
            "workspace"
        } else if child_id.starts_with("screen_") {
            "screen"
        } else if child_id.starts_with("pane_") {
            "pane"
        } else if child_id.starts_with("tab_") {
            "tab"
        } else if child_id.starts_with("term_") {
            "terminal"
        } else if child_id.starts_with("browser_") {
            "browser"
        } else {
            "pane"
        }
    } else {
        child_kind
    };
    ResourceError::new(
        "selector.wrong_parent",
        format!("{child_kind} {child_id} is outside the selected {parent_kind}"),
        json!({
            "scope":child_scope,
            "selector":child_id,
            "parent_scope":parent_kind,
            "expected_parent":expected,
            "actual_parent":actual.unwrap_or_else(|| "<none>".to_string()),
        }),
        false,
    )
}

fn target_public_id(
    state: &State,
    target: ResourceTarget,
    workspace: WorkspaceId,
    screen: Option<ScreenId>,
    pane: Option<PaneId>,
    tab: Option<SurfaceId>,
) -> Result<String, ResourceError> {
    match target {
        ResourceTarget::Workspace => state
            .resource_indexes
            .workspace_ids
            .get(&workspace)
            .map(ToString::to_string)
            .ok_or_else(|| ResourceError::not_found("workspace", "<resolved>")),
        ResourceTarget::Screen => public_screen_id(
            state,
            screen.ok_or_else(|| ResourceError::not_found("screen", "<resolved>"))?,
        )
        .map(|id| id.to_string()),
        ResourceTarget::Pane => public_pane_id(
            state,
            pane.ok_or_else(|| ResourceError::not_found("pane", "<resolved>"))?,
        )
        .map(|id| id.to_string()),
        ResourceTarget::Tab => {
            public_tab_id(state, tab.ok_or_else(|| ResourceError::not_found("tab", "<resolved>"))?)
                .map(|id| id.to_string())
        }
        ResourceTarget::Terminal | ResourceTarget::Browser => {
            let tab = tab.ok_or_else(|| ResourceError::not_found(target.kind(), "<resolved>"))?;
            state
                .resource_indexes
                .content_ids
                .get(&tab)
                .map(|id| id.as_str().to_string())
                .ok_or_else(|| ResourceError::not_found(target.kind(), "<resolved>"))
        }
        ResourceTarget::Machine | ResourceTarget::Session => {
            Err(ResourceError::not_found(target.kind(), "<resolved>"))
        }
    }
}

fn workspace_by_slot(state: &State, slot: WorkspaceId) -> Result<&crate::Workspace, ResourceError> {
    let index = state
        .workspace_index(slot)
        .ok_or_else(|| ResourceError::not_found("workspace", "<resolved>"))?;
    Ok(&state.workspaces[index])
}

fn screen_by_slot(state: &State, slot: ScreenId) -> Result<&crate::Screen, ResourceError> {
    let workspace = state
        .resource_indexes
        .screen_workspace
        .get(&slot)
        .copied()
        .ok_or_else(|| ResourceError::not_found("screen", "<resolved>"))?;
    workspace_by_slot(state, workspace)?
        .screens
        .iter()
        .find(|screen| screen.id == slot)
        .ok_or_else(|| ResourceError::not_found("screen", "<resolved>"))
}

fn public_workspace_id(
    state: &State,
    slot: WorkspaceId,
) -> Result<&WorkspacePublicId, ResourceError> {
    state
        .resource_indexes
        .workspace_ids
        .get(&slot)
        .ok_or_else(|| ResourceError::not_found("workspace", "<resolved>"))
}

fn public_screen_id(state: &State, slot: ScreenId) -> Result<&ScreenPublicId, ResourceError> {
    state
        .resource_indexes
        .screen_ids
        .get(&slot)
        .ok_or_else(|| ResourceError::not_found("screen", "<resolved>"))
}

fn public_pane_id(state: &State, slot: PaneId) -> Result<&PanePublicId, ResourceError> {
    state
        .resource_indexes
        .pane_ids
        .get(&slot)
        .ok_or_else(|| ResourceError::not_found("pane", "<resolved>"))
}

fn public_tab_id(state: &State, slot: SurfaceId) -> Result<&TabPublicId, ResourceError> {
    state
        .resource_indexes
        .tab_ids
        .get(&slot)
        .ok_or_else(|| ResourceError::not_found("tab", "<resolved>"))
}
