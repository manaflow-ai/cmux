// Placeholder until backend/packages/protocol/scripts/export-rust-client.ts
// writes the generated catalog types: no op is known yet.

/// Runs `visitor` on the op named `name`; `None` when the catalog has no such op.
pub fn visit_op<V: crate::OpVisitor>(name: &str, visitor: V) -> Option<V::Output> {
    let _ = (name, visitor);
    None
}
