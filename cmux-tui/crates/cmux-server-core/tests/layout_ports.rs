//! Layout table (server.md 4.3) and port block (server.md 8.2).

use std::collections::BTreeSet;

use cmux_server_core::access::{
    Access, Ace, PosixOwner, WinPrincipal, WinRights, access_policy, socket_dir_check,
};
use cmux_server_core::layout::{LayoutEnv, LayoutError, ServiceKind, layout};
use cmux_server_core::pg::AppId;
use cmux_server_core::ports::{
    PortError, PortSource, RANGE_LEN, RANGE_START, allocate, first_candidate, fnv1a64,
};
use cmux_server_core::{HostPath, InstallMode, Platform};
use proptest::prelude::*;

fn unix_env(home: &str) -> LayoutEnv {
    LayoutEnv { home: Some(home.to_owned()), uid: Some(501), ..LayoutEnv::default() }
}

fn win_env() -> LayoutEnv {
    LayoutEnv {
        local_app_data: Some(r"C:\Users\ana\AppData\Local".to_owned()),
        app_data: Some(r"C:\Users\ana\AppData\Roaming".to_owned()),
        program_data: Some(r"C:\ProgramData".to_owned()),
        program_files: Some(r"C:\Program Files".to_owned()),
        ..LayoutEnv::default()
    }
}

#[test]
fn linux_user_layout_matches_table() {
    let l = layout(InstallMode::User, Platform::Linux, &unix_env("/home/ana")).unwrap();
    assert_eq!(l.root.as_str(), "/home/ana/.local/share/cmux");
    assert_eq!(l.store.as_str(), "/home/ana/.local/share/cmux/store");
    assert_eq!(l.profiles.as_str(), "/home/ana/.local/share/cmux/profiles");
    assert_eq!(l.current.as_str(), "/home/ana/.local/share/cmux/current");
    assert_eq!(l.current_cmux.as_str(), "/home/ana/.local/share/cmux/current/bin/cmux");
    assert_eq!(l.state.as_str(), "/home/ana/.local/state/cmux/server");
    assert_eq!(l.config_file.as_str(), "/home/ana/.config/cmux/server.json");
    assert_eq!(l.cli_shim.as_str(), "/home/ana/.local/bin/cmux");
    let ServiceKind::SystemdUser { unit_path } = &l.service else { panic!("{:?}", l.service) };
    assert_eq!(unit_path.as_str(), "/home/ana/.config/systemd/user/cmux-server.service");
    assert_eq!(l.postgres_data().as_str(), "/home/ana/.local/state/cmux/server/postgres/17/data");
    assert_eq!(
        l.postgres_socket_dir(17274).as_str(),
        "/home/ana/.local/state/cmux/server/postgres/run"
    );
    assert_eq!(l.update_request(), None);
    assert_eq!(l.wal_archive().as_str(), "/home/ana/.local/state/cmux/server/backups/wal");
    assert_eq!(
        l.postgres_admin_pgpass().as_str(),
        "/home/ana/.local/state/cmux/server/postgres/admin.pgpass"
    );
    let app = AppId::parse("notes").unwrap();
    assert_eq!(l.app_pgpass(&app).as_str(), "/home/ana/.local/state/cmux/server/apps/notes/pgpass");
    let sha = "0f".repeat(32);
    assert_eq!(
        l.store_package(&sha).unwrap().as_str(),
        format!("/home/ana/.local/share/cmux/store/{sha}")
    );
    assert_eq!(l.store_package("../../etc"), None);
    assert_eq!(l.store_package(&"AB".repeat(32)), None);
    assert_eq!(l.profile(7).as_str(), "/home/ana/.local/share/cmux/profiles/7");
}

#[test]
fn linux_user_honors_xdg_and_refuses_relative() {
    let mut env = unix_env("/home/ana/");
    env.xdg_data_home = Some("/data".to_owned());
    env.xdg_state_home = Some("/state/".to_owned());
    env.xdg_config_home = Some(String::new());
    let l = layout(InstallMode::User, Platform::Linux, &env).unwrap();
    assert_eq!(l.root.as_str(), "/data/cmux");
    assert_eq!(l.state.as_str(), "/state/cmux/server");
    assert_eq!(l.config_file.as_str(), "/home/ana/.config/cmux/server.json");
    env.xdg_data_home = Some("relative/dir".to_owned());
    assert_eq!(
        layout(InstallMode::User, Platform::Linux, &env),
        Err(LayoutError::NotAbsolute("XDG_DATA_HOME"))
    );
    assert_eq!(
        layout(InstallMode::User, Platform::Linux, &LayoutEnv::default()),
        Err(LayoutError::Missing("HOME"))
    );
}

