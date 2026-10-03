//! One workspace mutation and its `resource_mutations` row.

use rusqlite::ToSql;

use super::*;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceMutation {
    pub id: String,
    pub origin: String,
    /// Who asked for it (plans/cmux-next/identity.md section 3), set by the
    /// request dispatcher. Recorded beside `origin`; never part of the
    /// idempotency fingerprint, so a replay keeps the first actor. None only
    /// for the session host's own mutations.
    pub actor: Option<cmux_local_auth::Actor>,
}

impl WorkspaceMutation {
    pub fn new(id: impl Into<String>, origin: impl Into<String>) -> anyhow::Result<Self> {
        let mutation = Self { id: id.into(), origin: origin.into(), actor: None };
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        Ok(mutation)
    }

    pub fn local(origin: &str) -> Self {
        Self { id: new_uuid_v4(), origin: origin.to_string(), actor: None }
    }

    /// This mutation, made by `actor`.
    pub fn with_actor(mut self, actor: cmux_local_auth::Actor) -> Self {
        self.actor = Some(actor);
        self
    }
}

/// Write the `resource_mutations` row of `mutation`. Every owner that
/// records a mutation goes through here, so every row carries the actor
/// beside its origin (plans/cmux-next/identity.md section 3); the actor is
/// never part of the fingerprint.
pub(crate) fn insert_resource_mutation(
    tx: &Connection,
    mutation: &WorkspaceMutation,
    operation: &dyn ToSql,
    fingerprint: &dyn ToSql,
    result_json: &dyn ToSql,
    committed_revision: &dyn ToSql,
) -> rusqlite::Result<usize> {
    tx.execute(
        "INSERT INTO resource_mutations(
           origin, idempotency_key, operation, fingerprint, result_json, committed_revision,
           actor_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            mutation.origin,
            mutation.id,
            operation,
            fingerprint,
            result_json,
            committed_revision,
            mutation.actor.as_ref().map(cmux_local_auth::Actor::to_json),
        ],
    )
}

/// Add `actor_json` to registries created before the actor stamp
/// (plans/cmux-next/identity.md section 3). Rows written before it have no
/// actor (NULL). Forward-only: an older daemon does not write the column, so
/// rolling back after the new daemon ran leaves later rows without actors.
pub(crate) fn ensure_resource_mutation_actor_column(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let has_actor = transaction
        .prepare("PRAGMA table_info(resource_mutations)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "actor_json");
    if !has_actor {
        transaction.execute_batch(
            "ALTER TABLE resource_mutations ADD COLUMN actor_json TEXT
               CHECK(actor_json IS NULL OR json_valid(actor_json));",
        )?;
    }
    Ok(())
}
