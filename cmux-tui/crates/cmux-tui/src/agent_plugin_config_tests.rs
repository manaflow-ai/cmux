use super::*;

fn raw(json: &str) -> RawAgents {
    serde_json::from_str(json).expect("agents section parses")
}

fn write_sibling(directory: &Path, contents: &[u8], mode: u32) -> PathBuf {
    let sibling = directory.join(BUNDLED_SCREEN_DETECTION_FILE);
    let _ = std::fs::remove_file(&sibling);
    std::fs::write(&sibling, contents).expect("write sibling");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&sibling, std::fs::Permissions::from_mode(mode)).unwrap();
    }
    #[cfg(not(unix))]
    let _ = mode;
    sibling
}

fn host_with_sibling() -> (tempfile::TempDir, PathBuf) {
    let directory = tempfile::tempdir().expect("temp dir");
    let sibling = write_sibling(directory.path(), b"#!/bin/sh\n", 0o755);
    (directory, sibling)
}

fn host(exe_dir: Option<&Path>, supported: bool) -> DaemonHost {
    let candidates =
        exe_dir.map(|dir| dir.join(BUNDLED_SCREEN_DETECTION_FILE)).into_iter().collect();
    DaemonHost { candidates, supported }
}

#[test]
fn bundled_sibling_runs_with_the_reserved_producer_id() {
    let (directory, sibling) = host_with_sibling();
    let options =
        agent_plugin(raw("{}"), &host(Some(directory.path()), true)).expect("default plugin");
    assert_eq!(options.id, BUNDLED_SCREEN_DETECTION_ID);
    assert_eq!(options.id, "cmux_screen_detection");
    assert_eq!(options.command, vec![sibling.to_str().unwrap().to_string()]);
    assert_eq!(options.cwd, None);
    assert_eq!(options.revision, bundled_revision(&sibling));
    assert!(options.revision.is_some(), "the default carries a restart revision");
    options.validate().expect("the default passes the supervisor's validation");
}

#[test]
fn a_replaced_sibling_gets_a_new_revision() {
    // An app update replaces the file (the bundle phase removes, then
    // copies), so the supervisor must see a new revision and restart.
    let (directory, sibling) = host_with_sibling();
    let first = bundled_revision(&sibling).expect("revision");
    assert_eq!(bundled_revision(&sibling).as_deref(), Some(first.as_str()), "stable for one file");
    let replaced = write_sibling(directory.path(), b"#!/bin/sh\n# the next build\n", 0o755);
    let second = bundled_revision(&replaced).expect("revision");
    assert_ne!(first, second, "a replaced detector must restart the child");
    let options = agent_plugin(raw("{}"), &host(Some(directory.path()), true)).unwrap();
    assert_eq!(options.revision.as_deref(), Some(second.as_str()));
}

#[cfg(unix)]
#[test]
fn a_sibling_that_is_not_executable_is_not_run() {
    let directory = tempfile::tempdir().expect("temp dir");
    write_sibling(directory.path(), b"#!/bin/sh\n", 0o644);
    assert!(agent_plugin(raw("{}"), &host(Some(directory.path()), true)).is_none());
}

