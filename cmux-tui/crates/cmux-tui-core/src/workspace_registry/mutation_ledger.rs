//! The durable mutation identity and the `resource_mutations` ledger write
//! (plans/cmux-next/identity.md section 3, P8 slice 3).
//!
//! Every durable write names its actor: who caused it. The daemon sets the
//! actor from the connection (or from itself for its own work); a caller can
//! never send one. The actor is not part of the idempotency fingerprint, so a
//! replay keeps the actor of the first commit.

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use super::{new_uuid_v4, validate_identifier};

/// The `resource_mutations.actor` value of rows written before actors existed.
pub(crate) const LEGACY_ACTOR: &str = "legacy";
/// The account-less local user (identity.md: `user_local`).
pub const LOCAL_USER_ID: &str = "user_local";

/// Who caused a durable mutation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Actor {
    /// The daemon's own work (startup, reaps, reducers): no caller.
    Daemon,
    /// The local OS user on a connection with no stronger proof.
    User { id: String },
    /// The verified cmux app on this machine (`verified_app`).
    Frontend { install_id: String },
    /// An app, as only the in-process app supervisor sets it.
    App { id: String },
    /// Written before actors existed, or by a daemon without them.
    Legacy,
    /// A connection from another machine: a `cmux link` peer
    /// (`link:<install>`), or a WebSocket or remote-entry connection.
    Peer { id: String },
}

impl Actor {
    pub fn local_user() -> Self {
        Self::User { id: LOCAL_USER_ID.to_string() }
    }

    /// The stored form: `daemon`, `user:<id>`, `frontend:<install id>`, `app:<id>`.
    pub fn wire(&self) -> String {
        match self {
            Self::Daemon => "daemon".to_string(),
            Self::User { id } => format!("user:{id}"),
            Self::Frontend { install_id } => format!("frontend:{install_id}"),
            Self::App { id } => format!("app:{id}"),
            Self::Peer { id } => format!("peer:{id}"),
            Self::Legacy => LEGACY_ACTOR.to_string(),
        }
    }

