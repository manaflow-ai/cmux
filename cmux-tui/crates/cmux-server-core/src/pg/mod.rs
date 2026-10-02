//! Postgres plan for one cluster per install and per-app provisioning
//! (server.md 8).
//!
//! [`PgPlan`] is built from a validated [`ClusterSpec`]. It renders the
//! `initdb` argv, the `cmux.conf` include for `postgresql.conf`, the full
//! `pg_hba.conf` and `pg_ident.conf`, and the SQL statements per app. The I/O
//! crate writes the files, runs the argv and executes the statements in order,
//! each on the database it names.

mod conf;
mod ident;
mod scram;
mod sql;

pub use conf::{CONF_FILE, CONF_INCLUDE_LINE};
pub use ident::{APP_ID_MAX, AppId, AppIdError, quote_ident, quote_literal, valid_os_user};
pub use scram::{
    SCRAM_ITERATIONS, admin_pgpass_line, password_from_random, pgpass_line, scram_verifier,
};
pub use sql::{AppLimits, Statement};

use crate::platform::{HostPath, InstallMode, Platform};

/// Superuser created by `initdb --username`.
pub const ADMIN_ROLE: &str = "cmux_admin";
/// The shared database that holds one schema per app in `schema` mode.
pub const SHARED_DATABASE: &str = "cmux_apps";
/// Maintenance database the admin connects to for cluster-level statements.
pub const ADMIN_DATABASE: &str = "postgres";
/// Group of the system-mode socket directory; app OS users are members.
pub const SOCKET_GROUP: &str = "cmux-db";
pub const ADMIN_MAP: &str = "cmuxadmin";
pub const APPS_MAP: &str = "cmuxapps";
/// Longest Unix socket path the platforms accept (`sun_path` minus NUL).
pub const MAX_SOCKET_PATH: usize = 103;

/// How an app gets its database (manifest `database.mode`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DbMode {
    /// Database `app_<id>` owned by role `app_<id>`.
    Database,
    /// Schema `app_<id>` in the shared database [`SHARED_DATABASE`].
    Schema,
}

/// One app's database declaration.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppDb {
    pub id: AppId,
    pub mode: DbMode,
    /// The service declared that it cannot use a Unix socket (server.md 8.2).
    pub tcp: bool,
}

impl AppDb {
    pub fn database(&self) -> String {
        match self.mode {
            DbMode::Database => self.id.role(),
            DbMode::Schema => SHARED_DATABASE.to_owned(),
        }
    }
}

/// Facts about the cluster that the caller decided (layout, ports, users).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClusterSpec {
    pub mode: InstallMode,
    pub platform: Platform,
    /// Directory with `initdb`, `postgres`, … from the `postgresql-17` package.
    pub pg_bin_dir: HostPath,
    pub data_dir: HostPath,
    pub socket_dir: HostPath,
    pub port: u16,
    /// `<current>/bin/cmux`, used by `archive_command`.
    pub cmux_bin: HostPath,
    /// OS user the cluster runs as: `cmux` in system mode, the installing
    /// user in user mode. Mapped to [`ADMIN_ROLE`] by peer auth.
    pub service_user: String,
    /// The `initdb --pwfile` input with the random admin secret. Required
    /// wherever the admin does not use peer auth: user mode on every
    /// platform and Windows in both modes (server.md 8.1, 8.3). The caller
    /// keeps the secret in `<state>/postgres/admin.pgpass` (0600; DPAPI on
    /// Windows), see [`admin_pgpass_line`].
    pub admin_pwfile: Option<HostPath>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PgError {
    /// A path is for another platform or holds a character this plan
    /// refuses to put into a config file or shell command.
    UnsafePath(&'static str),
    /// `<socket_dir>/.s.PGSQL.<port>` exceeds [`MAX_SOCKET_PATH`] bytes.
    SocketPathTooLong(usize),
    BadServiceUser,
    /// `admin_pwfile` is required exactly when the admin does not use peer
    /// auth (user mode, or Windows).
    PwfileMismatch,
    /// Port 0 or 5432.
    BadPort(u16),
    /// A password verifier that is not `SCRAM-SHA-256$…`.
    BadVerifier,
}

/// A validated cluster plan.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PgPlan {
    spec: ClusterSpec,
}

impl PgPlan {
    pub fn new(spec: ClusterSpec) -> Result<PgPlan, PgError> {
        conf::validate(&spec)?;
        Ok(PgPlan { spec })
    }

    pub fn spec(&self) -> &ClusterSpec {
        &self.spec
    }

    /// Peer auth for the admin and the apps: system mode on Linux and macOS
    /// only. User mode uses SCRAM, because every app runs as the installing
    /// user and peer auth would make each of them superuser (server.md 8.3,
    /// measured on the Freestyle prototype). Windows has no peer auth.
    pub fn uses_peer(&self) -> bool {
        self.spec.mode == InstallMode::System && self.spec.platform != Platform::Windows
    }

    /// The cluster listens on a Unix socket (everywhere but Windows).
    pub fn uses_socket(&self) -> bool {
        self.spec.platform != Platform::Windows
    }

    /// True when the cluster listens on `127.0.0.1` (Windows always, else
    /// only when an app needs TCP).
    pub fn listens_tcp(&self, apps: &[AppDb]) -> bool {
        self.spec.platform == Platform::Windows || apps.iter().any(|a| a.tcp)
    }

    /// The app role needs a password: user mode always, system mode only
    /// for TCP or on Windows (peer auth needs none).
    pub fn app_needs_password(&self, app: &AppDb) -> bool {
        self.spec.mode == InstallMode::User || app.tcp || !self.uses_peer()
    }
}