#[test]
fn screen_detection_true_keeps_the_default() {
    let (directory, _sibling) = host_with_sibling();
    let options =
        agent_plugin(raw(r#"{"screen_detection":true}"#), &host(Some(directory.path()), true));
    assert_eq!(options.map(|options| options.id).as_deref(), Some(BUNDLED_SCREEN_DETECTION_ID));
}

#[test]
fn screen_detection_false_opts_out() {
    let (directory, _sibling) = host_with_sibling();
    let options =
        agent_plugin(raw(r#"{"screen_detection":false}"#), &host(Some(directory.path()), true));
    assert!(options.is_none(), "agents.screen_detection=false must run no bundled plugin");
}

#[test]
fn an_invalid_agents_section_runs_nothing() {
    // config.rs marks a section (or file) that failed to parse: the user's
    // agents settings are unknown, so the bundled default must stay off.
    let (directory, _sibling) = host_with_sibling();
    assert!(agent_plugin(RawAgents::invalid(), &host(Some(directory.path()), true)).is_none());
}

#[test]
fn explicit_plugin_wins_over_the_bundled_sibling() {
    let (directory, _sibling) = host_with_sibling();
    let json = r#"{"plugin":{"id":"mine","command":["/opt/mine/plugin"],"revision":"r1"}}"#;
    let options =
        agent_plugin(raw(json), &host(Some(directory.path()), true)).expect("explicit plugin");
    assert_eq!(options.id, "mine");
    assert_eq!(options.command, vec!["/opt/mine/plugin".to_string()]);
    assert_eq!(options.revision.as_deref(), Some("r1"));
}

#[test]
fn explicit_plugin_still_runs_when_screen_detection_is_off() {
    let (directory, _sibling) = host_with_sibling();
    let json =
        r#"{"screen_detection":false,"plugin":{"id":"mine","command":["/opt/mine/plugin"]}}"#;
    let options = agent_plugin(raw(json), &host(Some(directory.path()), true));
    assert_eq!(options.map(|options| options.id).as_deref(), Some("mine"));
}

#[test]
fn invalid_explicit_plugin_disables_and_never_falls_back() {
    let (directory, _sibling) = host_with_sibling();
    for json in [
        r#"{"plugin":{"command":["/opt/mine/plugin"]}}"#,
        r#"{"plugin":{"id":"mine","command":[]}}"#,
        r#"{"plugin":{"id":"mine","command":["relative/plugin"]}}"#,
        r#"{"plugin":{"id":"cmux_agent","command":["/opt/mine/plugin"]}}"#,
        // The bundled detector's id is reserved for the bundled default.
        r#"{"plugin":{"id":"cmux_screen_detection","command":["/opt/mine/plugin"]}}"#,
    ] {
        let options = agent_plugin(raw(json), &host(Some(directory.path()), true));
        assert!(options.is_none(), "{json} must disable agent plugins, not select the default");
    }
}

#[test]
fn missing_sibling_runs_nothing() {
    let directory = tempfile::tempdir().expect("temp dir");
    assert!(agent_plugin(raw("{}"), &host(Some(directory.path()), true)).is_none());
    assert!(agent_plugin(raw("{}"), &host(None, true)).is_none());
}

#[test]
fn a_directory_named_like_the_plugin_is_not_a_sibling() {
    let directory = tempfile::tempdir().expect("temp dir");
    std::fs::create_dir(directory.path().join(BUNDLED_SCREEN_DETECTION_FILE)).unwrap();
    assert!(agent_plugin(raw("{}"), &host(Some(directory.path()), true)).is_none());
}

#[test]
fn unsupported_platform_runs_nothing() {
    // Windows: the plugin is Unix-only, so the daemon passes supported=false.
    let (directory, _sibling) = host_with_sibling();
    assert!(agent_plugin(raw("{}"), &host(Some(directory.path()), false)).is_none());
}

#[cfg(unix)]
#[test]
fn the_daemon_directory_resolves_a_symlinked_executable() {
    // A PATH link to the bundled `cmux` still finds the app's bin/ siblings.
    let app_bin = tempfile::tempdir().expect("app bin");
    let path_dir = tempfile::tempdir().expect("path dir");
    let exe = app_bin.path().join("cmux");
    std::fs::write(&exe, b"").unwrap();
    let link = path_dir.path().join("cmux");
    std::os::unix::fs::symlink(&exe, &link).unwrap();
    let resolved = std::fs::canonicalize(app_bin.path()).unwrap();
    let candidates = DaemonHost::for_exe(&link).candidates;
    assert_eq!(candidates[0], resolved.join(BUNDLED_SCREEN_DETECTION_FILE));
    assert_eq!(candidates[1], path_dir.path().join(BUNDLED_SCREEN_DETECTION_FILE));
}

#[cfg(unix)]
#[test]
fn screen_detection_finds_a_suffixed_sibling_and_one_beside_the_link() {
    // A download folder of target-suffixed files, and a folder of plain
    // links to them (the round 3 bench layout).
    let downloads = tempfile::tempdir().expect("downloads");
    let links = tempfile::tempdir().expect("links");
    let exe = downloads.path().join("cmux-tui-aarch64-apple-darwin");
    std::fs::write(&exe, b"").unwrap();
    let link = links.path().join("cmux-tui");
    std::os::unix::fs::symlink(&exe, &link).unwrap();
    let status = screen_detection_status(raw("{}"), Some(&link));
    let crate::screen_detection_status::ScreenDetection::NotInstalled { looked_in } = &status
    else {
        panic!("nothing is installed yet: {status:?}");
    };
    assert_eq!(looked_in.len(), 3, "{looked_in:?}");
    let suffixed = write_sibling(downloads.path(), b"#!/bin/sh\n", 0o755);
    let suffixed_path =
        downloads.path().join(format!("{BUNDLED_SCREEN_DETECTION_FILE}-aarch64-apple-darwin"));
    std::fs::rename(&suffixed, &suffixed_path).unwrap();
    let options = agent_plugin(raw("{}"), &DaemonHost::for_exe(&link)).expect("suffixed sibling");
    assert_eq!(
        std::fs::canonicalize(&options.command[0]).unwrap(),
        std::fs::canonicalize(&suffixed_path).unwrap()
    );
    std::fs::remove_file(&suffixed_path).unwrap();
    let beside = write_sibling(links.path(), b"#!/bin/sh\n", 0o755);
    let status = screen_detection_status(raw("{}"), Some(&link));
    assert_eq!(status, crate::screen_detection_status::ScreenDetection::Installed { path: beside });
}

#[test]
fn screen_detection_status_follows_the_agents_settings() {
    use crate::screen_detection_status::ScreenDetection;
    let exe = Path::new("/nonexistent/cmux-tui");
    assert_eq!(
        screen_detection_status(raw(r#"{"screen_detection":false}"#), Some(exe)),
        ScreenDetection::Off
    );
    assert_eq!(
        screen_detection_status(RawAgents::invalid(), Some(exe)),
        ScreenDetection::Unreadable
    );
    let json = r#"{"plugin":{"id":"mine","command":["/opt/mine/plugin"]}}"#;
    assert_eq!(
        screen_detection_status(raw(json), Some(exe)),
        ScreenDetection::Replaced { id: "mine".into() }
    );
    assert_eq!(screen_detection_status(raw("{}"), None), ScreenDetection::Unknown);
}

#[test]
fn unknown_agents_keys_are_still_rejected() {
    assert!(serde_json::from_str::<RawAgents>(r#"{"screen_detect":false}"#).is_err());
}
