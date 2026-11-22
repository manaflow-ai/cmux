//! The Postgres runner (server.md 8). Every argv, config file and SQL
//! statement comes from `cmux_server_core::pg::PgPlan`; this module runs
//! `initdb`, writes the files, starts and stops the cluster with `pg_ctl`,
//! and runs SQL through `psql` on the admin socket with the SQL on stdin
//! (never on argv) and the admin secret in a 0600 pgpass file.
//!
//! Postgres binaries come from `--pg-bin` or from the current profile's
//! `postgresql-17` package (`<current>/pkgs/postgresql-17/bin`).

mod apps;
mod backup;
pub mod port;

use std::fs;
use std::path::{Path, PathBuf};

use cmux_server_core::access::{access_policy, socket_dir_check};
use cmux_server_core::layout::Layout;
use cmux_server_core::pg::{
    ADMIN_DATABASE, ADMIN_ROLE, AppDb, CONF_FILE, CONF_INCLUDE_LINE, ClusterSpec, PgError, PgPlan,
    SOCKET_GROUP, admin_pgpass_line, password_from_random,
};
use cmux_server_core::units::SERVICE_USER;
use cmux_server_core::{HostPath, InstallMode, Platform};

pub use apps::{AppReport, RegistryEntry, parse_mode};
pub use backup::{Archived, WalMethod, archive_wal, utc_stamp};

use crate::config::ServerConfig;
use crate::error::{Error, IoContext, Result};
use crate::process::{Cmd, Runner};
use crate::store::Store;
use crate::{access, fsx, host};

/// The store package that carries the Postgres binaries.
pub const PG_PACKAGE: &str = "postgresql-17";

#[derive(Clone, Debug, Default)]
pub struct PgOptions {
    /// A directory with `initdb`, `pg_ctl`, `postgres`, `psql`,
    /// `pg_basebackup`.
    pub pg_bin: Option<PathBuf>,
    /// The binary named in `archive_command` (default `<current>/bin/cmux`).
    pub cmux_bin: Option<PathBuf>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClusterReport {
    pub created: bool,
    pub started: bool,
    pub port: u16,
    pub socket_dir: PathBuf,
}

pub struct Postgres<'a> {
    pub layout: &'a Layout,
    runner: &'a dyn Runner,
    plan: PgPlan,
    pub pg_bin: PathBuf,
}

fn pg_error(e: PgError) -> Error {
    Error::rejected(format!("Postgres plan refused: {e:?}"))
}

fn host_path(platform: Platform, path: &Path, what: &str) -> Result<HostPath> {
    let text = path.to_str().ok_or_else(|| Error::usage(format!("{what} is not UTF-8")))?;
    HostPath::new(platform, text).ok_or_else(|| Error::usage(format!("{what} is not absolute")))
}

fn absolute(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        return Ok(path.to_path_buf());
    }
    Ok(std::env::current_dir().ctx("current directory")?.join(path))
}

/// Refuses system mode, then finds the binaries: `--pg-bin`, else the
/// current profile's `postgresql-17` package.
fn resolve_bin(layout: &Layout, opts: &PgOptions) -> Result<PathBuf> {
    if layout.mode == InstallMode::System {
        // initdb and pg_ctl must run as the service user `cmux`, never
        // as root; that belongs to the server role, not this CLI.
        return Err(Error::rejected(
            "Postgres in system mode is run by the server role as user cmux; \
             this build does not run initdb or pg_ctl from the CLI in system mode",
        ));
    }
    let pg_bin = match &opts.pg_bin {
        Some(dir) => absolute(dir)?,
        None => Store::new(layout).current_package(PG_PACKAGE).map(|p| p.join("bin")).ok_or_else(
            || {
                Error::not_found(format!(
                    "no PostgreSQL 17 binaries: the current profile has no {PG_PACKAGE} package; pass --pg-bin <dir>"
                ))
            },
        )?,
    };
    if !pg_bin.join("initdb").is_file() {
        return Err(Error::not_found(format!("{} has no initdb", pg_bin.display())));
    }
    Ok(pg_bin)
}

