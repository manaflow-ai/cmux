//! Creation of a conversation tab (`conversation-tabs-v1`, raw
//! `new-conversation-tab`). The frontend browser row and the
//! `conversation_tabs` row commit together; the tab then commits through the
//! frontend browser creation path, under the browser id that commit chose.
//!
//! With an idempotency key (`origin` + `mutation_id`) a retry returns the tab
//! the first request created, and a retry after a crash between the two
//! commits creates the tab under the recorded browser id. A retry after that
//! tab was closed is refused (`frontend_browser_key_closed`) and creates
//! nothing, like `new-frontend-browser-tab` (state/frontend_browser_keys.rs).
//! The key names the request's record and target; the same key with another
//! one is refused. Keyed creations are serialized with the frontend browser ones.
//!
//! `bind-conversation-tab-session` commits on the state path: one resource
//! revision, a replay record and a `session.events` upsert of the tab.

use serde_json::Map;

use crate::Surface;
use crate::mux::*;
use crate::resource::BrowserPublicId;
use crate::state::commit::StateEffects;
use crate::state::conversation_tabs_store::{
    CONVERSATION_TAB_ENGINE, CONVERSATION_TAB_URL, ConversationTabKey, ConversationTabRecord,
    agent_session_of, bind_agent_session, browser_for_mutation, mark_conversation_tabs_present,
    write_conversation_tab,
};
use crate::state::frontend_browser_keys::{FrontendBrowserReuse, KEYED_CREATION, browser_committed};
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::state::values::fresh_upserts;
use crate::workspace_registry::FrontendBrowserRecord;

/// Where a new conversation tab goes: a pane (or the focused pane), or a
/// workspace, which gets its first screen and pane when it has none (the
/// home workspace starts empty).
#[derive(Debug, Clone, Copy)]
pub(crate) enum ConversationTabTarget {
    Pane(Option<PaneId>),
    Workspace(WorkspaceId),
}

/// A created or replayed conversation tab.
pub(crate) struct ConversationTabOutcome {
    pub(crate) surface: Arc<Surface>,
    pub(crate) replayed: bool,
}