    /// The actor of a stored [`Actor::wire`] value; anything unknown is `legacy`.
    pub fn from_wire(wire: &str) -> Self {
        let owned = |id: &str| id.to_string();
        match wire.split_once(':') {
            None if wire == "daemon" => Self::Daemon,
            Some(("user", id)) => Self::User { id: owned(id) },
            Some(("frontend", id)) => Self::Frontend { install_id: owned(id) },
            Some(("app", id)) => Self::App { id: owned(id) },
            Some(("peer", id)) => Self::Peer { id: owned(id) },
            _ => Self::Legacy,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceMutation {
    pub id: String,
    pub origin: String,
    /// Set by the daemon, never by a caller. Every constructor names it:
    /// [`WorkspaceMutation::new`] and [`WorkspaceMutation::local`] take the
    /// caller's actor, [`WorkspaceMutation::daemon`] and
    /// [`WorkspaceMutation::daemon_local`] are the daemon's own work.
    pub actor: Actor,
}

impl WorkspaceMutation {
    pub fn new(
        id: impl Into<String>,
        origin: impl Into<String>,
        actor: Actor,
    ) -> anyhow::Result<Self> {
        let mutation = Self { id: id.into(), origin: origin.into(), actor };
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        Ok(mutation)
    }

    pub fn local(origin: &str, actor: Actor) -> Self {
        Self { id: new_uuid_v4(), origin: origin.to_string(), actor }
    }

    /// The local user in the in-process TUI (their own frontend, no socket).
    pub fn by_local_user(id: impl Into<String>, origin: impl Into<String>) -> anyhow::Result<Self> {
        Self::new(id, origin, Actor::local_user())
    }

    /// A fresh mutation inside this one (a reservation it makes): same
    /// origin and actor, its own id.
    pub(crate) fn reservation(&self) -> Self {
        Self::local(&self.origin, self.actor.clone())
    }

    /// The daemon's own work (startup, reaps, reducers), never a request.
    pub fn daemon(id: impl Into<String>, origin: impl Into<String>) -> anyhow::Result<Self> {
        Self::new(id, origin, Actor::Daemon)
    }

    /// [`WorkspaceMutation::daemon`] with a fresh id.
    pub fn daemon_local(origin: &str) -> Self {
        Self::local(origin, Actor::Daemon)
    }
}

/// The one write of a `resource_mutations` row; every durable mutation path
/// records its actor through it.
pub(crate) fn insert_resource_mutation(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    operation: &str,
    fingerprint: &str,
    result_json: &str,
    committed_revision: i64,
) -> rusqlite::Result<usize> {
    transaction.execute(
        "INSERT INTO resource_mutations(
           origin, idempotency_key, operation, fingerprint, result_json, committed_revision, actor
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            mutation.origin,
            mutation.id,
            operation,
            fingerprint,
            result_json,
            committed_revision,
            mutation.actor.wire(),
        ],
    )
}

/// Forward-only, additive: rows written before the column get `legacy`,
/// and an older daemon that omits the column on its writes gets `legacy`
/// too. Probed by table shape, not by schema number, so older builds keep
/// opening the registry.
pub(crate) fn migrate_add_actor_columns(connection: &Connection) -> anyhow::Result<()> {
    for table in ["resource_mutations", "resource_effect_receipts"] {
        let has_actor = connection
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
            .iter()
            .any(|column| column == "actor");
        if !has_actor {
            connection.execute_batch(&format!(
                "ALTER TABLE {table} ADD COLUMN actor TEXT NOT NULL DEFAULT '{LEGACY_ACTOR}';"
            ))?;
        }
    }
    Ok(())
}

/// The actor stored with the effect receipt `key` when it was prepared:
/// an effect commits as its caller, also after a daemon restart.
pub(crate) fn effect_receipt_actor(connection: &Connection, key: &str) -> anyhow::Result<Actor> {
    let sql = "SELECT actor FROM resource_effect_receipts WHERE idempotency_key = ?1";
    let stored = connection.query_row(sql, [key], |row| row.get::<_, String>(0)).optional()?;
    Ok(stored.map_or(Actor::Legacy, |wire| Actor::from_wire(&wire)))
}

#[cfg(test)]
impl super::WorkspaceRegistry {
    /// The stored actor of the mutation `key`, if it is in the ledger.
    pub(crate) fn resource_mutation_actor_for_test(
        &self,
        key: &str,
    ) -> anyhow::Result<Option<String>> {
        let sql = "SELECT actor FROM resource_mutations WHERE idempotency_key = ?1";
        Ok(self.connection.query_row(sql, [key], |row| row.get::<_, String>(0)).optional()?)
    }
}

/// Tests prepare receipts as the daemon; production names the caller
/// (`prepare_resource_effect_for`, `prepare_resource_creation_for`).
#[cfg(test)]
impl super::WorkspaceRegistry {
    pub fn prepare_resource_effect(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &serde_json::Value,
        intent: &serde_json::Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<super::ResourceEffectPreparation> {
        let mutation = WorkspaceMutation::daemon(idempotency_key, "test")?;
        let (generation, revision) = (expected_generation, expected_revision);
        self.prepare_resource_effect_for(
            &mutation,
            operation,
            fingerprint,
            intent,
            generation,
            revision,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn prepare_resource_creation(
        &mut self,
        correlation_key: &str,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &serde_json::Value,
        intent: &serde_json::Value,
        effectful: bool,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<super::ResourceCreationPreparation> {
        let mutation = WorkspaceMutation::daemon(idempotency_key, "test")?;
        self.prepare_resource_creation_for(
            correlation_key,
            &mutation,
            operation,
            fingerprint,
            intent,
            effectful,
            expected_generation,
            expected_revision,
        )
    }
}
