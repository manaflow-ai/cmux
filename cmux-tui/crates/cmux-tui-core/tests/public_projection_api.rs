use cmux_tui_core::{RegistryAgentProjection, RegistryPublicProjections, WorkspaceRegistry};

#[test]
fn durable_projection_types_are_nameable_by_downstream_crates() {
    let _ = std::mem::size_of::<RegistryAgentProjection>();
    let _ = std::mem::size_of::<RegistryPublicProjections>();
    let _ = WorkspaceRegistry::public_projections;
}
