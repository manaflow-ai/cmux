//! Names the state handlers share with the multiplexer.

pub(crate) use std::sync::Arc;

pub(crate) use anyhow::Context;
pub(crate) use serde_json::Value;

pub(crate) use crate::model::State;
pub(crate) use crate::resource::{ContentPublicId, ResourceError, TabPublicId, WorkspacePublicId};
pub(crate) use crate::resource_mutation::ResourceMutationPlan;
pub(crate) use crate::resource_selector::{
    ResolvedResourceSlots, ResourceSelectorContext, resolve_resource_selectors,
};
pub(crate) use crate::workspace_registry::{
    ResourcePatchCommit, ResourceWorkspaceLedger, TerminalLifecycle, WorkspaceMutation,
};
pub(crate) use crate::{PaneId, ScreenId, SurfaceId, SurfaceKind, WorkspaceId};
