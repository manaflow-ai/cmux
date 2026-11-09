//! The id forms a selector takes besides a full public id (W5-P).
//!
//! Every client gets the same forms because the daemon expands them:
//!
//! - a unique id prefix: `pane_3f0a` is the one pane whose id starts so;
//!   two or more are `selector.ambiguous` with every candidate id;
//! - for a terminal, a tab id or a pane id (full or prefix): the terminal
//!   that tab shows, or that pane's selected tab's terminal;
//! - a bare id: the 32 hex digits without the prefix (`3f0a…`), or a
//!   terminal's host id (the raw protocol's `terminal_id`, which is not the
//!   payload of its `term_` id);
//! - `focused`: `current`.
//!
//! `cmux.protocol/2` takes additions only (spec/README.md), so a request
//! that resolved before must select the same object. A prefixed form was
//! never a name (the old parser refused it), so it is expanded first
//! ([`IdForms::Prefixed`]). A bare id and `focused` were names, so they are
//! expanded only when the full ids and names find nothing
//! ([`IdForms::Unprefixed`]): a tab named `focused` or named with 32 hex
//! digits keeps its old answer. A full id stays as it is, and so does any
//! other word (a name, `current`).

use crate::model::State;
use crate::resource::{
    ContentPublicId, PanePublicId, ResourceError, ScreenPublicId, TabPublicId, id_prefix_parts,
    is_bare_id,
};

use super::{InProcessHostLookup, ResourceSelectors, ResourceTarget};

/// Which id forms one [`expand`] pass expands.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum IdForms {
    /// Unique prefixes, and tab or pane ids as terminal selectors: forms
    /// that were never names, expanded before anything resolves.
    Prefixed,
    /// Bare ids, host ids and `focused`: forms that were names, expanded
    /// only when the full ids and names find nothing.
    Unprefixed,
}

/// `selectors` with every id form of `forms` expanded to the full id;
/// `Ok(None)` when no selector has such a form.
pub(super) fn expand(
    state: &State,
    in_process_host: Option<InProcessHostLookup<'_>>,
    selectors: &ResourceSelectors,
    forms: IdForms,
) -> Result<Option<ResourceSelectors>, ResourceError> {
    let mut expanded = selectors.clone();
    let mut changed = false;
    let kinds = [
        ResourceTarget::Workspace,
        ResourceTarget::Screen,
        ResourceTarget::Pane,
        ResourceTarget::Tab,
        ResourceTarget::Browser,
    ];
    for kind in kinds {
        let Some(raw) = slot(&mut expanded, kind).clone() else { continue };
        let full = match forms {
            IdForms::Prefixed => expand_prefix(state, kind, &raw)?,
            IdForms::Unprefixed if raw == "focused" => Some("current".to_owned()),
            IdForms::Unprefixed => expand_bare(state, None, kind, &raw)?,
        };
        let Some(full) = full else { continue };
        if forms == IdForms::Unprefixed && full != "current" {
            place_implicit_parents(state, &mut expanded, kind, &full);
        }
        *slot(&mut expanded, kind) = Some(full);
        changed = true;
    }
    let Some(raw) = expanded.terminal.clone() else { return Ok(changed.then_some(expanded)) };
    if forms == IdForms::Unprefixed {
        let full = if raw == "focused" {
            Some("current".to_owned())
        } else {
            expand_bare(state, in_process_host, ResourceTarget::Terminal, &raw)?
        };
        if let Some(full) = full {
            if full != "current" {
                place_implicit_parents(state, &mut expanded, ResourceTarget::Terminal, &full);
            }
            expanded.terminal = Some(full);
            changed = true;
        }
    } else if let Some(tab) = terminal_view(state, &raw)? {
        // The terminal that tab shows, in that tab: the tab id pins the
        // view, so the parent checks see the place the caller named.
        let terminal = shown_terminal(state, &tab)
            .ok_or_else(|| ResourceError::not_found("terminal", &raw))?;
        if expanded.tab.as_ref().is_none_or(|given| given == "current") {
            expanded.tab = Some(tab.to_string());
            for ancestor in [&mut expanded.workspace, &mut expanded.screen, &mut expanded.pane] {
                if ancestor.as_deref() == Some("current") {
                    *ancestor = None;
                }
            }
        }
        expanded.terminal = Some(terminal);
        changed = true;
    } else if let Some(full) = expand_prefix(state, ResourceTarget::Terminal, &raw)? {
        expanded.terminal = Some(full);
        changed = true;
    }
    Ok(changed.then_some(expanded))
}

