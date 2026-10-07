//! Per-app and cluster-level SQL (server.md 8.3).
//!
//! Statements are returned in order, each with the database it must run on.
//! `CREATE DATABASE` cannot run in a transaction block, so the I/O crate runs
//! each statement on its own (autocommit). The statements are for a fresh
//! object: the I/O crate checks `pg_roles`, `pg_database` and
//! `pg_namespace` first and skips what exists.

use super::{
    ADMIN_DATABASE, ADMIN_ROLE, AppDb, DbMode, PgError, PgPlan, SHARED_DATABASE, quote_ident,
    quote_literal,
};

/// One SQL statement and the database to run it on, as the admin role.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Statement {
    pub database: String,
    pub sql: String,
}

/// Per-role limits (server.md 8.3 defaults).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppLimits {
    pub connection_limit: u32,
    pub statement_timeout_ms: u64,
    pub idle_in_transaction_timeout_ms: u64,
    pub temp_file_limit_kb: u64,
}

impl Default for AppLimits {
    fn default() -> Self {
        AppLimits {
            connection_limit: 20,
            statement_timeout_ms: 30_000,
            idle_in_transaction_timeout_ms: 60_000,
            temp_file_limit_kb: 1024 * 1024,
        }
    }
}

fn stmt(database: &str, sql: String) -> Statement {
    Statement { database: database.to_owned(), sql }
}

fn ident(name: &str) -> String {
    quote_ident(name).expect("validated identifiers are non-empty and NUL-free")
}

/// A SCRAM verifier: `SCRAM-SHA-256$<iter>:<salt>$<stored>:<server>` with
/// base64 fields. Anything else is refused, so the value can never close the
/// literal it is placed in.
fn valid_verifier(v: &str) -> bool {
    let Some(rest) = v.strip_prefix("SCRAM-SHA-256$") else { return false };
    let base64 = |c: char| c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=');
    !rest.is_empty() && rest.chars().all(|c| base64(c) || c == '$' || c == ':')
}

impl PgPlan {
    /// Cluster-level hardening, run once after the first start.
    pub fn cluster_sql(&self) -> Vec<Statement> {
        vec![
            stmt(
                ADMIN_DATABASE,
                format!("REVOKE ALL ON DATABASE {} FROM PUBLIC", ident(ADMIN_DATABASE)),
            ),
            stmt(ADMIN_DATABASE, "REVOKE CONNECT ON DATABASE \"template1\" FROM PUBLIC".to_owned()),
        ]
    }

    /// The shared database for `schema` mode apps, created once before the
    /// first such app. No app may use its `public` schema.
    pub fn shared_database_sql(&self) -> Vec<Statement> {
        let db = ident(SHARED_DATABASE);
        vec![
            stmt(
                ADMIN_DATABASE,
                format!("CREATE DATABASE {db} OWNER {} TEMPLATE \"template0\"", ident(ADMIN_ROLE)),
            ),
            stmt(ADMIN_DATABASE, format!("REVOKE ALL ON DATABASE {db} FROM PUBLIC")),
            stmt(SHARED_DATABASE, "REVOKE ALL ON SCHEMA \"public\" FROM PUBLIC".to_owned()),
        ]
    }

    /// Role, limits and database (or schema) for one app:
    /// [`PgPlan::app_role_sql`] followed by [`PgPlan::app_objects_sql`].
    ///
    /// `password_verifier` is a SCRAM verifier from [`super::scram_verifier`]
    /// (never a clear-text password, so it never reaches the server log). It is
    /// required exactly when [`PgPlan::app_needs_password`] is true.
    pub fn app_sql(
        &self,
        app: &AppDb,
        limits: &AppLimits,
        password_verifier: Option<&str>,
    ) -> Result<Vec<Statement>, PgError> {
        let mut out = vec![self.app_role_sql(app, limits, password_verifier)?];
        out.extend(self.app_objects_sql(app, limits));
        Ok(out)
    }

    /// The password clause for `app`: required exactly when the role needs
    /// a password, and only a SCRAM verifier.
    fn password_clause(
        &self,
        app: &AppDb,
        password_verifier: Option<&str>,
    ) -> Result<String, PgError> {
        match (self.app_needs_password(app), password_verifier) {
            (true, Some(v)) if valid_verifier(v) => {
                Ok(format!(" PASSWORD {}", quote_literal(v).ok_or(PgError::BadVerifier)?))
            }
            (false, None) => Ok(String::new()),
            _ => Err(PgError::BadVerifier),
        }
    }

