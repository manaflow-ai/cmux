use cmux_tui_core::{RegistryAgentProjection, RegistryPublicProjections, WorkspaceRegistry};
use std::mem::size_of;

#[test]
fn durable_projection_types_are_nameable_by_downstream_crates() {
    let _ = size_of::<RegistryAgentProjection>();
    let _ = size_of::<RegistryPublicProjections>();
    let _ = WorkspaceRegistry::public_projections;
}