/// The selector slot of `kind` (a structural kind or a browser).
fn slot(selectors: &mut ResourceSelectors, kind: ResourceTarget) -> &mut Option<String> {
    match kind {
        ResourceTarget::Workspace => &mut selectors.workspace,
        ResourceTarget::Screen => &mut selectors.screen,
        ResourceTarget::Pane => &mut selectors.pane,
        ResourceTarget::Tab => &mut selectors.tab,
        ResourceTarget::Terminal => &mut selectors.terminal,
        _ => &mut selectors.browser,
    }
}

/// The CLI puts `current` parents above a name, and a bare id was a name:
/// the `current` parents of the object a bare id expanded to become that
/// object's own parents, so it is found wherever it is. A parent the caller
/// named (an id or a name) stays and is checked. A terminal or browser
/// (content, which may show in no tab) loses its parents when every one is
/// `current` or absent.
fn place_implicit_parents(
    state: &State,
    selectors: &mut ResourceSelectors,
    kind: ResourceTarget,
    full: &str,
) {
    let indexes = &state.resource_indexes;
    let implicit = |value: &Option<String>| value.as_deref().is_none_or(|value| value == "current");
    if matches!(kind, ResourceTarget::Terminal | ResourceTarget::Browser) {
        let parents = [&selectors.workspace, &selectors.screen, &selectors.pane, &selectors.tab];
        if parents.into_iter().all(implicit) {
            (selectors.workspace, selectors.screen, selectors.pane, selectors.tab) =
                (None, None, None, None);
        }
        return;
    }
    let tab_pane = || {
        let tab = TabPublicId::parse(full).ok()?;
        indexes.tab_pane.get(indexes.tabs.get(&tab)?).copied()
    };
    let pane = match kind {
        ResourceTarget::Tab => tab_pane(),
        ResourceTarget::Pane => {
            PanePublicId::parse(full).ok().and_then(|pane| indexes.panes.get(&pane).copied())
        }
        _ => None,
    };
    let screen = match kind {
        ResourceTarget::Screen => ScreenPublicId::parse(full)
            .ok()
            .and_then(|screen| indexes.screens.get(&screen).copied()),
        _ => pane.and_then(|pane| indexes.pane_screen.get(&pane).copied()),
    };
    let workspace = screen.and_then(|screen| indexes.screen_workspace.get(&screen).copied());
    let parents = [
        (
            &mut selectors.pane,
            pane.and_then(|pane| indexes.pane_ids.get(&pane)).map(ToString::to_string),
        ),
        (
            &mut selectors.screen,
            screen.and_then(|screen| indexes.screen_ids.get(&screen)).map(ToString::to_string),
        ),
        (
            &mut selectors.workspace,
            workspace
                .and_then(|workspace| indexes.workspace_ids.get(&workspace))
                .map(ToString::to_string),
        ),
    ];
    for (parent, own) in parents {
        if parent.as_deref() == Some("current")
            && let Some(own) = own
        {
            *parent = Some(own);
        }
    }
}

/// The public id prefix of `kind`'s ids.
fn id_prefix(kind: ResourceTarget) -> Option<&'static str> {
    Some(match kind {
        ResourceTarget::Workspace => "ws",
        ResourceTarget::Screen => "screen",
        ResourceTarget::Pane => "pane",
        ResourceTarget::Tab => "tab",
        ResourceTarget::Terminal => "term",
        ResourceTarget::Browser => "browser",
        ResourceTarget::Machine | ResourceTarget::Session => return None,
    })
}

/// Every live public id of `kind`.
fn ids(state: &State, kind: ResourceTarget) -> Vec<String> {
    let indexes = &state.resource_indexes;
    match kind {
        ResourceTarget::Workspace => indexes.workspaces.keys().map(ToString::to_string).collect(),
        ResourceTarget::Screen => indexes.screens.keys().map(ToString::to_string).collect(),
        ResourceTarget::Pane => indexes.panes.keys().map(ToString::to_string).collect(),
        ResourceTarget::Tab => indexes.tabs.keys().map(ToString::to_string).collect(),
        ResourceTarget::Terminal => {
            let mut ids = indexes
                .content_placements
                .keys()
                .filter(|id| matches!(id, ContentPublicId::Terminal(_)))
                .map(|id| id.as_str().to_owned())
                .chain(state.terminal_catalog.keys().map(ToString::to_string))
                .collect::<Vec<_>>();
            ids.sort();
            ids.dedup();
            ids
        }
        ResourceTarget::Browser => indexes
            .content_placements
            .keys()
            .filter(|id| matches!(id, ContentPublicId::Browser(_)))
            .map(|id| id.as_str().to_owned())
            .collect(),
        ResourceTarget::Machine | ResourceTarget::Session => Vec::new(),
    }
}

