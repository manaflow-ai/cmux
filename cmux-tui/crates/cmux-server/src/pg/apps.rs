//! Per-app roles and databases (server.md 8.3).
//!
//! The registry `<state>/postgres/apps.json` lists every provisioned app;
//! `pg_hba.conf` and `pg_ident.conf` are generated from it. In user mode
//! each app gets a random 32-byte secret in `<state>/apps/<app>/pgpass`
//! (0600, written before the role exists); the server only ever sees the
//! SCRAM verifier, on psql's stdin.

use std::path::PathBuf;

use cmux_server_core::pg::{
    AppDb, AppId, AppLimits, DbMode, SCRAM_ITERATIONS, SHARED_DATABASE, Statement,
    password_from_random, pgpass_line, quote_literal, scram_verifier,
};
use serde::{Deserialize, Serialize};

use super::{Postgres, pg_error};
use crate::error::{Error, Result};
use crate::{fsx, host};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegistryEntry {
    /// The mapped app id (`pg::AppId`).
    pub id: String,
    /// The manifest id it was mapped from, when known (collision check).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manifest_id: Option<String>,
    /// `database` or `schema`.
    pub mode: String,
    #[serde(default)]
    pub tcp: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppReport {
    pub app: String,
    pub mode: DbMode,
    pub url: String,
    pub created_role: bool,
    pub created_database: bool,
    /// User mode: the app's pgpass file (its content is never printed).
    pub pgpass: Option<PathBuf>,
}

fn mode_str(mode: DbMode) -> &'static str {
    match mode {
        DbMode::Database => "database",
        DbMode::Schema => "schema",
    }
}

/// `database` or `schema`.
pub fn parse_mode(s: &str) -> Option<DbMode> {
    match s {
        "database" => Some(DbMode::Database),
        "schema" => Some(DbMode::Schema),
        _ => None,
    }
}

fn to_db(entry: &RegistryEntry) -> Result<AppDb> {
    let id = AppId::parse(&entry.id)
        .map_err(|e| Error::internal(format!("apps.json: bad app id {:?}: {e:?}", entry.id)))?;
    let mode = parse_mode(&entry.mode)
        .ok_or_else(|| Error::internal(format!("apps.json: bad mode {:?}", entry.mode)))?;
    Ok(AppDb { id, mode, tcp: entry.tcp })
}