#[test]
fn linux_system_layout_matches_table() {
    let l = layout(InstallMode::System, Platform::Linux, &LayoutEnv::default()).unwrap();
    assert_eq!(l.store.as_str(), "/opt/cmux/store");
    assert_eq!(l.current_cmux.as_str(), "/opt/cmux/current/bin/cmux");
    assert_eq!(l.state.as_str(), "/var/lib/cmux");
    assert_eq!(l.config_file.as_str(), "/etc/cmux/server.json");
    assert_eq!(l.cli_shim.as_str(), "/usr/local/bin/cmux");
    assert_eq!(l.postgres_socket_dir(17274).as_str(), "/run/cmux/postgres");
    assert_eq!(l.update_request().unwrap().as_str(), "/run/cmux/update-request");
    let ServiceKind::SystemdSystem { unit_path } = &l.service else { panic!() };
    assert_eq!(unit_path.as_str(), "/etc/systemd/system/cmux-server.service");
}

#[test]
fn macos_headless_and_app_layouts() {
    let l = layout(InstallMode::User, Platform::MacOs, &unix_env("/Users/ana")).unwrap();
    assert_eq!(l.root.as_str(), "/Users/ana/Library/Application Support/cmux");
    assert_eq!(l.state.as_str(), "/Users/ana/Library/Application Support/cmux/server");
    assert_eq!(l.config_file.as_str(), "/Users/ana/.config/cmux/server.json");
    assert_eq!(l.cli_shim.as_str(), "/Users/ana/.local/bin/cmux");
    let ServiceKind::LaunchAgent { plist_path } = &l.service else { panic!() };
    assert_eq!(plist_path.as_str(), "/Users/ana/Library/LaunchAgents/com.cmux.server.plist");
    // <state> is too long for the 103-byte socket limit: the socket is in /tmp.
    assert_eq!(l.postgres_socket_dir(17274).as_str(), "/tmp/cmux-501/pg-17274");
    let no_uid = LayoutEnv { home: Some("/Users/ana".to_owned()), ..LayoutEnv::default() };
    assert_eq!(
        layout(InstallMode::User, Platform::MacOs, &no_uid),
        Err(LayoutError::Missing("uid"))
    );

    let mut env = unix_env("/Users/ana");
    env.mac_app_bundle = Some("/Applications/cmux.app".to_owned());
    let a = layout(InstallMode::User, Platform::MacOs, &env).unwrap();
    assert_eq!(a.store.as_str(), "/Users/ana/Library/Application Support/cmux/store");
    assert_eq!(a.current_cmux.as_str(), "/Applications/cmux.app/Contents/Resources/bin/cmux");
    let ServiceKind::AppServiceAgent { bundled_plist } = &a.service else { panic!() };
    assert_eq!(
        bundled_plist.as_str(),
        "/Applications/cmux.app/Contents/Library/LaunchAgents/com.cmux.server.plist"
    );
    assert_eq!(
        layout(InstallMode::System, Platform::MacOs, &env),
        Err(LayoutError::AppBundleNotApplicable)
    );

    let d = layout(InstallMode::System, Platform::MacOs, &LayoutEnv::default()).unwrap();
    let ServiceKind::LaunchDaemon { plist_path } = &d.service else { panic!() };
    assert_eq!(plist_path.as_str(), "/Library/LaunchDaemons/com.cmux.server.plist");
    assert_eq!(
        d.postgres_socket_dir(17274).as_str(),
        "/Library/Application Support/cmux/server/postgres/run"
    );
}