    /// `CREATE ROLE` for a role that does not exist yet.
    pub fn app_role_sql(
        &self,
        app: &AppDb,
        limits: &AppLimits,
        password_verifier: Option<&str>,
    ) -> Result<Statement, PgError> {
        let password = self.password_clause(app, password_verifier)?;
        let role = ident(&app.id.role());
        Ok(stmt(
            ADMIN_DATABASE,
            format!(
                "CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT CONNECTION LIMIT {}{password}",
                limits.connection_limit
            ),
        ))
    }

    /// A new password for an existing role (its pgpass file was lost).
    /// Refused when the role uses peer auth only.
    pub fn set_password_sql(
        &self,
        app: &AppDb,
        password_verifier: &str,
    ) -> Result<Statement, PgError> {
        let clause = self.password_clause(app, Some(password_verifier))?;
        Ok(stmt(ADMIN_DATABASE, format!("ALTER ROLE {}{clause}", ident(&app.id.role()))))
    }

    /// Limits and the database (or schema) of an app whose role exists.
    /// The `ALTER`, `REVOKE` and `GRANT` statements are idempotent; the
    /// caller skips `CREATE DATABASE` and `CREATE SCHEMA` when the object
    /// exists.
    pub fn app_objects_sql(&self, app: &AppDb, limits: &AppLimits) -> Vec<Statement> {
        let role = ident(&app.id.role());
        let a = ADMIN_DATABASE;
        let mut out = vec![
            stmt(
                a,
                format!(
                    "ALTER ROLE {role} SET statement_timeout = '{}ms'",
                    limits.statement_timeout_ms
                ),
            ),
            stmt(
                a,
                format!(
                    "ALTER ROLE {role} SET idle_in_transaction_session_timeout = '{}ms'",
                    limits.idle_in_transaction_timeout_ms
                ),
            ),
            stmt(
                a,
                format!(
                    "ALTER ROLE {role} SET temp_file_limit = '{}kB'",
                    limits.temp_file_limit_kb
                ),
            ),
        ];
        match app.mode {
            DbMode::Database => {
                let db_name = app.id.role();
                let db = ident(&db_name);
                out.push(stmt(
                    a,
                    format!("CREATE DATABASE {db} OWNER {role} TEMPLATE \"template0\""),
                ));
                out.push(stmt(a, format!("REVOKE ALL ON DATABASE {db} FROM PUBLIC")));
                out.push(stmt(
                    &db_name,
                    "REVOKE CREATE ON SCHEMA \"public\" FROM PUBLIC".to_owned(),
                ));
            }
            DbMode::Schema => {
                let shared = ident(SHARED_DATABASE);
                out.push(stmt(a, format!("GRANT CONNECT ON DATABASE {shared} TO {role}")));
                out.push(stmt(
                    SHARED_DATABASE,
                    format!("CREATE SCHEMA {role} AUTHORIZATION {role}"),
                ));
                out.push(stmt(SHARED_DATABASE, format!("REVOKE ALL ON SCHEMA {role} FROM PUBLIC")));
                out.push(stmt(
                    a,
                    format!("ALTER ROLE {role} IN DATABASE {shared} SET search_path = {role}"),
                ));
            }
        }
        out
    }

    /// The advisory step at 100% of the quota (server.md 8.3):
    /// `default_transaction_read_only` for new sessions of the role. It is
    /// advisory only, because an app can `SET default_transaction_read_only
    /// = off` in its own session; [`PgPlan::block_sql`] is the enforced cap.
    pub fn advisory_read_only_sql(&self, app: &AppDb, read_only: bool) -> Statement {
        let value = if read_only { "on" } else { "off" };
        stmt(
            ADMIN_DATABASE,
            format!(
                "ALTER ROLE {} SET default_transaction_read_only = {value}",
                ident(&app.id.role())
            ),
        )
    }

    /// The hard cap, `server.db.limits.set {app, blocked: true}`: no new
    /// connections for the role, and its open sessions end. This is the only
    /// enforceable cap, because the app owns its tables (server.md 8.3).
    pub fn block_sql(&self, app: &AppDb) -> Vec<Statement> {
        let role = app.id.role();
        vec![
            stmt(ADMIN_DATABASE, format!("ALTER ROLE {} CONNECTION LIMIT 0", ident(&role))),
            stmt(
                ADMIN_DATABASE,
                format!(
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = {}",
                    quote_literal(&role).expect("validated role name")
                ),
            ),
        ]
    }

    /// `server.db.limits.set {app, blocked: false}`: restores the role's
    /// connection limit.
    pub fn unblock_sql(&self, app: &AppDb, limits: &AppLimits) -> Statement {
        stmt(
            ADMIN_DATABASE,
            format!(
                "ALTER ROLE {} CONNECTION LIMIT {}",
                ident(&app.id.role()),
                limits.connection_limit
            ),
        )
    }
}