impl Postgres<'_> {
    fn registry_path(&self) -> PathBuf {
        self.state_dir("postgres/apps.json")
    }

    pub fn registry(&self) -> Result<Vec<RegistryEntry>> {
        let path = self.registry_path();
        match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| Error::internal(format!("{}: {e}", path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(Error::io(path.display(), e)),
        }
    }

    /// The provisioned apps, for the generated config files.
    pub fn apps(&self) -> Result<Vec<AppDb>> {
        self.registry()?.iter().map(to_db).collect()
    }

    fn save_registry(&self, entries: &[RegistryEntry]) -> Result<()> {
        let bytes =
            serde_json::to_vec_pretty(entries).map_err(|e| Error::internal(e.to_string()))?;
        fsx::atomic_write(&self.registry_path(), &bytes, 0o600)
    }

    /// The registered app with this id.
    pub fn find_app(&self, id: &AppId) -> Result<AppDb> {
        let entry = self
            .registry()?
            .into_iter()
            .find(|e| e.id == id.as_str())
            .ok_or_else(|| Error::not_found(format!("no database for app {id}")))?;
        to_db(&entry)
    }

    /// `DATABASE_URL` without a password.
    pub fn url(&self, app: &AppDb) -> String {
        self.plan().database_url(app)
    }

    fn lit(value: &str) -> Result<String> {
        quote_literal(value).ok_or_else(|| Error::internal("NUL in an identifier"))
    }

    fn role_exists(&self, role: &str) -> Result<bool> {
        self.exists(
            self.admin_db(),
            &format!("SELECT 1 FROM pg_roles WHERE rolname = {}", Self::lit(role)?),
        )
    }

    fn database_exists(&self, name: &str) -> Result<bool> {
        let sql = format!("SELECT 1 FROM pg_database WHERE datname = {}", Self::lit(name)?);
        self.exists(self.admin_db(), &sql)
    }

    fn schema_exists(&self, name: &str) -> Result<bool> {
        let sql = format!("SELECT 1 FROM pg_namespace WHERE nspname = {}", Self::lit(name)?);
        self.exists(SHARED_DATABASE, &sql)
    }

    /// Runs `statements` in order, skipping a `CREATE DATABASE` or
    /// `CREATE SCHEMA` whose object exists. Returns whether a database was
    /// created.
    fn run_statements(&self, statements: &[Statement]) -> Result<bool> {
        let mut created = false;
        for st in statements {
            if let Some(rest) = st.sql.strip_prefix("CREATE DATABASE ") {
                let name = unquote_first(rest);
                if self.database_exists(&name)? {
                    continue;
                }
                created = true;
            } else if let Some(rest) = st.sql.strip_prefix("CREATE SCHEMA ")
                && self.schema_exists(&unquote_first(rest))?
            {
                continue;
            }
            self.psql(&st.database, &st.sql)?;
        }
        Ok(created)
    }

    /// A new random secret: writes the pgpass file (0600) and returns the
    /// SCRAM verifier for the server.
    fn new_secret(&self, app: &AppDb) -> Result<(String, PathBuf)> {
        let password = password_from_random(&host::random::<32>()?);
        let verifier = scram_verifier(&password, &host::random::<16>()?, SCRAM_ITERATIONS)
            .ok_or_else(|| Error::internal("SCRAM verifier"))?;
        let dir = fsx::local(&self.layout.app_state(&app.id));
        fsx::ensure_dir(&fsx::local(&self.layout.state.join("apps")), 0o700)?;
        fsx::ensure_dir(&dir, 0o700)?;
        let path = fsx::local(&self.layout.app_pgpass(&app.id));
        fsx::atomic_write(&path, pgpass_line(app, &password).as_bytes(), 0o600)?;
        Ok((verifier, path))
    }

    /// Creates the app's role and database (or schema) unless they exist,
    /// registers the app and regenerates `pg_hba.conf`. The cluster must be
    /// running ([`Postgres::ensure_cluster`]).
    pub fn ensure_app(&self, app: &AppDb, manifest_id: Option<&str>) -> Result<AppReport> {
        let mut registry = self.registry()?;
        if let Some(existing) = registry.iter().find(|e| e.id == app.id.as_str()) {
            let other =
                matches!((&existing.manifest_id, manifest_id), (Some(a), Some(b)) if a != b);
            if other {
                return Err(Error::rejected(format!(
                    "app id {} is taken by {}; refusing",
                    app.id,
                    existing.manifest_id.as_deref().unwrap_or("?")
                )));
            }
            if existing.mode != mode_str(app.mode) {
                return Err(Error::rejected(format!(
                    "app {} already uses mode {}; refusing to change it",
                    app.id, existing.mode
                )));
            }
        }
        let role = app.id.role();
        let limits = AppLimits::default();
        let needs = self.plan().app_needs_password(app);
        let role_exists = self.role_exists(&role)?;
        let pgpass_path = fsx::local(&self.layout.app_pgpass(&app.id));
        let mut pgpass = needs.then(|| pgpass_path.clone());
        if !role_exists {
            let verifier = if needs { Some(self.new_secret(app)?.0) } else { None };
            let st =
                self.plan().app_role_sql(app, &limits, verifier.as_deref()).map_err(pg_error)?;
            self.psql(&st.database, &st.sql)?;
        } else if needs && !pgpass_path.is_file() {
            let (verifier, path) = self.new_secret(app)?;
            let st = self.plan().set_password_sql(app, &verifier).map_err(pg_error)?;
            self.psql(&st.database, &st.sql)?;
            pgpass = Some(path);
        }
        if app.mode == DbMode::Schema {
            self.run_statements(&self.plan().shared_database_sql())?;
        }
        let created_database = self.run_statements(&self.plan().app_objects_sql(app, &limits))?;
        if !registry.iter().any(|e| e.id == app.id.as_str()) {
            registry.push(RegistryEntry {
                id: app.id.as_str().to_owned(),
                manifest_id: manifest_id.map(str::to_owned),
                mode: mode_str(app.mode).to_owned(),
                tcp: app.tcp,
            });
            self.save_registry(&registry)?;
        }
        if self.write_config(&self.apps()?)? {
            self.reload()?;
        }
        Ok(AppReport {
            app: app.id.as_str().to_owned(),
            mode: app.mode,
            url: self.url(app),
            created_role: !role_exists,
            created_database,
            pgpass,
        })
    }
}

/// The first identifier of `"name" …` (as quoted by `quote_ident`).
fn unquote_first(rest: &str) -> String {
    let Some(body) = rest.strip_prefix('"') else {
        return rest.split_whitespace().next().unwrap_or("").to_owned();
    };
    let mut out = String::new();
    let mut chars = body.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '"' {
            if chars.peek() == Some(&'"') {
                chars.next();
                out.push('"');
                continue;
            }
            break;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::unquote_first;

    #[test]
    fn unquotes_the_first_identifier() {
        assert_eq!(unquote_first("\"app_notes\" OWNER \"app_notes\""), "app_notes");
        assert_eq!(unquote_first("\"a\"\"b\" AUTHORIZATION x"), "a\"b");
    }
}