#[test]
fn windows_layouts_use_backslashes() {
    let u = layout(InstallMode::User, Platform::Windows, &win_env()).unwrap();
    assert_eq!(u.root.as_str(), r"C:\Users\ana\AppData\Local\cmux");
    assert_eq!(u.current_cmux.as_str(), r"C:\Users\ana\AppData\Local\cmux\current\bin\cmux.exe");
    assert_eq!(u.state.as_str(), r"C:\Users\ana\AppData\Local\cmux\server");
    assert_eq!(u.config_file.as_str(), r"C:\Users\ana\AppData\Roaming\cmux\server.json");
    assert_eq!(u.cli_shim.as_str(), r"C:\Users\ana\AppData\Local\cmux\bin\cmux.exe");
    assert_eq!(u.service, ServiceKind::ScheduledTask { task_name: "cmux-server" });

    let s = layout(InstallMode::System, Platform::Windows, &win_env()).unwrap();
    assert_eq!(s.root.as_str(), r"C:\Program Files\cmux");
    assert_eq!(s.store.as_str(), r"C:\Program Files\cmux\store");
    assert_eq!(s.current_cmux.as_str(), r"C:\Program Files\cmux\current\bin\cmux.exe");
    assert_eq!(s.state.as_str(), r"C:\ProgramData\cmux\server");
    assert_eq!(s.config_file.as_str(), r"C:\ProgramData\cmux\server.json");
    assert_eq!(s.cli_shim.as_str(), r"C:\Program Files\cmux\bin\cmux.exe");
    assert_eq!(s.service, ServiceKind::WindowsService { service_name: "cmux-server" });

    let mut bad = win_env();
    bad.local_app_data = Some("/home/ana".to_owned());
    assert_eq!(
        layout(InstallMode::User, Platform::Windows, &bad),
        Err(LayoutError::NotAbsolute("LOCALAPPDATA"))
    );
}

#[test]
fn access_policy_linux_system_store_is_root_owned() {
    let l = layout(InstallMode::System, Platform::Linux, &LayoutEnv::default()).unwrap();
    let policy = access_policy(&l);
    assert_eq!(policy[0].path.as_str(), "/opt/cmux");
    assert_eq!(
        policy[0].access,
        Access::Posix { owner: PosixOwner::Root, group: Some("root"), mode: 0o755 }
    );
    assert_eq!(policy[1].path.as_str(), "/var/lib/cmux");
    assert_eq!(
        policy[1].access,
        Access::Posix { owner: PosixOwner::Named("cmux"), group: Some("cmux"), mode: 0o700 }
    );
    assert!(policy.iter().all(|p| p.no_symlink));
}

#[test]
fn access_policy_macos_user_shares_the_root_and_closes_the_state() {
    // Decision SV-R4: the app may own ~/Library/Application Support/cmux at
    // 0755; the server requires 0700 only on its own `server/` subfolder.
    let l = layout(InstallMode::User, Platform::MacOs, &unix_env("/Users/ana")).unwrap();
    let policy = access_policy(&l);
    assert_eq!(policy[0].path.as_str(), "/Users/ana/Library/Application Support/cmux");
    assert_eq!(
        policy[0].access,
        Access::Posix { owner: PosixOwner::Uid(501), group: None, mode: 0o755 }
    );
    assert_eq!(policy[1].path.as_str(), "/Users/ana/Library/Application Support/cmux/server");
    assert_eq!(
        policy[1].access,
        Access::Posix { owner: PosixOwner::Uid(501), group: None, mode: 0o700 }
    );
    assert!(l.store.as_str().starts_with(policy[0].path.as_str()));
    // Linux user mode keeps its private data root.
    let linux = layout(InstallMode::User, Platform::Linux, &unix_env("/home/ana")).unwrap();
    let Access::Posix { mode, .. } = access_policy(&linux)[0].access else { panic!() };
    assert_eq!(mode, 0o700);
}

#[test]
fn access_policy_windows_system_acls() {
    let l = layout(InstallMode::System, Platform::Windows, &win_env()).unwrap();
    let policy = access_policy(&l);
    let Access::Windows(bin) = &policy[0].access else { panic!() };
    assert_eq!(policy[0].path.as_str(), r"C:\Program Files\cmux");
    assert_eq!(bin.owner, WinPrincipal::Administrators);
    assert!(
        bin.entries
            .contains(&Ace { principal: WinPrincipal::Users, rights: WinRights::ReadExecute })
    );
    assert!(!bin.entries.iter().any(|a| a.principal == WinPrincipal::Service("cmux-server")));
    let Access::Windows(state) = &policy[1].access else { panic!() };
    assert_eq!(policy[1].path.as_str(), r"C:\ProgramData\cmux\server");
    assert!(state.entries.contains(&Ace {
        principal: WinPrincipal::Service("cmux-server"),
        rights: WinRights::Modify
    }));
    assert!(!state.entries.iter().any(|a| a.principal == WinPrincipal::Users));
    assert_eq!(WinPrincipal::Service("cmux-server").as_str(), r"NT SERVICE\cmux-server");
    assert_eq!(WinPrincipal::Administrators.as_str(), "S-1-5-32-544");
}

