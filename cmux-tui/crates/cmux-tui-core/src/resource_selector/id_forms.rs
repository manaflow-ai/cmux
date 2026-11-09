//! The id forms a selector takes besides a full public id (W5-P).
//!
//! Every client gets the same forms because the daemon expands them before
//! it resolves anything:
//!
//! - a unique id prefix: `pane_3f0a` is the one pane whose id starts so;
//!   two or more are `selector.ambiguous` with every candidate id;
//! - a bare id: the 32 hex digits without the prefix (`3f0a…`), or a
//!   terminal's host id (the raw protocol's `terminal_id`, which is not the
//!   payload of its `term_` id);
//! - for a terminal, a tab id or a pane id (full, prefix or bare is a
//!   terminal's own form): the terminal that tab shows, or that pane's
//!   selected tab's terminal.
//!
//! A full id stays as it is, and so does any other word (a name, `current`).

use crate::SurfaceId;
use crate::model::State;
use crate::resource::{
    ContentPublicId, PanePublicId, ResourceError, TabPublicId, id_prefix_parts, is_bare_id,
};

use super::{InProcessHostLookup, ResourceSelectors, ResourceTarget};

/// `selectors` with every prefix and bare id expanded to the full id;
/// `Ok(None)` when no selector has such a form.
pub(super) fn expand(
    state: &State,
    in_process_host: Option<InProcessHostLookup<'_>>,
    selectors: &ResourceSelectors,
) -> Result<Option<ResourceSelectors>, ResourceError> {
    let mut expanded = selectors.clone();
    let mut changed = false;
    let slots = [
        (ResourceTarget::Workspace, &mut expanded.workspace),
        (ResourceTarget::Screen, &mut expanded.screen),
        (ResourceTarget::Pane, &mut expanded.pane),
        (ResourceTarget::Tab, &mut expanded.tab),
        (ResourceTarget::Browser, &mut expanded.browser),
    ];
    for (kind, slot) in slots {
        if let Some(raw) = slot.as_deref()
            && let Some(full) = expand_one(state, None, kind, raw)?
        {
            *slot = Some(full);
            changed = true;
        }
    }
    if let Some(raw) = expanded.terminal.clone() {
        if let Some(tab) = terminal_view(state, &raw)? {
            // The terminal that tab shows, in that tab: the tab id pins the
            // view, so the parent checks see the place the caller named.
            let terminal = shown_terminal(state, &tab)
                .ok_or_else(|| ResourceError::not_found("terminal", &raw))?;
            if expanded.tab.as_ref().is_none_or(|given| given == "current") {
                expanded.tab = Some(tab.to_string());
                for ancestor in [&mut expanded.workspace, &mut expanded.screen, &mut expanded.pane]
                {
                    if ancestor.as_deref() == Some("current") {
                        *ancestor = None;
                    }
                }
            }
            expanded.terminal = Some(terminal);
            changed = true;
        } else if let Some(full) =
            expand_one(state, in_process_host, ResourceTarget::Terminal, &raw)?
        {
            expanded.terminal = Some(full);
            changed = true;
        }
    }
    Ok(changed.then_some(expanded))
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

/// The full id `raw` names when it is a prefix or a bare id of `kind`;
/// `Ok(None)` for any other word.
fn expand_one(
    state: &State,
    in_process_host: Option<InProcessHostLookup<'_>>,
    kind: ResourceTarget,
    raw: &str,
) -> Result<Option<String>, ResourceError> {
    let Some(prefix) = id_prefix(kind) else { return Ok(None) };
    if let Some((given, _)) = id_prefix_parts(raw) {
        if given != prefix {
            return Ok(None);
        }
        let mut matches =
            ids(state, kind).into_iter().filter(|id| id.starts_with(raw)).collect::<Vec<_>>();
        matches.sort();
        return match matches.len() {
            0 => Err(ResourceError::not_found(kind.kind(), raw)),
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
        };
    }
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

/// The tab a terminal selector names by a tab or pane id (full, prefix or
/// bare form of those kinds is not taken: a bare id is the terminal's own).
fn terminal_view(state: &State, raw: &str) -> Result<Option<TabPublicId>, ResourceError> {
    let kind = match raw.rsplit_once('_') {
        Some(("tab", _)) => ResourceTarget::Tab,
        Some(("pane", _)) => ResourceTarget::Pane,
        _ => return Ok(None),
    };
    let full = expand_one(state, None, kind, raw)?.unwrap_or_else(|| raw.to_owned());
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
