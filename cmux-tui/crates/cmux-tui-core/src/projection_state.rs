//! Protocol-v9 v1 projection-state wire compatibility.
//!
//! Storage and mutation now live in `projection_navigation_v2`, which keeps
//! v1 and v2 records in one registry and enforces the one-way per-client
//! schema floor. These aliases intentionally retain the original command
//! payload and response field names for existing Swift clients.

pub(crate) use crate::projection_navigation_v2::{
    ProjectionNavigationClaimant as ProjectionClaimant,
    ProjectionNavigationV1State as ProjectionState,
    ProjectionNavigationV1Update as ProjectionStateUpdate,
    ProjectionNavigationV1Workspace as ProjectionWorkspaceState,
};
