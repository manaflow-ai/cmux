//! Frontend projections (`get-frontend-projection` / `put-frontend-projection`,
//! spec/commands.md): one opaque, schema-versioned view document the daemon
//! keeps per `(frontend, scope, subject_key)` for a frontend.

use super::*;

/// The mutation origin of the TUI's own projection writes.
const PROJECTION_ORIGIN: &str = "cmux-tui-frontend-projection";

/// One frontend projection's address.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ProjectionKey<'a> {
    pub(crate) frontend: &'a str,
    pub(crate) scope: &'a str,
    pub(crate) subject_key: &'a str,
}

impl Session {
    /// The stored projection document, None when there is none.
    pub(crate) fn frontend_projection(
        &self,
        key: ProjectionKey<'_>,
    ) -> anyhow::Result<Option<Value>> {
        let value = match self {
            Session::Local(mux) => {
                return Ok(mux
                    .get_frontend_projection(key.frontend, key.scope, key.subject_key)?
                    .map(|projection| projection.projection)
                    .filter(|projection| !projection.is_null()));
            }
            Session::Remote(remote) => remote.request(json!({
                "cmd": "get-frontend-projection",
                "frontend": key.frontend,
                "scope": key.scope,
                "subject_key": key.subject_key,
            }))?,
        };
        Ok(value.get("projection").filter(|projection| !projection.is_null()).cloned())
    }

    /// Replace the projection document (last writer wins).
    pub(crate) fn put_frontend_projection(
        &self,
        key: ProjectionKey<'_>,
        schema_version: u32,
        projection: &Value,
    ) -> anyhow::Result<()> {
        let mutation_id = new_projection_mutation_id()?;
        match self {
            Session::Local(mux) => {
                let mutation = WorkspaceMutation::by_local_user(mutation_id, PROJECTION_ORIGIN)?;
                mux.put_frontend_projection(
                    &mutation,
                    key.frontend,
                    key.scope,
                    key.subject_key,
                    schema_version,
                    None,
                    projection,
                )?;
                Ok(())
            }
            Session::Remote(remote) => remote
                .request(json!({
                    "cmd": "put-frontend-projection",
                    "frontend": key.frontend,
                    "scope": key.scope,
                    "subject_key": key.subject_key,
                    "schema_version": schema_version,
                    "projection": projection,
                    "origin": PROJECTION_ORIGIN,
                    "mutation_id": mutation_id,
                }))
                .map(|_| ()),
        }
    }
}

fn new_projection_mutation_id() -> anyhow::Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| anyhow::anyhow!("random mutation id: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}
