//! One public tab representation for snapshots, mutations, and journal updates.
use serde_json::{Value, json};

use crate::resource::ContentPublicId;
use crate::workspace_registry::RegistryTab;

impl RegistryTab {
    /// Keep additions in the extension map accepted by released strict SDKs.
    /// Callers retain their existing topology and index validation boundaries.
    pub(crate) fn public_value(&self, focused: bool) -> Value {
        json!({
            "id":self.public_id,
            "pane_id":self.pane_id,
            "name":self.name,
            "index":self.position,
            "focused":focused,
            "content_kind":match self.content_id {
                ContentPublicId::Terminal(_) => "terminal",
                ContentPublicId::Browser(_) => "browser",
            },
            "content_id":self.content_id.as_str(),
            "extra":{
                "name_source":self.name_source,
                "name_revision":self.name_revision.to_string(),
            },
        })
    }
}