impl Mux {
    pub(crate) fn new_conversation_tab(
        self: &Arc<Self>,
        target: ConversationTabTarget,
        record: ConversationTabRecord,
        mutation: Option<&WorkspaceMutation>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<ConversationTabOutcome> {
        record.validate()?;
        let key = mutation.map(|mutation| (mutation.origin.as_str(), mutation.id.as_str()));
        // Held for the whole keyed creation, before every other lock.
        let _serial = key
            .is_some()
            .then(|| KEYED_CREATION.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        let target_ids = self.conversation_tab_target_ids(target)?;
        let recorded = match key {
            Some((origin, id)) => {
                self.read_registry_state(|connection| browser_for_mutation(connection, origin, id))?
            }
            None => None,
        };
        let (browser_id, fresh) = match recorded {
            Some(recorded) => {
                anyhow::ensure!(
                    recorded.record.as_ref() == Some(&record)
                        && recorded.target.as_ref().is_none_or(|stored| *stored == target_ids),
                    "idempotency.conflict: the key named another conversation tab request"
                );
                let browser_id = BrowserPublicId::parse(recorded.browser_id)?;
                let content = ContentPublicId::Browser(browser_id.clone());
                if let Some(surface) = self.with_state(|state| {
                    let surface = state.single_placement_of_content(&content)?;
                    state.surfaces.get(&surface).cloned()
                }) {
                    return Ok(ConversationTabOutcome { surface, replayed: true });
                }
                // The key's tab committed and was closed: its browser id is a
                // tombstone, never the content of a second tab.
                if self.read_registry_state(|c| browser_committed(c, browser_id.as_str()))? {
                    return Err(FrontendBrowserReuse::KeyClosed(browser_id.as_str().to_string()).into());
                }
                (browser_id, false)
            }
            None => (BrowserPublicId::random()?, true),
        };
        if fresh {
            let frontend = FrontendBrowserRecord {
                engine: CONVERSATION_TAB_ENGINE.to_string(),
                url: CONVERSATION_TAB_URL.to_string(),
                title: None,
                favicon_url: None,
                profile_id: None,
                owner: None,
            };
            let id = browser_id.as_str().to_string();
            let key = key.map(|(origin, mutation_id)| ConversationTabKey {
                origin,
                mutation_id,
                target: &target_ids,
            });
            let write =
                |tx: &rusqlite::Transaction<'_>| write_conversation_tab(tx, &id, &record, key);
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.put_frontend_browser(browser_id.as_str(), &frontend, Some(&write))?;
            self.reload_presentation(&registry)?;
        }
        mark_conversation_tabs_present();
        let fields = Map::from_iter([(
            "frontend_browser_id".to_string(),
            Value::String(browser_id.as_str().to_string()),
        )]);
        let created = match target {
            ConversationTabTarget::Pane(pane) => self.new_browser_tab_with_fields(
                CONVERSATION_TAB_URL.to_string(),
                pane,
                size,
                fields,
            ),
            ConversationTabTarget::Workspace(workspace) => {
                self.new_conversation_tab_in(workspace, fields)
            }
        };
        match created {
            Ok(surface) => {
                self.publish_journal_event();
                Ok(ConversationTabOutcome { surface, replayed: false })
            }
            Err(error) => {
                // A keyed creation keeps its record, so a retry resumes it.
                if key.is_none() {
                    let mut registry = self.workspace_registry.lock().unwrap();
                    if registry.delete_frontend_browser(browser_id.as_str()).is_ok() {
                        let _ = self.reload_presentation(&registry);
                    }
                }
                Err(error)
            }
        }
    }

    /// A conversation tab in `workspace`'s active pane, or in a new first
    /// pane of an empty workspace.
    fn new_conversation_tab_in(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        mut fields: Map<String, Value>,
    ) -> anyhow::Result<Arc<Surface>> {
        let selectors = self
            .ordinary_workspace_selectors(workspace)
            .with_context(|| format!("unknown workspace {workspace}"))?;
        fields.insert("url".into(), Value::String(CONVERSATION_TAB_URL.to_string()));
        let operation = crate::resource::ResourceOperation::TabCreateBrowser;
        let commit = self.commit_ordinary_topology_operation(operation, selectors, fields)?;
        self.emit_resource_topology_legacy_events(operation, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// The public ids a creation's target names (a key's fingerprint):
    /// numeric ids do not survive a daemon restart.
    fn conversation_tab_target_ids(&self, target: ConversationTabTarget) -> anyhow::Result<Value> {
        self.with_state(|state| match target {
            ConversationTabTarget::Pane(None) => Ok(serde_json::json!({"pane": null})),
            ConversationTabTarget::Pane(Some(pane)) => {
                let id = state.resource_indexes.pane_ids.get(&pane).context("unknown pane")?;
                Ok(serde_json::json!({"pane": id.as_str()}))
            }
            ConversationTabTarget::Workspace(workspace) => {
                let id = state
                    .workspaces
                    .iter()
                    .find(|item| item.id == workspace)
                    .map(|item| item.public_id.to_string())
                    .with_context(|| format!("unknown workspace {workspace}"))?;
                Ok(serde_json::json!({"workspace": id}))
            }
        })
    }

    /// `bind-conversation-tab-session`: bind a new chat's acpmux session
    /// once. Returns the record and whether the call was a replay (the same
    /// session was bound already).
    pub(crate) fn bind_conversation_tab_session(
        &self,
        surface: SurfaceId,
        session: &str,
    ) -> anyhow::Result<(ConversationTabRecord, bool)> {
        let runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        let identity = runtime.resource_identity();
        let (browser_id, tab_id) = match identity
            .map(|identity| (&identity.content_id, &identity.tab_id))
        {
            Some((ContentPublicId::Browser(id), tab)) => (id.as_str().to_string(), tab.to_string()),
            _ => anyhow::bail!("bad request: surface {surface} is not a conversation tab"),
        };
        let bound =
            self.read_registry_state(|connection| agent_session_of(connection, &browser_id))?;
        let changed = match bound {
            None => anyhow::bail!("bad request: surface {surface} has no agent session source"),
            Some(Some(bound)) if bound == session => false,
            Some(Some(bound)) => {
                anyhow::bail!("conversation_tab.session_bound: the tab is bound to session {bound}")
            }
            Some(None) => {
                let operation = "tab.conversation.bind_session";
                let fingerprint = serde_json::json!({
                    "operation": operation, "browser": browser_id, "session": session,
                });
                let commit = self.commit_state(
                    &WorkspaceMutation::local("cmux-tui-conversation-tab"),
                    operation,
                    &fingerprint,
                    None,
                    StateEffects { presentation: true, tree: false },
                    |transaction, _| {
                        // A concurrent bind may have won since the read.
                        let changed = bind_agent_session(transaction, &browser_id, session)?;
                        let changes = if changed {
                            fresh_upserts(transaction, &[], &[], std::slice::from_ref(&tab_id))?
                        } else {
                            Vec::new()
                        };
                        Ok(StateChanges::new(serde_json::json!({"changed": changed}), changes))
                    },
                )?;
                commit.result["changed"].as_bool().unwrap_or(false)
            }
        };
        let record = self
            .conversation_tab_of(&runtime)
            .ok_or_else(|| anyhow::anyhow!("surface {surface} lost its conversation record"))?;
        if changed {
            self.emit_tab_changed(surface);
        }
        Ok((record, !changed))
    }

    /// The conversation record of a tab surface, if it is a conversation tab.
    pub(crate) fn conversation_tab_of(&self, surface: &Surface) -> Option<ConversationTabRecord> {
        let identity = surface.resource_identity()?;
        let ContentPublicId::Browser(id) = &identity.content_id else { return None };
        self.presentation_snapshot().conversation_tabs.get(id.as_str()).cloned()
    }

    /// Drop conversation contents from a `browser.list` result.
    pub(crate) fn retain_browser_pages(&self, browsers: &mut Value) {
        let presentation = self.presentation_snapshot();
        if let Some(items) = browsers.as_array_mut() {
            items.retain(|item| {
                item["id"]
                    .as_str()
                    .is_none_or(|id| !presentation.conversation_tabs.contains_key(id))
            });
        }
    }

    /// `browser.get` of a conversation content is refused (`validation.invalid`).
    pub(crate) fn refuse_conversation_content(&self, browser: &Value) -> Result<(), ResourceError> {
        let conversation = browser["id"]
            .as_str()
            .is_some_and(|id| self.presentation_snapshot().conversation_tabs.contains_key(id));
        if conversation {
            return Err(ResourceError::validation_invalid(
                Some("browser"),
                "a conversation tab is not a browser page",
            ));
        }
        Ok(())
    }

    /// v2 browser operations refuse a conversation tab (`validation.invalid`).
    pub(crate) fn refuse_conversation_browser(
        &self,
        surface: &Surface,
    ) -> Result<(), ResourceError> {
        match self.conversation_tab_of(surface) {
            Some(_) => Err(ResourceError::validation_invalid(
                Some("browser"),
                "a conversation tab is not a browser page",
            )),
            None => Ok(()),
        }
    }

    /// Raw browser commands refuse a conversation tab (`validation.invalid`).
    pub(crate) fn refuse_conversation_tab(&self, surface: &Surface) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.conversation_tab_of(surface).is_none(),
            "bad request: a conversation tab is not a browser page"
        );
        Ok(())
    }
}
