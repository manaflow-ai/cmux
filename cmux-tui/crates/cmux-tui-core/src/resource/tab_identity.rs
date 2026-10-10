//! A tab's public identity: its tab id and its content's id (moved out of
//! resource.rs, unchanged).

use serde::{Deserialize, Serialize};

use super::{BrowserPublicId, ContentPublicId, ResourceError, TabPublicId, TerminalPublicId};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TabResourceIdentity {
    pub tab_id: TabPublicId,
    pub content_id: ContentPublicId,
}

impl TabResourceIdentity {
    pub fn new(tab_id: TabPublicId, content_id: ContentPublicId) -> Self {
        Self { tab_id, content_id }
    }

    pub fn persisted_terminal(tab_id: TabPublicId, terminal_id: TerminalPublicId) -> Self {
        Self::new(tab_id, ContentPublicId::Terminal(terminal_id))
    }

    pub fn persisted_browser(tab_id: TabPublicId, browser_id: BrowserPublicId) -> Self {
        Self::new(tab_id, ContentPublicId::Browser(browser_id))
    }

    pub fn terminal(terminal_id: Option<TerminalPublicId>) -> Result<Self, ResourceError> {
        let terminal_id = match terminal_id {
            Some(terminal_id) => terminal_id,
            None => TerminalPublicId::random()?,
        };
        Ok(Self::persisted_terminal(TabPublicId::random()?, terminal_id))
    }

    pub fn browser() -> Result<Self, ResourceError> {
        Ok(Self::persisted_browser(TabPublicId::random()?, BrowserPublicId::random()?))
    }
}
