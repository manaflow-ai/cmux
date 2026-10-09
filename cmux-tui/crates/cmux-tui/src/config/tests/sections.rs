//! Tests for config sections: machines, providers, plugins, server, tabs, sidebar, browser.

use super::*;

#[test]
fn machine_config_rejects_misspelled_and_cross_transport_fields() {
    for invalid in [
        r#"{"machines":[{"id":"mini","name":"Mini","transport":"ssh","host":"mini","sesion":"main"}]}"#,
        r#"{"machines":[{"id":"mini","name":"Mini","transport":"ssh","host":"mini","socket":"/tmp/mux.sock"}]}"#,
        r#"{"machines":[{"id":"mini","name":"Mini","transport":"unix","socket":"/tmp/mux.sock","host":"mini"}]}"#,
    ] {
        assert!(serde_json::from_str::<RawConfig>(invalid).is_err(), "accepted {invalid}");
    }
}

#[test]
fn machine_provider_command_parses_and_requires_a_program() {
    let raw: RawConfig = serde_json::from_str(
        r#"{"machine_provider":{"command":["/opt/provider/run.sh","--profile","prod"]}}"#,
    )
    .unwrap();
    assert_eq!(
        raw.machine_provider.command.as_deref(),
        Some(
            ["/opt/provider/run.sh".to_string(), "--profile".into(), "prod".into()].as_slice()
        )
    );

    // An empty argv or blank program is ignored at apply time.
    let raw: RawConfig =
        serde_json::from_str(r#"{"machine_provider":{"command":[]}}"#).unwrap();
    assert!(raw.machine_provider.command.as_deref().is_some_and(|c| c.is_empty()));
    let raw: RawConfig =
        serde_json::from_str(r#"{"machine_provider":{"command":["  "]}}"#).unwrap();
    assert!(raw.machine_provider.command.as_deref().is_some_and(|c| c[0].trim().is_empty()));
}

#[test]
fn agent_plugin_requires_an_explicit_namespace_id() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let directory = TestDirectory::new("agent-plugin-id-required");
    let path = directory.path.join("mux.json");
    std::fs::write(&path, r#"{"agents":{"plugin":{"command":["/tmp/agent-plugin"]}}}"#)
        .unwrap();
    // SAFETY: environment mutation is serialized by CONFIG_ENV_LOCK.
    unsafe {
        std::env::remove_var("CMUX_TUI_CONFIG");
        std::env::set_var("CMUX_MUX_CONFIG", &path);
    }

    let config = load();

    restore_env_var("CMUX_TUI_CONFIG", old_cmux_tui_config);
    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    assert!(
        config.agents.plugin.is_none(),
        "a userland plugin without an explicit producer id must be ignored",
    );
}

#[cfg(unix)]
#[test]
fn unreadable_agents_settings_keep_the_bundled_detector_off() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old = (std::env::var_os("CMUX_TUI_CONFIG"), std::env::var_os("CMUX_MUX_CONFIG"));
    let directory = TestDirectory::new("agents-invalid");
    let (bin, path) = (directory.path.join("bin"), directory.path.join("mux.json"));
    std::fs::create_dir(&bin).unwrap();
    write_executable(bin.join("cmux-agent-screen-detection"), "#!/bin/sh\n");
    let mut plugin_ids = Vec::new();
    for text in [
        "{}",
        r#"{"agents":{"plugin":{"id":"mine","command":"/opt/mine"}}}"#,
        r#"{"agents":{"plugin":{"id":"mine","command":["/opt/mine"],"bogus":1}}}"#,
        r#"{"agents":{"screen_detection":"false"}}"#,
        r#"{"agents":{"screen_detection":false"#,
        "[]",
        r#"{"not_a_section":{}}"#,
    ] {
        std::fs::write(&path, text).unwrap();
        // SAFETY: environment mutation is serialized by CONFIG_ENV_LOCK.
        unsafe {
            std::env::remove_var("CMUX_TUI_CONFIG");
            std::env::set_var("CMUX_MUX_CONFIG", &path);
        }
        let config = crate::agent_plugin_config::with_test_daemon_dir(&bin, load);
        plugin_ids.push(config.agents.plugin.map(|plugin| plugin.id));
    }
    restore_env_var("CMUX_TUI_CONFIG", old.0);
    restore_env_var("CMUX_MUX_CONFIG", old.1);
    let mut expected = vec![None; 7];
    expected[0] = Some("cmux_screen_detection".to_string());
    assert_eq!(plugin_ids, expected, "only a readable config may enable the bundled detector");
}

#[test]
fn zero_static_ssh_port_falls_back_to_the_ssh_default() {
    assert_eq!(normalize_ssh_machine_port("mini", Some(0)), None);
    assert_eq!(normalize_ssh_machine_port("mini", Some(22)), Some(22));
    assert_eq!(normalize_ssh_machine_port("mini", None), None);
}

#[test]
fn parses_websocket_server_config() {
    let raw: RawConfig =
        serde_json::from_str(r#"{"server":{"ws":"127.0.0.1:7681","ws_token":"secret"}}"#)
            .unwrap();
    assert_eq!(raw.server.ws.as_deref(), Some("127.0.0.1:7681"));
    assert_eq!(raw.server.ws_token.as_deref(), Some("secret"));
}

#[test]
fn cloud_provider_defaults_are_inert_and_target_cmux_cloud() {
    let config = Config::default();

    assert!(!config.machine_provider.cloud.enabled);
    assert_eq!(config.machine_provider.cloud.host, "cmux.cloud");
    assert_eq!(config.machine_provider.cloud.user, None);
    assert_eq!(config.machine_provider.cloud.port, None);
    assert_eq!(config.machine_provider.cloud.identity_file, None);
}

#[test]
fn ignores_empty_websocket_server_config_values() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let dir = std::env::temp_dir()
        .join(format!("mux-config-test-empty-websocket-values-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("mux.json");
    std::fs::write(&path, r#"{"server":{"ws":"","ws_token":"   "}}"#).unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };

    let config = load();

    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(config.server.ws, None);
    assert_eq!(config.server.ws_token, None);
}

#[test]
fn tab_labels_are_numbers_except_agents() {
    let tabs = Tabs::default();
    assert_eq!(tab_label(&tabs, 0, "", None), "0");
    assert_eq!(tab_label(&tabs, 1, "zsh", None), "1");
    assert_eq!(tab_label(&tabs, 2, "vim src/main.rs", None), "2");
    // Recognized agent programs surface in the label.
    assert_eq!(tab_label(&tabs, 0, "claude", None), "0 claude");
    assert_eq!(tab_label(&tabs, 3, "✳ Codex CLI", None), "3 codex");
    assert_eq!(tab_label(&tabs, 4, "opencode - fix bug", None), "4 opencode");
    // "pi" matches only as a word, not inside other words.
    assert_eq!(tab_label(&tabs, 5, "pick a file", None), "5");
    assert_eq!(tab_label(&tabs, 5, "pi chat", None), "5 pi");
    assert_eq!(tab_label(&tabs, 5, "pi chat", Some("api")), "api");

    let titled = Tabs { show_titles: true, ..Tabs::default() };
    assert_eq!(tab_label(&titled, 1, "zsh", None), "1 zsh");
}

#[test]
fn tab_selection_actions_use_zero_based_indexes() {
    assert_eq!(Action::select_tab(0).unwrap().tab_index(), Some(0));
    assert_eq!(Action::select_tab(9).unwrap().tab_index(), Some(9));
    assert!(Action::select_tab(10).is_none());
}

#[test]
fn config_overrides_defaults() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!("mux-config-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("mux.json");
    std::fs::write(
        &path,
        r##"{
            "theme": {
                "chrome": "dark",
                "selection_background": "#101010",
                "sidebar_rail": 42,
                "sidebar_active_bg": "#202020",
                "tab_bg": 44,
                "border_style": "rounded"
            },
            "tabs": {"min_width": 9, "solid_background": false},
            "sidebar": {
                "view": "workspaces",
                "width": 30,
                "compact_width": 12,
                "max_width": 38,
                "columns": [
                    {"kind": "machines", "width": 18},
                    {"kind": "workspaces", "width": 24},
                    {"kind": "tabs", "width": 26, "max_width": 40}
                ],
                "plugin": {
                    "command": ["/tmp/sidebar-plugin", "--mode", "test"],
                    "cwd": "/tmp"
                }
            },
            "agents": {
                "plugin": {
                    "id": "screen-detector",
                    "command": ["/tmp/agent-plugin", "", "--mode", "test"],
                    "cwd": "/tmp",
                    "revision": "sha256-test"
                }
            },
            "machine_sidebar": {
                "enabled": true,
                "width": 26,
                "max_width": 34,
                "create_sources": [
                    {"id": "docker", "name": "Docker", "subtitle": "container prototype"},
                    {"id": "e2b", "name": "E2B"}
                ]
            },
            "machine_provider": {
                "cloud": {
                    "enabled": true,
                    "host": "edge.example.com",
                    "user": "lawrence",
                    "port": 2200,
                    "identity_file": "/tmp/cloud-key"
                }
            },
            "machines": [
                {
                    "id": "mini",
                    "name": "Mac mini",
                    "subtitle": "studio",
                    "transport": "ssh",
                    "host": "mini.local",
                    "user": "lawrence",
                    "session": "main"
                }
            ],
            "scrollbar": {"position": "border"},
            "pane": {"padding": 9},
            "status_bar": {"visible": false},
            "viewport": {"animation": false},
            "keys": {
                "alt_shortcuts": false,
                "rename-pane": "r",
                "focus-left": ["left", "alt+h"],
                "next-tab": "none",
                "select-tab-0": "q",
                "browser-edit-url": "u"
            }
        }"##,
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
    let config = load();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    let _ = std::fs::remove_file(&path);
    assert_eq!(config.theme.selection_bg, Color::Rgb(0x10, 0x10, 0x10));
    assert_eq!(config.chrome, ChromeMode::Dark);
    assert!(config.theme_overrides.selection);
    assert_eq!(config.theme.sidebar_rail, Color::Indexed(42));
    assert_eq!(config.theme.sidebar_active_bg, Color::Rgb(0x20, 0x20, 0x20));
    assert_eq!(config.theme.tab_bg, Color::Indexed(44));
    assert!(config.theme_overrides.sidebar_active_bg);
    assert!(config.theme_overrides.tab_bg);
    assert_eq!(config.tabs.min_width, 9);
    assert!(!config.tabs.solid_background);
    assert_eq!(config.sidebar.width, 30);
    assert_eq!(config.sidebar.compact_width, 12);
    assert_eq!(config.sidebar.max_width, 38);
    assert_eq!(config.sidebar.view, SidebarView::Workspaces);
    assert!(config.sidebar.columns_explicit);
    assert_eq!(
        config.sidebar.columns,
        vec![
            SidebarColumn { kind: SidebarColumnKind::Machines, width: 18, max_width: 34 },
            SidebarColumn { kind: SidebarColumnKind::Workspaces, width: 24, max_width: 38 },
            SidebarColumn { kind: SidebarColumnKind::Tabs, width: 26, max_width: 40 },
        ]
    );
    assert!(config.sidebar.views_explicit);
    assert_eq!(
        config.sidebar.views,
        vec![
            SidebarViewSpec::legacy(SidebarColumnKind::Machines, 18, 34),
            SidebarViewSpec::legacy(SidebarColumnKind::Workspaces, 24, 38),
            SidebarViewSpec::legacy(SidebarColumnKind::Tabs, 26, 40),
        ]
    );
    assert_eq!(
        config.machine_sidebar,
        MachineSidebar {
            enabled: true,
            width: 26,
            max_width: 34,
            create_sources: vec![
                MachineCreationSourceConfig {
                    id: "docker".into(),
                    name: "Docker".into(),
                    subtitle: "container prototype".into(),
                },
                MachineCreationSourceConfig {
                    id: "e2b".into(),
                    name: "E2B".into(),
                    subtitle: String::new(),
                },
            ],
        }
    );
    assert_eq!(
        config.machine_provider.cloud,
        CloudProviderConfig {
            enabled: true,
            host: "edge.example.com".into(),
            user: Some("lawrence".into()),
            port: Some(2200),
            identity_file: Some(PathBuf::from("/tmp/cloud-key")),
        }
    );
    assert_eq!(config.machines.len(), 1);
    assert_eq!(config.machines[0].id, "mini");
    assert_eq!(config.machines[0].name, "Mac mini");
    assert!(matches!(
        &config.machines[0].target,
        MachineTargetConfig::Ssh { host, user: Some(user), session, binary, .. }
            if host == "mini.local"
                && user == "lawrence"
                && session == "main"
                && binary == "~/.local/bin/cmux-tui"
    ));
    let plugin = config.sidebar.plugin.as_ref().expect("sidebar plugin config");
    assert_eq!(plugin.command, vec!["/tmp/sidebar-plugin", "--mode", "test"]);
    assert_eq!(plugin.cwd.as_deref(), Some("/tmp"));
    let agent_plugin = config.agents.plugin.as_ref().expect("agent plugin config");
    assert_eq!(agent_plugin.id, "screen-detector");
    assert_eq!(
        agent_plugin.command,
        vec!["/tmp/agent-plugin", "", "--mode", "test"],
        "empty arguments after argv[0] must remain part of the command"
    );
    assert_eq!(agent_plugin.cwd.as_deref(), Some("/tmp"));
    assert_eq!(agent_plugin.revision.as_deref(), Some("sha256-test"));
    assert_eq!(config.scrollbar.position, ScrollbarPosition::Border);
    assert_eq!(config.theme.border_style, BorderStyle::Rounded);
    assert_eq!(config.pane.padding, MAX_PANE_PADDING, "padding clamps to the maximum");
    assert!(!config.status_bar.visible);
    assert!(!config.viewport.animation);
    assert_eq!(
        config.keys.action_for(&KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE)),
        Some(Action::RenameTab)
    );
    assert_eq!(config.keys.action_for(&KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)), None);
    assert_eq!(
        config.keys.action_for(&KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)),
        Action::select_tab(0)
    );
    assert_eq!(
        config.keys.action_for(&KeyEvent::new(KeyCode::Char('u'), KeyModifiers::NONE)),
        Some(Action::BrowserEditUrl)
    );
    assert_eq!(
        config.keys.action_for(&KeyEvent::new(KeyCode::Char('S'), KeyModifiers::SHIFT)),
        Some(Action::FocusSidebar)
    );
    assert_eq!(
        config.keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)),
        None
    );
    assert_eq!(
        config.keys.modeless_action_for(&KeyEvent::new(KeyCode::Char('h'), KeyModifiers::ALT)),
        Some(Action::FocusLeft)
    );
    // Untouched keys keep their default.
    assert_eq!(config.theme.border_inactive, Theme::default().border_inactive);
}

