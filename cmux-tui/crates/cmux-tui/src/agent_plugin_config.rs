#[cfg(test)]
mod tests {
    use super::*;

    fn raw(json: &str) -> RawAgents {
        serde_json::from_str(json).expect("agents section parses")
    }

    fn host_with_sibling() -> (tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().expect("temp dir");
        let sibling = directory.path().join(BUNDLED_SCREEN_DETECTION_FILE);
        std::fs::write(&sibling, b"#!/bin/sh\n").expect("write sibling");
        (directory, sibling)
    }

    fn host(exe_dir: Option<&Path>, supported: bool) -> DaemonHost<'_> {
        DaemonHost { exe_dir, revision: "0.1.0 (abc123)", supported }
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
        assert_eq!(options.revision.as_deref(), Some("0.1.0 (abc123)"));
        options.validate().expect("the default passes the supervisor's validation");
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
    fn explicit_plugin_wins_over_the_bundled_sibling() {
        let (directory, _sibling) = host_with_sibling();
        let json = r#"{"plugin":{"id":"mine","command":["/opt/mine/plugin"],"revision":"r1"}}"#;
        let options = agent_plugin(raw(json), &host(Some(directory.path()), true))
            .expect("explicit plugin");
        assert_eq!(options.id, "mine");
        assert_eq!(options.command, vec!["/opt/mine/plugin".to_string()]);
        assert_eq!(options.revision.as_deref(), Some("r1"));
    }

    #[test]
    fn explicit_plugin_still_runs_when_screen_detection_is_off() {
        let (directory, _sibling) = host_with_sibling();
        let json = r#"{"screen_detection":false,"plugin":{"id":"mine","command":["/opt/mine/plugin"]}}"#;
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

    #[test]
    fn this_daemon_supports_the_default_only_on_unix() {
        assert_eq!(this_daemon_supports_bundled_plugin(), cfg!(unix));
    }

    #[test]
    fn unknown_agents_keys_are_still_rejected() {
        assert!(serde_json::from_str::<RawAgents>(r#"{"screen_detect":false}"#).is_err());
    }
}
