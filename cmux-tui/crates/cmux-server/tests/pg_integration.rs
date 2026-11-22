//! A real PostgreSQL 17 cluster, gated by `CMUX_SERVER_PG_BIN` (the
//! directory with `initdb`, `pg_ctl`, `psql`, `pg_basebackup`). Runs only on
//! a Linux Testbox; it never installs anything.
//!
//! Proves (server.md 8): no TCP listener, app A cannot reach app B or the
//! admin role, archive-wal produces files, basebackup works, and a second
//! ensure is a no-op.

mod common;

use std::net::{Ipv4Addr, TcpStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_server::config::ServerConfig;
use cmux_server::pg::{PgOptions, Postgres};
use cmux_server::process::{Cmd, Runner, SystemRunner};
use cmux_server_core::pg::{AppDb, AppId, DbMode};
use common::*;

fn pg_bin() -> Option<PathBuf> {
    std::env::var_os("CMUX_SERVER_PG_BIN").map(PathBuf::from)
}

/// `psql` as an app role with its own pgpass file.
fn psql_as(pg: &Postgres<'_>, role: &str, db: &str, pgpass: &Path, sql: &str) -> (bool, String) {
    let cmd = Cmd::new(pg.pg_bin.join("psql"))
        .args(["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h"])
        .arg(pg.socket_dir())
        .arg("-p")
        .arg(pg.port().to_string())
        .args(["-U", role, "-d", db, "-w", "-f", "-"])
        .env("PGPASSFILE", pgpass)
        .stdin(sql.as_bytes().to_vec());
    let out = SystemRunner.run(&cmd).unwrap();
    let text = if out.ok() {
        out.stdout_text()
    } else {
        String::from_utf8_lossy(&out.stderr).into_owned()
    };
    (out.ok(), text)
}

#[test]
fn real_cluster_isolation_archive_and_backup() {
    let Some(bin) = pg_bin() else {
        eprintln!("skipped: set CMUX_SERVER_PG_BIN to run against real PostgreSQL 17");
        return;
    };
    let tmp = tempfile::Builder::new().prefix("pgi").tempdir_in("/tmp").unwrap();
    let layout = layout_at(tmp.path(), cmux_server_core::Platform::Linux);
    let runner = SystemRunner;
    let mut cfg = ServerConfig::load(Path::new(layout.config_file.as_str())).unwrap();
    let opts = PgOptions {
        pg_bin: Some(bin),
        cmux_bin: Some(PathBuf::from(env!("CARGO_BIN_EXE_cmux-server"))),
    };
    let pg = Postgres::open(&layout, &runner, &mut cfg, &opts).unwrap();
    let started = Instant::now();
    let report = pg.ensure_cluster().unwrap();
    eprintln!("ensure_cluster (initdb + start): {:?}", started.elapsed());
    assert!(report.created && report.started);
    assert!(cfg.postgres_port().is_some(), "the port is persisted");

    // No TCP listener: listen_addresses is empty and the port refuses.
    assert_eq!(pg.psql("postgres", "SHOW listen_addresses").unwrap(), "");
    assert!(
        TcpStream::connect_timeout(
            &(Ipv4Addr::LOCALHOST, pg.port()).into(),
            Duration::from_secs(2)
        )
        .is_err()
    );

    let notes = AppDb { id: AppId::parse("notes").unwrap(), mode: DbMode::Database, tcp: false };
    let crm = AppDb { id: AppId::parse("crm").unwrap(), mode: DbMode::Database, tcp: false };
    let tasks = AppDb {
        id: AppId::from_manifest_id("cmux/tasks").unwrap(),
        mode: DbMode::Schema,
        tcp: false,
    };
    let a = pg.ensure_app(&notes, None).unwrap();
    let b = pg.ensure_app(&crm, None).unwrap();
    let c = pg.ensure_app(&tasks, Some("cmux/tasks")).unwrap();
    assert!(a.created_role && a.created_database && b.created_role);
    assert!(
        !a.url.contains("PASSWORD") && a.url.starts_with("postgresql://app_notes@/app_notes?host=")
    );
    let notes_pass = a.pgpass.unwrap();
    let mode = std::fs::metadata(&notes_pass).unwrap();
    assert_eq!(cmux_server::fsx::mode_of(&mode), 0o600);

    // Each app reaches its own database and nothing else.
    let (ok, _) = psql_as(
        &pg,
        "app_notes",
        "app_notes",
        &notes_pass,
        "CREATE TABLE t(x int); INSERT INTO t VALUES (1)",
    );
    assert!(ok, "notes uses its own database");
    let (ok, err) = psql_as(&pg, "app_notes", "app_crm", &notes_pass, "SELECT 1");
    assert!(!ok, "notes must not open crm: {err}");
    assert!(err.contains("pg_hba.conf"), "{err}");
    let (ok, err) = psql_as(&pg, "app_crm", "app_crm", &notes_pass, "SELECT 1");
    assert!(!ok, "notes' secret must not log in as crm: {err}");
    let (ok, err) = psql_as(&pg, "cmux_admin", "postgres", &notes_pass, "SELECT 1");
    assert!(!ok, "an app secret must not reach the admin role: {err}");
    let (ok, out) = psql_as(
        &pg,
        "app_cmux_tasks",
        "cmux_apps",
        &c.pgpass.unwrap(),
        "CREATE TABLE s(x int); SELECT current_schema()",
    );
    assert!(ok && out.ends_with("app_cmux_tasks"), "schema mode search_path: {out}");
    let passworded = pg.psql("postgres", "SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_authid WHERE rolpassword IS NOT NULL").unwrap();
    assert_eq!(passworded, "app_cmux_tasks,app_crm,app_notes,cmux_admin");

    // A second ensure is a no-op and keeps the secret.
    let before = std::fs::read(&notes_pass).unwrap();
    let again = pg.ensure_app(&notes, None).unwrap();
    assert!(!again.created_role && !again.created_database);
    assert_eq!(std::fs::read(&notes_pass).unwrap(), before);
    // A pwfile left by a crashed initdb is removed by the next ensure.
    let leftover = PathBuf::from(layout.state.join("postgres/initdb.pw").as_str());
    std::fs::write(&leftover, "stale-secret\n").unwrap();
    let second = pg.ensure_cluster().unwrap();
    assert!(!leftover.exists(), "leftover pwfile removed");
    assert!(!second.created && !second.started);

    // archive-wal: a WAL switch lands a durable segment in the archive.
    pg.psql("app_notes", "SELECT 1").ok();
    pg.psql(
        "postgres",
        "CREATE TABLE IF NOT EXISTS wal_probe AS SELECT generate_series(1, 10000) AS x",
    )
    .unwrap();
    pg.psql("postgres", "SELECT pg_switch_wal()").unwrap();
    let wal_dir = PathBuf::from(layout.wal_archive().as_str());
    let deadline = Instant::now() + Duration::from_secs(60);
    let archived = loop {
        let names: Vec<String> = std::fs::read_dir(&wal_dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !n.starts_with('.'))
            .collect();
        if !names.is_empty() || Instant::now() > deadline {
            break names;
        }
        std::thread::sleep(Duration::from_millis(100)); // test-only wait
    };
    assert!(!archived.is_empty(), "archive_command stored a segment");
    let failed = pg.psql("postgres", "SELECT failed_count FROM pg_stat_archiver").unwrap();
    assert_eq!(failed, "0");
    eprintln!("archived: {archived:?}");

    // basebackup.
    let started = Instant::now();
    let base = pg.backup_now(NOW_MS).unwrap();
    eprintln!("basebackup: {:?}", started.elapsed());
    assert!(base.join("base.tar.gz").is_file(), "{}", base.display());
    assert!(pg.last_wal().is_some());

    // prepare-snapshot stops the cluster; a second stop is a no-op.
    assert!(pg.prepare_snapshot().unwrap());
    assert!(!pg.is_running());
    assert!(!pg.stop().unwrap());
}