#[test]
fn sidebar_views_parse_flat_columns_and_nested_resource_trees() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let dir =
        std::env::temp_dir().join(format!("cmux-sidebar-views-config-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("cmux-tui.json");
    std::fs::write(
        &path,
        r#"{
            "sidebar": {
                "views": [
                    {
                        "id": "hosts",
                        "levels": ["machines"],
                        "width": 18,
                        "collapse_priority": 7
                    },
                    {
                        "id": "workspace-agents",
                        "levels": ["workspaces", "agents"],
                        "actions": ["new-workspace", "new-tab"],
                        "width": 28
                    },
                    {
                        "id": "workspace-pane-tabs",
                        "levels": ["workspaces", "panes", "tabs"],
                        "actions": [],
                        "width": 32,
                        "max_width": 44
                    }
                ]
            }
        }"#,
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };

    let config = load();

    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(config.sidebar.views_explicit);
    assert!(!config.sidebar.columns_explicit);
    assert_eq!(config.sidebar.views.len(), 3);
    assert_eq!(config.sidebar.views[0].id, "hosts");
    assert_eq!(config.sidebar.views[0].levels, vec![SidebarResourceKind::Machines]);
    assert_eq!(config.sidebar.views[0].width, 18);
    assert_eq!(config.sidebar.views[0].collapse_priority, 7);
    assert_eq!(
        config.sidebar.views[1].levels,
        vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents]
    );
    assert_eq!(config.sidebar.views[1].collapse_priority, 20);
    assert_eq!(
        config.sidebar.views[1].actions,
        vec![
            SidebarActionSpec::plain(Action::NewWorkspace),
            SidebarActionSpec::plain(Action::NewTab)
        ]
    );
    assert_eq!(
        config.sidebar.views[2].levels,
        vec![
            SidebarResourceKind::Workspaces,
            SidebarResourceKind::Panes,
            SidebarResourceKind::Tabs,
        ]
    );
    assert_eq!(config.sidebar.views[2].max_width, 44);
    assert!(config.sidebar.views[2].actions.is_empty());
    assert_eq!(
        config.sidebar.columns,
        vec![SidebarColumn { kind: SidebarColumnKind::Machines, width: 18, max_width: 0 }]
    );
}

