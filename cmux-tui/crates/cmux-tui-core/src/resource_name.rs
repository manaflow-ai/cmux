//! Name precedence and revision checks shared by durable tab mutations.
use anyhow::Context;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::resource::ResourceError;
use crate::workspace_registry::RegistryTab;

/// Missing provenance in an older registry is conservatively user-owned.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NameSource {
    #[default]
    User,
    Auto,
}

/// Automatic callbacks carry the name revision captured before their work began.
/// Unrelated graph changes can advance the session revision without invalidating it.
pub(crate) struct TabNameUpdate {
    source: NameSource,
    generation: Option<String>,
    name_revision: Option<u64>,
}

impl TabNameUpdate {
    pub(crate) fn parse(fields: &Map<String, Value>) -> anyhow::Result<Self> {
        let source = fields.get("source").cloned()
            .map(serde_json::from_value).transpose()?.unwrap_or_default();
        let generation = fields.get("expected_generation").and_then(Value::as_str).map(str::to_owned);
        let name_revision = fields.get("expected_name_revision").and_then(Value::as_str)
            .map(str::parse).transpose()?;
        anyhow::ensure!(source != NameSource::Auto || (generation.is_some() && name_revision.is_some()),
            "automatic names require a generation and name revision");
        Ok(Self { source, generation, name_revision })
    }

    pub(crate) fn apply(
        &self, tab: &mut RegistryTab, name: Option<String>, generation: &str, revision: u64,
    ) -> anyhow::Result<()> {
        if self.generation.as_deref().is_some_and(|expected| expected != generation) {
            return Err(ResourceError::operation_failed("tab.rename",
                "name callback belongs to a retired session generation", json!({"tab":tab.public_id})).into());
        }
        if let Some(expected) = self.name_revision {
            if expected != tab.name_revision {
                return Err(ResourceError::revision_conflict(expected, tab.name_revision).into());
            }
        }
        if self.source == NameSource::Auto {
            anyhow::ensure!(name.as_ref().is_some_and(|value| !value.trim().is_empty()),
                "automatic names cannot clear a title");
            anyhow::ensure!(tab.name.is_none() || tab.name_source == NameSource::Auto,
                "an explicit user name cannot be replaced by an automatic title");
        }
        tab.name = name;
        tab.name_source = self.source;
        tab.name_revision = revision.checked_add(1).context("name revision overflow")?;
        Ok(())
    }
}
