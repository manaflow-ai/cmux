//! Name precedence and revision checks shared by durable tab and workspace
//! renames.
use anyhow::Context;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::resource::ResourceError;
use crate::workspace_registry::{RegistryTab, RegistryWorkspace};
use cmux_json::JsonSet as _;

/// Missing provenance in an older registry is conservatively user-owned.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NameSource {
    #[default]
    User,
    Auto,
}

impl NameSource {
    /// The stored and wire spelling (`user` or `auto`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Auto => "auto",
        }
    }

    /// A stored value; anything unknown stays user-owned.
    pub fn from_stored(value: &str) -> Self {
        if value == "auto" { Self::Auto } else { Self::User }
    }

    /// A new workspace's name source: one the daemon picked itself (no
    /// requested name) belongs to the automatic namer, a requested name to
    /// whoever asked. The app sends the daemon's own next
    /// default (`workspace-N`) with Cmd-N so its row shows the final name at
    /// once; that is still the daemon's default, not a name a person chose,
    /// so it stays the automatic namer's (else the first prompt never
    /// renames the workspace).
    pub(crate) fn for_requested_workspace_name(name: Option<&str>) -> Self {
        match name {
            Some(name) if !is_default_workspace_name(name) => Self::User,
            _ => Self::Auto,
        }
    }
}