#[test]
fn sidebar_profiles_select_one_named_native_layout() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let old_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let dir = std::env::temp_dir()
        .join(format!("cmux-sidebar-profiles-config-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("cmux-tui.json");
    std::fs::write(
        &path,
        r#"{
            "sidebar": {
                "profile": "focused",
                "profiles": [
                    {
                        "id": "full",
                        "name": "Full",
                        "views": [
                            {"id": "machines", "levels": ["machines"]},
                            {"id": "workspaces", "levels": ["workspaces"]},
                            {"id": "tabs", "levels": ["tabs"]}
                        ]
                    },
                    {
                        "id": "focused",
                        "name": "Focused",
                        "views": [
                            {"id": "machines", "levels": ["machines"]},
                            {
                                "id": "workspace-tree",
                                "levels": ["workspaces", "agents"]
                            }
                        ]
                    }
                ]
            }
        }"#,
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };

    let config = load();

    restore_env_var("CMUX_MUX_CONFIG", old_mux_config);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        config.sidebar.views.iter().map(|view| view.id.as_str()).collect::<Vec<_>>(),
        vec!["machines", "workspace-tree"]
    );
    assert!(config.sidebar.views.iter().all(|view| !view.includes(SidebarResourceKind::Tabs)));
}

#[test]
fn sidebar_resources_are_hidden_when_their_view_is_omitted() {
    let sidebar = Sidebar::default();
    assert!(sidebar.views.iter().all(|view| !view.includes(SidebarResourceKind::Agents)));
    assert_eq!(sidebar.views[1].actions, vec![SidebarActionSpec::plain(Action::NewWorkspace)]);
}