impl<'a> Postgres<'a> {
    /// Resolves binaries, the port (allocated and persisted in `server.json`
    /// on first use) and the plan. For verbs that create the cluster.
    pub fn open(
        layout: &'a Layout,
        runner: &'a dyn Runner,
        config: &mut ServerConfig,
        opts: &PgOptions,
    ) -> Result<Postgres<'a>> {
        let pg_bin = resolve_bin(layout, opts)?;
        let (install_id, new_id) = config.ensure_install_id()?;
        let allocation = port::allocate(&install_id, config.postgres_port())?;
        let port = allocation.block.postgres;
        if new_id || config.postgres_port() != Some(port) {
            config.set_postgres_port(port);
            config.save()?;
        }
        Postgres::build(layout, runner, pg_bin, port, opts)
    }

    /// Like [`Postgres::open`] for verbs that only read or stop the
    /// cluster (`db url`, the uninstall stop path): it never writes
    /// `server.json`, and a server with no install id or no Postgres port
    /// yet is "not found" (exit 3).
    pub fn open_existing(
        layout: &'a Layout,
        runner: &'a dyn Runner,
        config: &ServerConfig,
        opts: &PgOptions,
    ) -> Result<Postgres<'a>> {
        let pg_bin = resolve_bin(layout, opts)?;
        let none = |what: &str| {
            Error::not_found(format!(
                "no Postgres on this server yet ({what} missing in {})",
                config.path().display()
            ))
        };
        let install_id = config.install_id().ok_or_else(|| none("installId"))?;
        let persisted = config.postgres_port().ok_or_else(|| none("postgres.port"))?;
        let port = port::allocate(install_id, Some(persisted))?.block.postgres;
        Postgres::build(layout, runner, pg_bin, port, opts)
    }

    fn build(
        layout: &'a Layout,
        runner: &'a dyn Runner,
        pg_bin: PathBuf,
        port: u16,
        opts: &PgOptions,
    ) -> Result<Postgres<'a>> {
        let platform = layout.platform;
        let cmux_bin = match &opts.cmux_bin {
            Some(path) => host_path(platform, &absolute(path)?, "cmux binary")?,
            None => layout.current_cmux.clone(),
        };
        let peer = layout.mode == InstallMode::System && platform == Platform::Linux;
        let service_user = if peer { SERVICE_USER.to_owned() } else { host::current_user()? };
        let spec = ClusterSpec {
            mode: layout.mode,
            platform,
            pg_bin_dir: host_path(platform, &pg_bin, "Postgres bin directory")?,
            data_dir: layout.postgres_data(),
            socket_dir: layout.postgres_socket_dir(port),
            port,
            cmux_bin,
            service_user,
            admin_pwfile: (!peer).then(|| layout.state.join("postgres/initdb.pw")),
        };
        let plan = PgPlan::new(spec).map_err(pg_error)?;
        Ok(Postgres { layout, runner, plan, pg_bin })
    }

    pub fn plan(&self) -> &PgPlan {
        &self.plan
    }

    pub fn port(&self) -> u16 {
        self.plan.spec().port
    }

    pub fn data_dir(&self) -> PathBuf {
        fsx::local(&self.plan.spec().data_dir)
    }

    pub fn socket_dir(&self) -> PathBuf {
        fsx::local(&self.plan.spec().socket_dir)
    }

    pub fn admin_pgpass(&self) -> PathBuf {
        fsx::local(&self.layout.postgres_admin_pgpass())
    }

    fn state_dir(&self, rel: &str) -> PathBuf {
        fsx::local(&self.layout.state.join(rel))
    }

    fn bin(&self, name: &str) -> PathBuf {
        self.pg_bin.join(name)
    }

    pub fn initialized(&self) -> bool {
        self.data_dir().join("PG_VERSION").is_file()
    }

    /// `pg_ctl status`: exit 0 when a postmaster runs on the data directory.
    pub fn is_running(&self) -> bool {
        let cmd = Cmd::new(self.bin("pg_ctl")).arg("status").arg("-D").arg(self.data_dir());
        self.runner.run(&cmd).is_ok_and(|o| o.ok())
    }

    /// The admin connection: the socket directory, the port, and the admin
    /// secret file where the admin uses SCRAM.
    fn admin_env(&self, cmd: Cmd) -> Cmd {
        let mut cmd = cmd
            .arg("-h")
            .arg(self.socket_dir())
            .arg("-p")
            .arg(self.port().to_string())
            .arg("-U")
            .arg(ADMIN_ROLE)
            .env("PGCONNECT_TIMEOUT", "10");
        if !self.plan.uses_peer() {
            cmd = cmd.env("PGPASSFILE", self.admin_pgpass());
        }
        cmd
    }

    /// Runs `sql` on `database` as the admin; returns stdout (unaligned,
    /// tuples only).
    pub fn psql(&self, database: &str, sql: &str) -> Result<String> {
        let cmd =
            Cmd::new(self.bin("psql")).args(["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]);
        let cmd = self.admin_env(cmd).arg("-d").arg(database).arg("-f").arg("-");
        let out = self.runner.check(&cmd.stdin(sql.as_bytes().to_vec()))?;
        Ok(out.stdout_text())
    }

    fn ensure_socket_dir(&self) -> Result<()> {
        if let Some(checks) = socket_dir_check(self.layout, self.port()) {
            return access::ensure(&checks, self.runner);
        }
        let dir = self.socket_dir();
        if self.plan.uses_peer() {
            fsx::ensure_dir(&dir, 0o750)?;
            self.runner.check(&Cmd::new("chgrp").arg(SOCKET_GROUP).arg(&dir))?;
            return Ok(());
        }
        fsx::ensure_dir(&dir, 0o700)
    }

    /// Creates the cluster on first use, writes the generated config and
    /// starts it.
    pub fn ensure_cluster(&self) -> Result<ClusterReport> {
        let mut report = ClusterReport {
            port: self.port(),
            socket_dir: self.socket_dir(),
            ..ClusterReport::default()
        };
        // The state directory first: created 0700, or refused when it is
        // wider (decision SV-R4), before any secret is written under it.
        access::ensure(&access_policy(self.layout), self.runner)?;
        for rel in ["postgres", "postgres/17", "logs", "backups", "backups/wal"] {
            fsx::ensure_dir(&self.state_dir(rel), 0o700)?;
        }
        // A pwfile left by an initdb that crashed holds the admin secret in
        // clear text; it is never needed again.
        if let Some(pwfile) = self.plan.spec().admin_pwfile.as_ref().map(fsx::local) {
            fsx::remove_tree(&pwfile)?;
        }
        if !self.initialized() {
            self.init()?;
            report.created = true;
        }
        self.write_config(&self.apps()?)?;
        self.ensure_socket_dir()?;
        report.started = self.start()?;
        for statement in self.plan.cluster_sql() {
            self.psql(&statement.database, &statement.sql)?;
        }
        Ok(report)
    }

    fn init(&self) -> Result<()> {
        let data = self.data_dir();
        if data.exists() && fs::read_dir(&data).ctx(data.display())?.next().is_some() {
            return Err(Error::rejected(format!(
                "{} is not empty and holds no cluster; refusing",
                data.display()
            )));
        }
        let pwfile = self.plan.spec().admin_pwfile.as_ref().map(fsx::local);
        if let Some(pwfile) = &pwfile {
            let password = password_from_random(&host::random::<32>()?);
            // The admin secret is kept before initdb runs, so a crash
            // between the two cannot lose access to a new cluster.
            fsx::atomic_write(
                &self.admin_pgpass(),
                admin_pgpass_line(&password).as_bytes(),
                0o600,
            )?;
            fsx::atomic_write(pwfile, format!("{password}\n").as_bytes(), 0o600)?;
        }
        let argv = self.plan.initdb_argv();
        let cmd = Cmd::new(&argv[0]).args(&argv[1..]);
        let result = self.runner.check(&cmd);
        if let Some(pwfile) = &pwfile {
            let _ = fs::remove_file(pwfile);
        }
        result.map(|_| ())
    }

    /// Writes `cmux.conf`, `pg_hba.conf` and `pg_ident.conf` and the include
    /// line. Returns whether any file changed.
    pub fn write_config(&self, apps: &[AppDb]) -> Result<bool> {
        let data = self.data_dir();
        let main = data.join("postgresql.conf");
        let text = fs::read_to_string(&main).ctx(main.display())?;
        let mut changed = false;
        if !text.lines().any(|l| l.trim() == CONF_INCLUDE_LINE) {
            let mut next = text;
            if !next.ends_with('\n') {
                next.push('\n');
            }
            next.push_str(CONF_INCLUDE_LINE);
            next.push('\n');
            fsx::atomic_write(&main, next.as_bytes(), 0o600)?;
            changed = true;
        }
        let files = [
            (CONF_FILE, self.plan.postgresql_conf(apps)),
            ("pg_hba.conf", self.plan.pg_hba_conf(apps)),
            ("pg_ident.conf", self.plan.pg_ident_conf(apps)),
        ];
        for (name, content) in files {
            changed |= fsx::write_if_changed(&data.join(name), content.as_bytes(), 0o600)?;
        }
        Ok(changed)
    }

    /// `pg_ctl start -w`. The postmaster gets `CMUX_SERVER_WAL_DIR`, which
    /// `archive-wal` uses, so archiving never depends on `HOME`.
    pub fn start(&self) -> Result<bool> {
        if self.is_running() {
            return Ok(false);
        }
        let log = self.state_dir("logs").join("postgres.log");
        let cmd = Cmd::new(self.bin("pg_ctl"))
            .args(["start", "-w", "-t", "60", "-s", "-D"])
            .arg(self.data_dir())
            .arg("-l")
            .arg(log)
            .env("CMUX_SERVER_WAL_DIR", fsx::local(&self.layout.wal_archive()))
            .env("CMUX_SERVER_MODE", host::mode_str(self.layout.mode));
        self.runner.check(&cmd)?;
        Ok(true)
    }

    /// `pg_ctl stop -m fast -w`; `false` when it was not running.
    pub fn stop(&self) -> Result<bool> {
        if !self.is_running() {
            return Ok(false);
        }
        let cmd = Cmd::new(self.bin("pg_ctl"))
            .args(["stop", "-w", "-t", "60", "-s", "-m", "fast", "-D"])
            .arg(self.data_dir());
        self.runner.check(&cmd)?;
        Ok(true)
    }

    /// Before a VM snapshot (vm-image.md 4.5): a running cluster in the
    /// snapshot slows `vms.create`, so it is stopped and started after bind.
    pub fn prepare_snapshot(&self) -> Result<bool> {
        self.stop()
    }

    /// Re-reads `pg_hba.conf` and `pg_ident.conf`.
    pub fn reload(&self) -> Result<()> {
        if !self.is_running() {
            return Ok(());
        }
        let cmd = Cmd::new(self.bin("pg_ctl")).args(["reload", "-s", "-D"]).arg(self.data_dir());
        self.runner.check(&cmd).map(|_| ())
    }

    /// One row exists for `sql` (a `SELECT 1 … WHERE …`).
    fn exists(&self, database: &str, sql: &str) -> Result<bool> {
        Ok(self.psql(database, sql)? == "1")
    }

    fn admin_db(&self) -> &'static str {
        ADMIN_DATABASE
    }
}