/// The full id `raw` names when it is a unique prefix of `kind`'s ids;
/// `Ok(None)` for any other word (a prefix of another kind's ids too).
fn expand_prefix(
    state: &State,
    kind: ResourceTarget,
    raw: &str,
) -> Result<Option<String>, ResourceError> {
    let Some(prefix) = id_prefix(kind) else { return Ok(None) };
    let Some((given, _)) = id_prefix_parts(raw) else { return Ok(None) };
    if given != prefix {
        return Ok(None);
    }
    let mut matches =
        ids(state, kind).into_iter().filter(|id| id.starts_with(raw)).collect::<Vec<_>>();
    matches.sort();
    match matches.len() {
        0 => {
            let mut error = ResourceError::not_found(kind.kind(), raw);
            error.message = crate::resource::unmatched_id_prefix_message(kind.kind(), raw);
            Err(error)
        }
        1 => Ok(matches.pop()),
        _ => Err(ResourceError::new(
            "selector.ambiguous",
            format!(
                "{} {kind}s have ids that start with {raw}: {}; pass more of the id",
                matches.len(),
                matches.join(", "),
                kind = kind.kind(),
            ),
            serde_json::json!({
                "scope": kind.kind(),
                "selector": raw,
                "candidates": matches,
            }),
            false,
        )),
    }
}

/// The full id `raw` names when it is a bare id of `kind` (or, for a
/// terminal, a host id); `Ok(None)` for any other word.
fn expand_bare(
    state: &State,
    in_process_host: Option<InProcessHostLookup<'_>>,
    kind: ResourceTarget,
    raw: &str,
) -> Result<Option<String>, ResourceError> {
    let Some(prefix) = id_prefix(kind) else { return Ok(None) };
    if !is_bare_id(raw) {
        return Ok(None);
    }
    let full = format!("{prefix}_{raw}");
    if ids(state, kind).contains(&full) {
        return Ok(Some(full));
    }
    if kind == ResourceTarget::Terminal {
        if let Some(public) = state.terminal_catalog_by_host.get(raw) {
            return Ok(Some(public.to_string()));
        }
        if let Some(public) = in_process_host
            .and_then(|lookup| lookup(raw))
            .and_then(|runtime| state.terminal_catalog_by_runtime.get(&runtime))
        {
            return Ok(Some(public.to_string()));
        }
    }
    Err(ResourceError::not_found(kind.kind(), raw))
}

/// The tab a terminal selector names by a tab or pane id (full or prefix; a
/// bare id is the terminal's own).
fn terminal_view(state: &State, raw: &str) -> Result<Option<TabPublicId>, ResourceError> {
    let kind = match raw.rsplit_once('_') {
        Some(("tab", _)) => ResourceTarget::Tab,
        Some(("pane", _)) => ResourceTarget::Pane,
        _ => return Ok(None),
    };
    let full = expand_prefix(state, kind, raw)?.unwrap_or_else(|| raw.to_owned());
    if kind == ResourceTarget::Tab {
        return TabPublicId::parse(full).map(Some);
    }
    let pane = PanePublicId::parse(full)?;
    let selected = state
        .resource_indexes
        .panes
        .get(&pane)
        .and_then(|slot| state.panes.get(slot))
        .and_then(|pane| pane.active_surface())
        .and_then(|surface| state.resource_indexes.tab_ids.get(&surface))
        .cloned()
        .ok_or_else(|| ResourceError::not_found("terminal", raw))?;
    Ok(Some(selected))
}

/// The `term_` id of the terminal `tab` shows.
fn shown_terminal(state: &State, tab: &TabPublicId) -> Option<String> {
    let surface = state.resource_indexes.tabs.get(tab)?;
    match state.resource_indexes.content_ids.get(surface)? {
        ContentPublicId::Terminal(id) => Some(id.to_string()),
        ContentPublicId::Browser(_) => None,
    }
}
