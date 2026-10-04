//! `app-screens-v1` support that needs the mux's creation fences.

use super::*;
use crate::state::home_store::EmptyWorkspaceMark;

impl Mux {
    /// The creation fences every topology effect holds from its pre-check to
    /// its commit (handoff, then execution). A screen kind commit takes them
    /// too, so it never lands between an effect's app-rule check and the
    /// effect, and the effect never changes memory that its commit check
    /// would then refuse.
    pub(crate) fn app_screen_fences(&self) -> (MutexGuard<'_, ()>, MutexGuard<'_, ()>) {
        let handoff = self.resource_creation_handoff.lock().unwrap();
        (handoff, self.resource_creation_execution.lock().unwrap())
    }
}

/// A creation's selectors and fields after routing, and the lock that keeps
/// a second companion creation out until this one commits.
type RoutedCreation = (ResourceSelectors, Map<String, Value>, Option<MutexGuard<'static, ()>>);

impl Mux {
    /// A new tab sent to an app workspace (a workspace or screen target,
    /// not a pane) goes to its companion workspace. When the companion is
    /// missing, the same creation makes it: a new workspace marked
    /// `app_tabs` in the transaction that stages it, holding the tab, so no
    /// reader sees it empty. The returned guard keeps a second creation from
    /// making another companion until this one commits. A session target
    /// makes a new workspace and keeps its selectors; a pane inside an app
    /// screen is refused by the effect's app rules.
    pub(crate) fn route_new_tab_to_companion(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selectors: ResourceSelectors,
        mut fields: Map<String, Value>,
    ) -> anyhow::Result<RoutedCreation> {
        if !matches!(
            operation,
            ResourceOperation::TabCreateTerminal | ResourceOperation::TabCreateBrowser
        ) || selectors.pane.is_some()
            || (selectors.screen.is_none() && selectors.workspace.is_none())
        {
            return Ok((selectors, fields, None));
        }
        let target = if selectors.screen.is_some() {
            ResourceTarget::Screen
        } else {
            ResourceTarget::Workspace
        };
        let Ok(path) = self.resolve_resource_path(target, &selectors) else {
            return Ok((selectors, fields, None));
        };
        let app = path.workspace.as_ref().and_then(|id| {
            self.with_state(|state| {
                let workspace = state.workspace_by_public_id(id)?;
                let app = workspace
                    .screens
                    .iter()
                    .find_map(|screen| state.resource_indexes.screen_apps.get(&screen.id))?;
                Some((app.app.clone(), id.to_string()))
            })
        });
        let Some((app, app_workspace)) = app else { return Ok((selectors, fields, None)) };
        let guard = crate::state::app_screens::home::COMPANIONS
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let live = self.read_registry_state(|connection| {
            crate::state::app_screens_store::live_companion(connection, &app)
        })?;
        let selectors = match live {
            Some(companion) => ResourceSelectors {
                workspace: Some(companion),
                screen: None,
                pane: None,
                ..selectors
            },
            None => {
                let default_name = self.companion_default_name(&app, None)?;
                fields.insert("new_workspace".into(), Value::Bool(true));
                fields.insert("workspace_name".into(), Value::String(default_name.clone()));
                fields.insert(
                    "companion_of".into(),
                    json!({"app": app, "app_workspace": app_workspace, "default_name": default_name}),
                );
                ResourceSelectors { workspace: None, screen: None, pane: None, ..selectors }
            }
        };
        Ok((selectors, fields, Some(guard)))
    }
}

/// The mark of a workspace a topology effect makes: an app workspace's
/// companion (internal `companion_of`), else ephemeral or none.
pub(super) fn effect_workspace_mark(fields: &Map<String, Value>) -> EmptyWorkspaceMark {
    if let Some(companion) = fields.get("companion_of") {
        let text = |name: &str| companion[name].as_str().unwrap_or_default().to_string();
        return EmptyWorkspaceMark::Companion {
            app: text("app"),
            app_workspace: text("app_workspace"),
            default_name: text("default_name"),
        };
    }
    let flag = |name: &str| fields.get(name).and_then(Value::as_bool) == Some(true);
    EmptyWorkspaceMark::ephemeral(flag("ephemeral") || flag("workspace_ephemeral"))
}

/// A creation with the internal `new_workspace` field ignores the target's
/// slots and always makes a new workspace.
pub(super) fn new_workspace_slots(
    mut slots: EffectSlots,
    fields: &Map<String, Value>,
) -> EffectSlots {
    if fields.get("new_workspace") == Some(&Value::Bool(true)) {
        (slots.pane, slots.workspace) = (None, None);
    }
    slots
}

#[cfg(test)]
#[path = "app_screen_race_tests.rs"]
mod tests;
