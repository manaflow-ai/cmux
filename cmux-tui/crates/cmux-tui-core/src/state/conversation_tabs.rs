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

use serde_json::Map;

use crate::Surface;
use crate::mux::*;
use crate::resource::BrowserPublicId;
use crate::state::conversation_tabs_store::{
    CONVERSATION_TAB_ENGINE, CONVERSATION_TAB_URL, ConversationTabRecord, browser_for_mutation,
    mark_conversation_tabs_present, write_conversation_tab,
};
use crate::state::frontend_browser_keys::{FrontendBrowserReuse, browser_committed};
use crate::state::prelude::*;
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
        let recorded = match key {
            Some((origin, id)) => {
                self.read_registry_state(|connection| browser_for_mutation(connection, origin, id))?
            }
            None => None,
        };
        let (browser_id, fresh) = match recorded {
            Some((browser_id, stored)) => {
                anyhow::ensure!(
                    stored == record,
                    "idempotency.conflict: the key named another conversation tab"
                );
                if let Some(surface) = self.with_state(|state| {
                    let content =
                        ContentPublicId::Browser(BrowserPublicId::parse(browser_id.clone()).ok()?);
                    let surface = state.single_placement_of_content(&content)?;
                    state.surfaces.get(&surface).cloned()
                }) {
                    return Ok(ConversationTabOutcome { surface, replayed: true });
                }
                // The key's tab committed and was closed: its browser id is a
                // tombstone, never the content of a second tab.
                if self.read_registry_state(|c| browser_committed(c, &browser_id))? {
                    return Err(FrontendBrowserReuse::KeyClosed(browser_id).into());
                }
                (BrowserPublicId::parse(browser_id)?, false)
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