#[test]
fn sidebar_view_paths_reject_ambiguous_hierarchies() {
    assert!(validate_sidebar_levels(&[]).is_err());
    assert!(
        validate_sidebar_levels(&[
            SidebarResourceKind::Machines,
            SidebarResourceKind::Workspaces,
        ])
        .is_err()
    );
    assert!(
        validate_sidebar_levels(&[SidebarResourceKind::Tabs, SidebarResourceKind::Workspaces,])
            .is_err()
    );
    assert!(
        validate_sidebar_levels(&[
            SidebarResourceKind::Workspaces,
            SidebarResourceKind::Tabs,
            SidebarResourceKind::Panes,
        ])
        .is_err()
    );
}

/// The launcher keys (cx-kyn5) select nothing any more: an old file with
/// any value in them still loads, and the live browser keys beside them
/// stay in effect instead of the whole section being discarded.
#[test]
fn compatibility_browser_keys_are_ignored_whatever_their_value() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = TestDirectory::new("browser-compat-keys");
    let path = dir.path.join("cmux-tui.json");
    std::fs::write(
        &path,
        r##"{"browser":{"mode":"stealth","chrome_binary":7,"discover":"yes","discover_ports":[1],"user_data_dir":"/x","ephemeral":true,"max_capture_megapixels":1.0,"capture_scale":0.5}}"##,
    )
    .unwrap();
    let old = std::env::var_os("CMUX_TUI_CONFIG");
    unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };
    let config = load();
    restore_env_var("CMUX_TUI_CONFIG", old);
    assert_eq!(config.browser.max_capture_megapixels, 1.0);
    assert_eq!(config.browser.capture_scale, Some(0.5));
    // A key the browser section never had is still rejected (the section
    // falls back to its defaults).
    std::fs::write(&path, r##"{"browser":{"typo":1,"max_capture_megapixels":1.0}}"##).unwrap();
    let old = std::env::var_os("CMUX_TUI_CONFIG");
    unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };
    let config = load();
    restore_env_var("CMUX_TUI_CONFIG", old);
    assert_eq!(
        config.browser.max_capture_megapixels,
        Browser::default().max_capture_megapixels
    );
}