#[test]
fn macos_socket_dir_check_is_owner_only() {
    let l = layout(InstallMode::User, Platform::MacOs, &unix_env("/Users/ana")).unwrap();
    let checks = socket_dir_check(&l, 17274).unwrap();
    let paths: Vec<&str> = checks.iter().map(|c| c.path.as_str()).collect();
    assert_eq!(paths, ["/tmp/cmux-501", "/tmp/cmux-501/pg-17274"]);
    for c in &checks {
        assert_eq!(
            c.access,
            Access::Posix { owner: PosixOwner::Uid(501), group: None, mode: 0o700 }
        );
        assert!(c.no_symlink);
    }
    let linux = layout(InstallMode::User, Platform::Linux, &unix_env("/home/ana")).unwrap();
    assert_eq!(socket_dir_check(&linux, 17274), None);
}

#[test]
fn host_path_rules() {
    assert!(HostPath::new(Platform::Linux, "relative").is_none());
    assert!(HostPath::new(Platform::Linux, "/a\nb").is_none());
    assert_eq!(HostPath::new(Platform::Linux, "/").unwrap().join("x").as_str(), "/x");
    assert_eq!(HostPath::new(Platform::Windows, "C:/x/").unwrap().as_str(), r"C:\x");
    assert_eq!(HostPath::new(Platform::Windows, r"C:\").unwrap().join("y").as_str(), r"C:\y");
    assert!(HostPath::new(Platform::Windows, r"\\srv\share").is_some());
    assert!(HostPath::new(Platform::Windows, "/unix").is_none());
}

#[test]
fn fnv_and_first_candidate_golden() {
    assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    assert_eq!(first_candidate(""), 21469);
    assert_eq!(first_candidate("a"), 17428);
    assert_eq!(first_candidate("inst_test"), 17274);
}

#[test]
fn allocate_skips_busy_blocks_and_keeps_persisted() {
    let first = first_candidate("inst_test");
    let free = allocate("inst_test", &BTreeSet::new(), None).unwrap();
    assert_eq!(free.block.postgres, first);
    assert_eq!(free.source, PortSource::Allocated);
    assert_eq!(free.block.services[0], first + 1);
    assert_eq!(free.block.services[30], first + 31);

    // A busy port at +31 moves the base past it.
    let busy: BTreeSet<u16> = [first + 31].into();
    let moved = allocate("inst_test", &busy, None).unwrap();
    assert_eq!(moved.block.postgres, first + 32);

    // Persisted wins, even when the port is in use (our own cluster).
    let held: BTreeSet<u16> = [40000].into();
    let p = allocate("inst_test", &held, Some(40000)).unwrap();
    assert_eq!((p.block.postgres, p.source), (40000, PortSource::Persisted));
    assert_eq!(allocate("x", &held, Some(5432)), Err(PortError::InvalidPersisted(5432)));
    assert_eq!(allocate("x", &held, Some(5420)), Err(PortError::InvalidPersisted(5420)));
    assert_eq!(allocate("x", &held, Some(65530)), Err(PortError::InvalidPersisted(65530)));
    assert_eq!(allocate("x", &held, Some(0)), Err(PortError::InvalidPersisted(0)));

    let all: BTreeSet<u16> = (RANGE_START..RANGE_START + RANGE_LEN + 40).collect();
    assert_eq!(allocate("x", &all, None), Err(PortError::Exhausted));
}

proptest! {
    #[test]
    fn first_candidate_in_range(id in ".{0,64}") {
        let p = first_candidate(&id);
        prop_assert!((RANGE_START..RANGE_START + RANGE_LEN).contains(&p));
    }

    #[test]
    fn allocation_avoids_busy_ports_and_5432(
        id in "[a-z0-9_]{1,24}",
        busy in proptest::collection::btree_set(15400u16..25500, 0..400),
    ) {
        let a = allocate(&id, &busy, None).unwrap();
        prop_assert_eq!(a.source, PortSource::Allocated);
        prop_assert!(a.block.ports().all(|p| !busy.contains(&p) && p != 5432));
        prop_assert!((RANGE_START..RANGE_START + RANGE_LEN).contains(&a.block.postgres));
        // Deterministic, and stable once persisted.
        prop_assert_eq!(&allocate(&id, &busy, None).unwrap(), &a);
        let again = allocate(&id, &busy, Some(a.block.postgres)).unwrap();
        prop_assert_eq!(&again.block, &a.block);
        prop_assert_eq!(again.source, PortSource::Persisted);
        // With nothing busy, the first candidate wins.
        if busy.is_empty() {
            prop_assert_eq!(a.block.postgres, first_candidate(&id));
        }
    }
}
