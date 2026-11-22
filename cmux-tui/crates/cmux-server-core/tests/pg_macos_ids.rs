//! macOS Postgres auth, the manifest id mapping and the hard database cap.

use cmux_server_core::pg::{
    AppDb, AppId, AppIdError, AppLimits, ClusterSpec, DbMode, PgError, PgPlan, valid_manifest_id,
};
use cmux_server_core::{HostPath, InstallMode, Platform};
use proptest::prelude::*;

fn mac(s: &str) -> HostPath {
    HostPath::new(Platform::MacOs, s).unwrap()
}

/// macOS: every app runs as the service user in both modes, so the admin
/// and the apps use SCRAM, never peer (server.md 8.3).
fn macos_spec(mode: InstallMode) -> ClusterSpec {
    let state = match mode {
        InstallMode::User => "/Users/ana/Library/Application Support/cmux/server",
        InstallMode::System => "/Library/Application Support/cmux/server",
    };
    let socket = match mode {
        InstallMode::User => "/tmp/cmux-501/pg-17274".to_owned(),
        InstallMode::System => format!("{state}/postgres/run"),
    };
    ClusterSpec {
        mode,
        platform: Platform::MacOs,
        pg_bin_dir: mac("/Users/ana/Library/Application Support/cmux/current/pg/bin"),
        data_dir: mac(&format!("{state}/postgres/17/data")),
        socket_dir: mac(&socket),
        port: 17274,
        cmux_bin: mac("/Users/ana/Library/Application Support/cmux/current/bin/cmux"),
        service_user: "ana".to_owned(),
        admin_pwfile: Some(mac(&format!("{state}/postgres/initdb.pw"))),
    }
}

fn app(id: &str, mode: DbMode) -> AppDb {
    AppDb { id: AppId::parse(id).unwrap(), mode, tcp: false }
}

#[test]
fn macos_both_modes_use_scram_not_peer() {
    for mode in [InstallMode::User, InstallMode::System] {
        let plan = PgPlan::new(macos_spec(mode)).unwrap();
        assert!(!plan.uses_peer(), "{mode:?}");
        let apps = [app("notes", DbMode::Database)];
        let hba = plan.pg_hba_conf(&apps);
        assert!(!hba.contains("peer"), "{mode:?}: {hba}");
        assert!(hba.contains(
            "\nlocal all cmux_admin scram-sha-256\nlocal replication cmux_admin scram-sha-256\nlocal sameuser app_notes scram-sha-256\n"
        ));
        assert!(plan.pg_ident_conf(&apps).ends_with("# MAPNAME SYSTEM-USERNAME PG-USERNAME\n"));
        let argv = plan.initdb_argv();
        assert!(argv.contains(&"--auth-local=scram-sha-256".to_owned()));
        assert!(argv.contains(&"--auth-host=reject".to_owned()));
        assert!(argv.iter().any(|a| a.starts_with("--pwfile=")));
        assert!(plan.app_needs_password(&apps[0]));
        let conf = plan.postgresql_conf(&apps);
        assert!(conf.contains("unix_socket_permissions = 0700\n"), "{conf}");
        assert!(!conf.contains("unix_socket_group"));
    }
    let user = PgPlan::new(macos_spec(InstallMode::User)).unwrap();
    assert!(
        user.postgresql_conf(&[])
            .contains("unix_socket_directories = '\"/tmp/cmux-501/pg-17274\"'\n")
    );
}

#[test]
fn macos_system_without_pwfile_is_refused() {
    let mut s = macos_spec(InstallMode::System);
    s.admin_pwfile = None;
    assert_eq!(PgPlan::new(s), Err(PgError::PwfileMismatch));
}

#[test]
fn manifest_ids_map_to_app_ids() {
    let cases = [
        ("cmux/tasks", "cmux_tasks"),
        ("local/my-app", "local_my_app"),
        ("9lives/x", "a_9lives_x"),
        ("acme-co/crm", "acme_co_crm"),
    ];
    for (id, want) in cases {
        assert_eq!(AppId::from_manifest_id(id).unwrap().as_str(), want, "{id}");
    }
    assert_eq!(AppId::from_manifest_id("cmux/tasks").unwrap().role(), "app_cmux_tasks");
    // Long ids: first 31 bytes, `_`, 8 hex of SHA-256 of the full id.
    let long = "manaflow-ai/a-very-long-application-name-for-testing";
    let mapped = AppId::from_manifest_id(long).unwrap();
    assert_eq!(mapped.as_str().len(), 40);
    assert!(mapped.as_str().starts_with("manaflow_ai_a_very_long_applica_"));
    // SHA-256("manaflow-ai/a-very-long-application-name-for-testing")[..4], hex.
    assert_eq!(&mapped.as_str()[32..], &sha256_prefix(long));
    let other = AppId::from_manifest_id("manaflow-ai/a-very-long-application-name-for-testinG");
    assert_eq!(other, Err(AppIdError::ManifestGrammar));
    for bad in [
        "",
        "tasks",
        "Cmux/tasks",
        "cmux/",
        "/tasks",
        "cmux/tasks/x",
        "cmux/ta sks",
        "-x/y",
        "cmux/_x",
        "cmux/a.b",
    ] {
        assert_eq!(AppId::from_manifest_id(bad), Err(AppIdError::ManifestGrammar), "{bad:?}");
        assert!(!valid_manifest_id(bad), "{bad:?}");
    }
    assert!(valid_manifest_id(&format!("{}/{}", "p".repeat(39), "n".repeat(64))));
    assert!(!valid_manifest_id(&format!("{}/{}", "p".repeat(40), "n")));
    assert!(!valid_manifest_id(&format!("p/{}", "n".repeat(65))));
}

/// Expected hash part, computed independently of the crate's code path.
fn sha256_prefix(id: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(id.as_bytes())[..4].iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn collisions_are_visible_to_the_caller() {
    // The mapping is not injective; the caller refuses the second install.
    assert_eq!(
        AppId::from_manifest_id("a-b/c").unwrap(),
        AppId::from_manifest_id("a/b-c").unwrap()
    );
}

#[test]
fn hard_cap_blocks_connections_and_ends_sessions() {
    let plan = PgPlan::new(macos_spec(InstallMode::User)).unwrap();
    let a = app("crm", DbMode::Schema);
    let sql: Vec<String> = plan.block_sql(&a).into_iter().map(|s| s.sql).collect();
    assert_eq!(
        sql,
        [
            "ALTER ROLE \"app_crm\" CONNECTION LIMIT 0",
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'app_crm'",
        ]
    );
    assert_eq!(
        plan.unblock_sql(&a, &AppLimits::default()).sql,
        "ALTER ROLE \"app_crm\" CONNECTION LIMIT 20"
    );
    assert_eq!(
        plan.advisory_read_only_sql(&a, false).sql,
        "ALTER ROLE \"app_crm\" SET default_transaction_read_only = off"
    );
}

proptest! {
    /// Every id of the manifest grammar maps to a valid app id of at most
    /// 40 bytes, deterministically.
    #[test]
    fn manifest_mapping_is_total_on_the_grammar(
        publisher in "[a-z0-9][a-z0-9-]{0,38}",
        name in "[a-z0-9][a-z0-9-]{0,63}",
    ) {
        let id = format!("{publisher}/{name}");
        let mapped = AppId::from_manifest_id(&id).unwrap();
        prop_assert!(mapped.as_str().len() <= 40);
        prop_assert_eq!(&AppId::from_manifest_id(&id).unwrap(), &mapped);
        prop_assert_eq!(AppId::parse(mapped.as_str()), Ok(mapped));
    }
}
