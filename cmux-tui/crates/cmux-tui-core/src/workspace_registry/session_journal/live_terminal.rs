//! A stream's read of one terminal's durable rows on its own connection.

use super::SessionJournalReader;
use crate::resource::TerminalPublicId;
use crate::workspace_registry::resource_store;

impl SessionJournalReader {
    /// The durable rows of `terminal` in one read transaction on this
    /// reader's own read-only connection (no registry lock), so the rows
    /// and their revision are one cut of the registry.
    pub(crate) fn live_terminal(
        &self,
        terminal: &TerminalPublicId,
    ) -> anyhow::Result<resource_store::LiveTerminalRows> {
        let transaction = self.connection.unchecked_transaction()?;
        resource_store::query_live_terminal(&transaction, terminal)
    }
}
