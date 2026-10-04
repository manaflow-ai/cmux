//! The `WorkspaceMutation` of a dispatched request, stamped with its actor
//! (plans/cmux-next/identity.md section 3).

use super::ParsedResourceRequest;

impl ParsedResourceRequest {
    /// A `WorkspaceMutation` with this request's idempotency key, `origin`
    /// and actor.
    pub(crate) fn mutation(
        &self,
        origin: &str,
    ) -> anyhow::Result<crate::workspace_registry::WorkspaceMutation> {
        let key = self
            .envelope
            .idempotency_key
            .clone()
            .ok_or_else(|| anyhow::anyhow!("mutation without an idempotency key"))?;
        Ok(crate::workspace_registry::WorkspaceMutation::new(key, origin)?
            .with_actor(self.actor.clone()))
    }
}
