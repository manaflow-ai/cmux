//! Split identities of the ids that only the side tables name: row 1 of a
//! column with rows and the column of a lone column with rows.

#[cfg(test)]
impl crate::workspace_registry::WorkspaceRegistry {
    /// `(kind, live)` of `public_id` in the identity ledger, if registered.
    pub(crate) fn split_identity(&self, public_id: &str) -> anyhow::Result<Option<(String, bool)>> {
        use rusqlite::OptionalExtension;
        Ok(self
            .connection
            .query_row(
                "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
                [public_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?.is_none())),
            )
            .optional()?)
    }
}