#[test]
fn invalid_section_does_not_discard_valid_sections() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = TestDirectory::new("section-recovery");
    let path = dir.path.join("cmux-tui.json");
    std::fs::write(
        &path,
        r##"{"theme":{"sidebar_rail":42},"browser":{"max_capture_megapixels":"big"}}"##,
    )
    .unwrap();
    let old = std::env::var_os("CMUX_TUI_CONFIG");
    unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };
    let config = load();
    restore_env_var("CMUX_TUI_CONFIG", old);
    assert_eq!(config.theme.sidebar_rail, Color::Indexed(42));
    assert_eq!(
        config.browser.max_capture_megapixels,
        Browser::default().max_capture_megapixels
    );
}

#[test]
fn unknown_top_level_field_keeps_strict_rejection() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir =
        std::env::temp_dir().join(format!("cmux-tui-top-level-strict-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("cmux-tui.json");
    std::fs::write(&path, r##"{"theme":{"sidebar_rail":42},"future":true}"##).unwrap();
    let old = std::env::var_os("CMUX_TUI_CONFIG");
    unsafe { std::env::set_var("CMUX_TUI_CONFIG", &path) };
    let config = load();
    restore_env_var("CMUX_TUI_CONFIG", old);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(config.theme.sidebar_rail, Theme::default().sidebar_rail);
}

#[test]
fn viewport_animation_defaults_on_and_can_be_disabled() {
    let raw: RawConfig = serde_json::from_str(r#"{}"#).unwrap();
    assert!(raw.viewport.animation.is_none());
    assert!(Config::default().viewport.animation);

    let raw: RawConfig = serde_json::from_str(r#"{"viewport":{"animation":false}}"#).unwrap();
    assert_eq!(raw.viewport.animation, Some(false));

    let error = serde_json::from_str::<RawConfig>(r#"{"viewport":{"animation":"slow"}}"#)
        .unwrap_err()
        .to_string();
    assert!(error.contains("invalid type"), "{error}");
}

#[test]
fn config_path_prefers_cmux_tui_json_and_falls_back_to_legacy_mux_json() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-config-path-test-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let config_dir = dir.join("cmux");
    std::fs::create_dir_all(&config_dir).unwrap();
    let preferred = config_dir.join("cmux-tui.json");
    let legacy = config_dir.join("mux.json");
    let old_cmux_tui_config = std::env::var_os("CMUX_TUI_CONFIG");
    let old_cmux_mux_config = std::env::var_os("CMUX_MUX_CONFIG");
    let old_xdg_config_home = std::env::var_os("XDG_CONFIG_HOME");

    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe {
        std::env::remove_var("CMUX_TUI_CONFIG");
        std::env::remove_var("CMUX_MUX_CONFIG");
        std::env::set_var("XDG_CONFIG_HOME", &dir);
    }

    assert_eq!(platform::config_path().as_deref(), Some(preferred.as_path()));

    std::fs::write(&legacy, "{}").unwrap();
    assert_eq!(platform::config_path().as_deref(), Some(legacy.as_path()));

    std::fs::write(&preferred, "{}").unwrap();
    assert_eq!(platform::config_path().as_deref(), Some(preferred.as_path()));

    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe {
        match old_cmux_tui_config {
            Some(value) => std::env::set_var("CMUX_TUI_CONFIG", value),
            None => std::env::remove_var("CMUX_TUI_CONFIG"),
        }
        match old_cmux_mux_config {
            Some(value) => std::env::set_var("CMUX_MUX_CONFIG", value),
            None => std::env::remove_var("CMUX_MUX_CONFIG"),
        }
        match old_xdg_config_home {
            Some(value) => std::env::set_var("XDG_CONFIG_HOME", value),
            None => std::env::remove_var("XDG_CONFIG_HOME"),
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn browser_capture_config_validates_bounds() {
    let _guard = CONFIG_ENV_LOCK.lock().unwrap();
    let dir = std::env::temp_dir()
        .join(format!("mux-config-test-browser-capture-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("mux.json");
    std::fs::write(
        &path,
        r##"{"browser": {"max_capture_megapixels": 1.5, "capture_scale": 0.5}}"##,
    )
    .unwrap();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::set_var("CMUX_MUX_CONFIG", &path) };
    let config = load();
    assert_eq!(config.browser.max_capture_megapixels, 1.5);
    assert_eq!(config.browser.capture_scale, Some(0.5));

    std::fs::write(
        &path,
        r##"{"browser": {"max_capture_megapixels": 3.5, "capture_scale": 0.5}}"##,
    )
    .unwrap();
    let config = load();
    assert_eq!(config.browser.max_capture_megapixels, TRANSPORT_SAFE_CAPTURE_MEGAPIXELS);
    assert_eq!(config.browser.capture_scale, Some(0.5));

    std::fs::write(
        &path,
        r##"{"browser": {"max_capture_megapixels": 0, "capture_scale": 1.5}}"##,
    )
    .unwrap();
    let config = load();
    // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
    unsafe { std::env::remove_var("CMUX_MUX_CONFIG") };
    let _ = std::fs::remove_file(&path);
    assert_eq!(
        config.browser.max_capture_megapixels,
        Browser::default().max_capture_megapixels
    );
    assert_eq!(config.browser.capture_scale, None);
}