/// `workspace-N`, the daemon's default workspace name (`default_workspace_name`).
pub(crate) fn is_default_workspace_name(name: &str) -> bool {
    name.strip_prefix("workspace-")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// Automatic callbacks carry the name revision captured before their work began.
/// Unrelated graph changes can advance the session revision without invalidating it.
pub(crate) struct NameUpdate {
    source: NameSource,
    generation: Option<String>,
    name_revision: Option<u64>,
    /// A person hands the current name back to the automatic namer: the
    /// text stays, the source becomes auto, the revision advances.
    release: bool,
}

pub(crate) type TabNameUpdate = NameUpdate;
pub(crate) type WorkspaceNameUpdate = NameUpdate;

/// The name a rename is checked against.
struct CurrentName {
    /// No name an automatic writer would overwrite (a cleared tab name, an
    /// empty workspace name).
    unnamed: bool,
    source: NameSource,
    revision: u64,
}

impl NameUpdate {
    /// A person's rename with no preconditions: the request shape before
    /// name provenance.
    pub(crate) fn user() -> Self {
        Self { source: NameSource::User, generation: None, name_revision: None, release: false }
    }

    #[cfg(test)]
    pub(crate) fn new(
        source: Option<NameSource>,
        generation: Option<String>,
        name_revision: Option<u64>,
    ) -> anyhow::Result<Self> {
        Self::with_release(source, generation, name_revision, false)
    }

    /// A release is a person's request, so it needs no expected revision; it
    /// is only meaningful toward the automatic namer.
    fn with_release(
        source: Option<NameSource>,
        generation: Option<String>,
        name_revision: Option<u64>,
        release: bool,
    ) -> anyhow::Result<Self> {
        let source = source.unwrap_or_default();
        if release && source != NameSource::Auto {
            return Err(ResourceError::validation_invalid(
                Some("release"),
                "release hands a name to source auto",
            )
            .into());
        }
        if source == NameSource::Auto
            && !release
            && (generation.is_none() || name_revision.is_none())
        {
            return Err(ResourceError::validation_invalid(
                Some("source"),
                "automatic names require a generation and name revision",
            )
            .into());
        }
        Ok(Self { source, generation, name_revision, release })
    }

    /// The name authority of a v1 rename, whose `expected_generation` is the
    /// mutation's registry guard. Only an automatic rename also fences its
    /// name with it; a user rename keeps the fingerprint and errors it had
    /// before name provenance.
    pub(crate) fn from_request(
        source: Option<NameSource>,
        mutation_generation: Option<String>,
        name_revision: Option<u64>,
        release: bool,
    ) -> anyhow::Result<Self> {
        let generation = mutation_generation.filter(|_| source == Some(NameSource::Auto));
        Self::with_release(source, generation, name_revision, release)
    }

    pub(crate) fn parse(fields: &Map<String, Value>) -> anyhow::Result<Self> {
        let source = fields.get("source").cloned().map(serde_json::from_value).transpose()?;
        let generation =
            fields.get("expected_generation").and_then(Value::as_str).map(str::to_owned);
        let name_revision = fields
            .get("expected_name_revision")
            .and_then(Value::as_str)
            .map(parse_name_revision)
            .transpose()?;
        let release = match fields.get("release") {
            None => false,
            Some(value) => value.as_bool().ok_or_else(|| {
                ResourceError::validation_invalid(Some("release"), "release is a boolean")
            })?,
        };
        Self::with_release(source, generation, name_revision, release)
    }

    /// A release keeps the current text, so a request may omit the name.
    pub(crate) fn releases(&self) -> bool {
        self.release
    }

    #[cfg(test)]
    pub(crate) fn source(&self) -> NameSource {
        self.source
    }

    /// The idempotency fingerprint part of a rename. `None` for a plain user
    /// rename, so mutations recorded before name provenance still replay.
    pub(crate) fn fingerprint(&self) -> Option<Value> {
        (self.source != NameSource::User
            || self.generation.is_some()
            || self.name_revision.is_some())
        .then(|| {
            let mut fingerprint = json!({
                "source": self.source,
                "expected_generation": self.generation,
                "expected_name_revision": self.name_revision.map(|revision| revision.to_string()),
            });
            if self.release {
                fingerprint.set("release", json!(true));
            }
            fingerprint
        })
    }

    fn authorize(
        &self,
        operation: &str,
        resource: Value,
        current: CurrentName,
        name: Option<&str>,
        generation: &str,
    ) -> anyhow::Result<()> {
        if self.generation.as_deref().is_some_and(|expected| expected != generation) {
            return Err(ResourceError::operation_failed(
                operation,
                "name callback belongs to a retired session generation",
                resource,
            )
            .into());
        }
        if let Some(expected) = self.name_revision
            && expected != current.revision
        {
            return Err(ResourceError::revision_conflict(expected, current.revision).into());
        }
        if self.source == NameSource::Auto && !self.release {
            if name.is_none_or(|value| value.trim().is_empty()) {
                return Err(name_refusal(operation, resource, NAME_EMPTY).into());
            }
            if !(current.unnamed || current.source == NameSource::Auto) {
                return Err(name_refusal(operation, resource, NAME_PINNED).into());
            }
        }
        Ok(())
    }

    fn next_revision(revision: u64) -> anyhow::Result<u64> {
        revision.checked_add(1).context("name revision overflow")
    }

    pub(crate) fn apply(
        &self,
        tab: &mut RegistryTab,
        name: Option<String>,
        generation: &str,
        revision: u64,
    ) -> anyhow::Result<()> {
        if self.release {
            return Err(ResourceError::validation_invalid(
                Some("release"),
                "tab names have no release",
            )
            .into());
        }
        let current = CurrentName {
            unnamed: tab.name.is_none(),
            source: tab.name_source,
            revision: tab.name_revision,
        };
        self.authorize(
            "tab.rename",
            json!({"tab":tab.public_id}),
            current,
            name.as_deref(),
            generation,
        )?;
        tab.name = name;
        tab.name_source = self.source;
        tab.name_revision = Self::next_revision(revision)?;
        Ok(())
    }

    /// A workspace's name revision counts that workspace's own renames, so
    /// only a rename of the same workspace fences a pending callback.
    pub(crate) fn apply_workspace(
        &self,
        workspace: &mut RegistryWorkspace,
        name: String,
        generation: &str,
    ) -> anyhow::Result<()> {
        if self.release && name != workspace.name {
            return Err(ResourceError::validation_invalid(
                Some("name"),
                "a release keeps the current name",
            )
            .into());
        }
        // A default name never renamed is still unnamed, whatever its recorded source: daemons
        // before `for_requested_workspace_name` recorded the default name Cmd-N sends as the user's.
        let current = CurrentName {
            unnamed: workspace.name.trim().is_empty()
                || (workspace.name_revision == 0 && is_default_workspace_name(&workspace.name)),
            source: workspace.name_source,
            revision: workspace.name_revision,
        };
        self.authorize(
            "workspace.rename",
            json!({"workspace":workspace.public_id}),
            current,
            Some(&name),
            generation,
        )?;
        workspace.name_revision = Self::next_revision(workspace.name_revision)?;
        workspace.name = name;
        workspace.name_source = self.source;
        Ok(())
    }
}

/// `workspace-name-source-v1`: the `extra` of a workspace's public value.
/// The journal decorates stored workspaces with the same fields
/// (state/values.rs), so a projected value equals the stated one.
pub(crate) fn workspace_name_extra(source: NameSource, revision: u64) -> Value {
    json!({"name_source": source, "name_revision": revision.to_string()})
}

/// `reason_code` of an automatic rename over an explicit user name.
pub(crate) const NAME_PINNED: &str = "name_pinned";
/// `reason_code` of an automatic rename to an empty name.
pub(crate) const NAME_EMPTY: &str = "name_empty";

/// The typed refusal of an automatic rename: `operation.failed` whose extra
/// names the resource and the `reason_code`.
pub(crate) fn name_refusal(
    operation: &str,
    mut resource: Value,
    reason_code: &str,
) -> ResourceError {
    let reason = if reason_code == NAME_PINNED {
        "an explicit user name cannot be replaced by an automatic title"
    } else {
        "automatic names cannot clear a title"
    };
    resource.set("reason_code", json!(reason_code));
    ResourceError::operation_failed(operation, reason, resource)
}

/// A decimal `expected_name_revision`, as the wire carries it.
pub(crate) fn parse_name_revision(value: &str) -> anyhow::Result<u64> {
    Ok(value.parse()?)
}

#[cfg(test)]
#[path = "resource_name_tests.rs"]
mod tests;
