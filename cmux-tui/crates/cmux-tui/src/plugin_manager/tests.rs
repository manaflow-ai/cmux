use super::*;

#[test]
fn automatic_updates_only_use_remote_sources() {
    for source in [
        "https://github.com/manaflow-ai/cmux-sidebar-fzf",
        "ssh://git@github.com/manaflow-ai/cmux-sidebar-fzf.git",
        "git@github.com:manaflow-ai/cmux-sidebar-fzf.git",
    ] {
        assert!(is_auto_update_source(source), "remote source should update: {source}");
    }
    for source in [
        "file:///tmp/cmux-sidebar-fzf",
        "/Users/me/src/cmux-sidebar-fzf",
        "../cmux-sidebar-fzf",
        "http://github.com/manaflow-ai/cmux-sidebar-fzf",
    ] {
        assert!(
            !is_auto_update_source(source),
            "local or insecure source should stay manual: {source}"
        );
    }
}

#[test]
fn automatic_updates_require_a_clean_origin_tracking_branch() {
    let clean =
        "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -1\n";
    assert!(auto_update_status_is_safe(clean));
    assert!(!auto_update_status_is_safe(
        "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +1 -0\n"
    ));
    assert!(!auto_update_status_is_safe(
        "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0\n1 .M N... 100644 100644 100644 abc def file\n"
    ));
    assert!(!auto_update_status_is_safe("# branch.oid abc\n# branch.head (detached)\n"));
}

#[test]
fn automatic_update_marker_waits_a_day() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-auto-update-test-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    assert!(auto_update_due(&root, 1_000));
    write_auto_update_marker(&root, 1_000).unwrap();
    assert!(!auto_update_due(&root, 1_000 + AUTO_UPDATE_INTERVAL.as_secs() - 1));
    assert!(auto_update_due(&root, 1_000 + AUTO_UPDATE_INTERVAL.as_secs()));
    fs::remove_dir_all(root).unwrap();
}

fn manifest_text(name: &str) -> String {
    format!(
        r#"
            [plugin]
            name = "{name}"
            kind = "sidebar"
            version = "0.1.0"
            description = "test plugin"

            [run]
            command = ["bin/sidebar"]
            "#
    )
}

#[test]
fn manifest_parse_validates_required_fields() {
    let manifest = parse_manifest(&manifest_text("fzf")).unwrap();
    assert_eq!(manifest.plugin.name, "fzf");
    assert_eq!(manifest.plugin.kind, "sidebar");
    assert_eq!(manifest.run.command, vec!["bin/sidebar"]);
}

#[test]
fn manifest_rejects_bad_kind() {
    let text = manifest_text("fzf").replace("sidebar", "pane");
    let error = parse_manifest(&text).unwrap_err().to_string();
    assert!(error.contains("plugin.kind"));
}

#[test]
fn manifest_rejects_bad_name_chars() {
    let error = parse_manifest(&manifest_text("../bad")).unwrap_err().to_string();
    assert!(error.contains("[a-z0-9-_]+"));
}

#[test]
fn manifest_rejects_overlong_name() {
    let name = "a".repeat(MAX_PLUGIN_NAME_BYTES + 1);
    let error = parse_manifest(&manifest_text(&name)).unwrap_err().to_string();
    assert!(error.contains("[a-z0-9-_]+"));
}

#[test]
fn manifest_rejects_missing_run_command() {
    let text = r#"
            [plugin]
            name = "fzf"
            kind = "sidebar"
        "#;
    let error = parse_manifest(text).unwrap_err().to_string();
    assert!(error.contains("missing field `run`") || error.contains("run.command"));
}

#[test]
fn manifest_platforms_are_validated_and_current_platform_is_admitted() {
    let current = current_plugin_platform();
    if current == "other" {
        return;
    }
    let text = manifest_text("fzf").replace(
        "description = \"test plugin\"",
        &format!("description = \"test plugin\"\n            platforms = [\"{current}\"]"),
    );
    let manifest = parse_manifest(&text).unwrap();
    ensure_manifest_platform_supported(&manifest).unwrap();

    let unsupported = if current == "macos" { "linux" } else { "macos" };
    let text = manifest_text("fzf").replace(
        "description = \"test plugin\"",
        &format!("description = \"test plugin\"\n            platforms = [\"{unsupported}\"]"),
    );
    let manifest = parse_manifest(&text).unwrap();
    assert!(ensure_manifest_platform_supported(&manifest).is_err());
}

#[test]
fn manifest_rejects_unknown_and_duplicate_platforms() {
    for platforms in
        ["platforms = [\"plan9\"]", "platforms = [\"linux\", \"linux\"]", "platforms = []"]
    {
        let text = manifest_text("fzf").replace(
            "description = \"test plugin\"",
            &format!("description = \"test plugin\"\n            {platforms}"),
        );
        assert!(parse_manifest(&text).is_err(), "{platforms}");
    }
}

#[test]
fn manifest_rejects_unknown_fields_and_unsafe_argv() {
    let unknown = manifest_text("fzf").replace(
        "description = \"test plugin\"",
        "description = \"test plugin\"\n            unexpected = true",
    );
    assert!(parse_manifest(&unknown).is_err(), "unknown manifest fields must fail closed");

    let empty_executable =
        manifest_text("fzf").replace("command = [\"bin/sidebar\"]", "command = [\"\", \"kept\"]");
    assert!(parse_manifest(&empty_executable).is_err());

    let nul_argument = manifest_text("fzf")
        .replace("command = [\"bin/sidebar\"]", "command = [\"bin/sidebar\", \"bad\\u0000arg\"]");
    assert!(parse_manifest(&nul_argument).is_err());

    let too_many = (0..=MAX_PLUGIN_COMMAND_ARGS)
        .map(|index| format!("\"arg-{index}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let too_many = manifest_text("fzf").replace(
        "command = [\"bin/sidebar\"]",
        &format!("command = [\"bin/sidebar\", {too_many}]"),
    );
    assert!(parse_manifest(&too_many).is_err());
}

#[test]
fn relative_run_command_cannot_escape_plugin_directory() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-command-boundary-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    let plugin_dir = root.join("plugin");
    let outside_dir = root.join("outside");
    fs::create_dir_all(&plugin_dir).unwrap();
    fs::create_dir_all(&outside_dir).unwrap();
    let outside_executable = outside_dir.join("agent");
    fs::write(&outside_executable, b"#!/bin/sh\n").unwrap();

    let mut manifest = parse_manifest(&manifest_text("fzf")).unwrap();
    manifest.run.command[0] = "../outside/agent".into();
    let error = resolved_run_command(&manifest, &plugin_dir).unwrap_err().to_string();
    assert!(error.contains("escapes plugin directory"), "{error}");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn bounded_manifest_reader_rejects_oversized_files() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-manifest-limit-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    let path = root.join("cmux-plugin.toml");
    fs::write(&path, vec![b'x'; MAX_PLUGIN_MANIFEST_BYTES + 1]).unwrap();
    let error = read_manifest(&root, PluginKind::Sidebar).unwrap_err().to_string();
    assert!(error.contains("manifest limit"), "{error}");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn bounded_plugin_text_reader_rejects_oversized_files() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-text-limit-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    let path = root.join("plugin.json");
    fs::write(&path, b"four").unwrap();
    let error = read_bounded_plugin_text(&path, 3).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    assert!(error.to_string().contains("3-byte limit"), "{error}");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn bounded_child_stdout_reader_rejects_oversized_output() {
    let mut exact = Command::new("sh")
        .args(["-c", "printf four"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert_eq!(read_bounded_child_stdout(&mut exact, 4), Some(b"four".to_vec()));

    let mut oversized = Command::new("sh")
        .args(["-c", "printf four"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert_eq!(read_bounded_child_stdout(&mut oversized, 3), None);
    assert!(oversized.try_wait().unwrap().is_some());
}

#[test]
fn plugin_registry_rejects_an_unbounded_entry_count() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-registry-entry-limit-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    for index in 0..=MAX_INSTALLED_PLUGIN_ENTRIES {
        fs::create_dir(root.join(format!("plugin-{index}"))).unwrap();
    }

    let error = bounded_plugin_registry_entries(&root).unwrap_err().to_string();
    assert!(error.contains("plugin registry") && error.contains("entry limit"), "{error}");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn artifact_digest_handles_multiple_read_chunks() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-artifact-digest-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    let path = root.join("plugin");
    let bytes = (0..(ARTIFACT_HASH_BUFFER_BYTES * 2 + 17))
        .map(|index| (index % 251) as u8)
        .collect::<Vec<_>>();
    fs::write(&path, &bytes).unwrap();

    let mut actual = Sha256::new();
    update_file_digest(fs::File::open(&path).unwrap(), &mut actual).unwrap();
    assert_eq!(actual.finalize(), Sha256::digest(&bytes));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn installed_name_uses_manifest_or_override() {
    let manifest = parse_manifest(&manifest_text("fzf")).unwrap();
    assert_eq!(installed_name(&manifest, None).unwrap(), "fzf");
    assert_eq!(installed_name(&manifest, Some("custom-name")).unwrap(), "custom-name");
    assert!(installed_name(&manifest, Some("Bad")).is_err());
}

#[test]
fn update_preserves_an_explicit_install_alias() {
    let installed_manifest = parse_manifest(&manifest_text("fzf")).unwrap();
    let updated_manifest = parse_manifest(&manifest_text("fzf")).unwrap();
    let installed = InstalledPlugin {
        id: "sidebar_plugin_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
        name: "custom-name".into(),
        manifest: installed_manifest,
        dir: PathBuf::from("/tmp/custom-name"),
        selected: false,
    };

    validate_update_manifest_name(&installed, &updated_manifest).unwrap();
    assert_eq!(installed.name, "custom-name");
}

#[test]
fn update_rejects_a_manifest_identity_change_even_for_an_alias() {
    let installed_manifest = parse_manifest(&manifest_text("fzf")).unwrap();
    let updated_manifest = parse_manifest(&manifest_text("other")).unwrap();
    let installed = InstalledPlugin {
        id: "sidebar_plugin_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
        name: "custom-name".into(),
        manifest: installed_manifest,
        dir: PathBuf::from("/tmp/custom-name"),
        selected: false,
    };

    let error =
        validate_update_manifest_name(&installed, &updated_manifest).unwrap_err().to_string();
    assert!(error.contains("changed its manifest name"), "{error}");
}

#[test]
fn registry_assigns_and_persists_secure_opaque_ids() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-registry-test-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&root).unwrap();

    let first = PluginRegistryMetadata { id: random_plugin_id().unwrap() };
    replace_registry_metadata(&root, "first", &first, PluginKind::Sidebar).unwrap();
    let replay = read_registry_metadata(&root, "first", PluginKind::Sidebar).unwrap();
    let second = PluginRegistryMetadata { id: random_plugin_id().unwrap() };
    replace_registry_metadata(&root, "second", &second, PluginKind::Sidebar).unwrap();
    assert_eq!(first.id, replay.id);
    assert_ne!(first.id, second.id);
    validate_plugin_id(&first.id).unwrap();
    validate_plugin_id(&second.id).unwrap();
    assert_eq!(
        serde_json::from_str::<PluginRegistryMetadata>(
            &fs::read_to_string(registry_metadata_path(&root, "first")).unwrap()
        )
        .unwrap()
        .id,
        first.id
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn install_transaction_restores_the_previous_artifact_and_identity() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-transaction-test-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    let target = root.join("agent-view");
    let staged = root.join(".staged");
    fs::create_dir_all(target.join("bin")).unwrap();
    fs::write(target.join("bin/old"), "old artifact").unwrap();
    fs::create_dir_all(staged.join("bin")).unwrap();
    fs::write(staged.join("bin/new"), "new artifact").unwrap();

    let old_metadata =
        PluginRegistryMetadata { id: "sidebar_plugin_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into() };
    replace_registry_metadata(&root, "agent-view", &old_metadata, PluginKind::Sidebar).unwrap();
    let new_metadata =
        PluginRegistryMetadata { id: "sidebar_plugin_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into() };

    let transaction = replace_plugin_install(
        &root,
        "agent-view",
        &staged,
        &target,
        &new_metadata,
        PluginKind::Sidebar,
    )
    .unwrap();
    assert!(target.join("bin/new").is_file());
    assert_eq!(
        read_registry_metadata(&root, "agent-view", PluginKind::Sidebar).unwrap().id,
        new_metadata.id
    );

    transaction.rollback().unwrap();
    assert!(target.join("bin/old").is_file());
    assert!(!target.join("bin/new").exists());
    assert_eq!(
        read_registry_metadata(&root, "agent-view", PluginKind::Sidebar).unwrap().id,
        old_metadata.id
    );
    assert!(!staged.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn plugin_snapshot_matches_the_closed_catalog_shape() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-snapshot-test-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let executable = bin.join("sidebar");
    fs::write(&executable, "#!/bin/sh\nexit 0\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let snapshot = plugin_json(&InstalledPlugin {
        id: "sidebar_plugin_11111111111111111111111111111111".into(),
        name: "custom-name".into(),
        manifest: parse_manifest(&manifest_text("manifest-name")).unwrap(),
        dir: root.clone(),
        selected: true,
    });
    let keys = snapshot
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(keys, ["active", "enabled", "extra", "id", "name", "source"].into_iter().collect());
    assert_eq!(snapshot["id"], "sidebar_plugin_11111111111111111111111111111111");
    assert_eq!(snapshot["name"], "custom-name");
    assert_eq!(snapshot["active"], true);
    assert_eq!(snapshot["enabled"], true);
    assert_eq!(snapshot["extra"]["manifest_name"], "manifest-name");
    assert!(snapshot.get("revision").is_none());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn plugin_source_never_exposes_url_credentials() {
    assert_eq!(
        sanitized_git_source("https://user:secret@example.com/team/plugin.git?token=secret"),
        "https://example.com/team/plugin.git"
    );
    assert_eq!(
        sanitized_git_source("ssh://git@example.com/team/plugin.git"),
        "ssh://example.com/team/plugin.git"
    );
    assert_eq!(
        sanitized_git_source("git@example.com:team/plugin.git"),
        "git@example.com:team/plugin.git"
    );
}

#[test]
fn git_source_rejects_embedded_credentials_and_query_tokens() {
    for source in [
        "https://user:secret@example.com/team/plugin.git",
        "https://user@example.com/team/plugin.git",
        "https://example.com/team/plugin.git?token=secret",
        "http://example.com/team/plugin.git#token",
    ] {
        assert!(validate_git_source(source).is_err(), "unsafe source must be rejected: {source}");
    }

    for source in [
        "ssh://git@example.com/team/plugin.git",
        "git@example.com:team/plugin.git",
        "/tmp/plugin.git",
    ] {
        assert!(validate_git_source(source).is_ok(), "normal source must remain valid: {source}");
    }
}

#[test]
fn git_source_rejects_custom_transports_and_helpers() {
    for source in [
        "ext::sh -c 'curl https://attacker.invalid'",
        "hg::https://example.com/team/plugin",
        "ftp://example.com/team/plugin.git",
        "git://token@example.com/team/plugin.git",
        "--separate-git-dir=/tmp/attacker",
        "ssh://-oProxyCommand=id/repo.git",
        "ssh://git@-oProxyCommand=id/repo.git",
        "ssh://-oProxyCommand=id@trusted-host/repo.git",
    ] {
        assert!(
            validate_git_source(source).is_err(),
            "custom Git transport must be rejected: {source}"
        );
    }
    assert!(validate_git_source("/tmp/plugin:variant@repo").is_ok());
    assert!(validate_git_source("C:\\tmp\\plugin:variant@repo").is_ok());
    assert!(validate_git_source("https://[2001:db8::1]/team/plugin.git").is_ok());
    assert!(validate_git_source("ssh://git@[::1]/team/plugin.git").is_ok());
}

#[test]
fn plugin_build_environment_scrubs_secret_values() {
    for name in [
        "GITHUB_TOKEN",
        "AWS_SECRET_ACCESS_KEY",
        "SERVICE_PASSWORD",
        "OPENAI_API_KEY",
        "SSH_PRIVATE_KEY",
        "AWS_ACCESS_KEY_ID",
        "DOCKER_AUTH_CONFIG",
        "SSH_AUTH_SOCK",
    ] {
        assert!(is_sensitive_env_name(name), "secret environment name: {name}");
        assert!(!is_safe_plugin_build_env_name(name), "secret environment name: {name}");
    }
    for name in ["PATH", "HOME", "RUSTUP_HOME"] {
        assert!(!is_sensitive_env_name(name), "build environment name: {name}");
    }
    assert!(is_safe_plugin_build_env_name("PATH"));
    assert!(is_safe_plugin_build_env_name("LC_CTYPE"));
    for name in ["RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "CARGO_HOME", "CARGO_BUILD_TARGET", "RUSTFLAGS"]
    {
        assert!(is_safe_plugin_build_env_name(name), "toolchain environment name: {name}");
    }
}

#[test]
fn selection_matching_uses_id_then_path_or_command_migrations() {
    let root = std::env::temp_dir().join(format!(
        "cmux-plugin-selection-test-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    let dir = root.join("agent-view");
    let executable = dir.join("bin/sidebar");
    fs::create_dir_all(executable.parent().unwrap()).unwrap();
    fs::write(&executable, "#!/bin/sh\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let manifest = parse_manifest(&manifest_text("agent-view")).unwrap();
    let id = "sidebar_plugin_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    let by_id = SelectedPluginConfig { id: Some(id.into()), ..Default::default() };
    assert!(plugin_is_selected(Some(&by_id), id, &manifest, &dir));

    let by_path = SelectedPluginConfig { cwd: Some(dir.clone()), ..Default::default() };
    assert!(plugin_is_selected(Some(&by_path), "other", &manifest, &dir));

    let shared_cwd_with_other_command = SelectedPluginConfig {
        cwd: Some(dir.clone()),
        command: Some(vec!["/tmp/other-plugin".into()]),
        ..Default::default()
    };
    assert!(!plugin_is_selected(Some(&shared_cwd_with_other_command), "other", &manifest, &dir));

    let command = resolved_run_command(&manifest, &dir).unwrap();
    let by_command = SelectedPluginConfig { command: Some(command), ..Default::default() };
    assert!(plugin_is_selected(Some(&by_command), "other", &manifest, &dir));

    let by_relative_command = SelectedPluginConfig {
        command: Some(vec!["bin/sidebar".into()]),
        cwd: Some(dir.clone()),
        ..Default::default()
    };
    assert!(plugin_is_selected(Some(&by_relative_command), "other", &manifest, &dir));

    let sibling_command = SelectedPluginConfig {
        command: Some(vec![dir.join("bin/other").display().to_string()]),
        ..Default::default()
    };
    assert!(!plugin_is_selected(Some(&sibling_command), "other", &manifest, &dir));

    let unrelated_command = SelectedPluginConfig {
        command: Some(vec!["/tmp/plugin".into(), "different".into()]),
        ..Default::default()
    };
    assert!(!plugin_is_selected(Some(&unrelated_command), id, &manifest, &dir));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn plugin_build_timeout_is_finite_and_positive() {
    assert!(PLUGIN_BUILD_TIMEOUT.as_nanos() > 0);
}

#[cfg(unix)]
#[test]
fn plugin_build_command_terminates_after_timeout() {
    let mut command = Command::new("sh");
    command.args(["-c", "while :; do :; done"]);
    let started = Instant::now();
    let error = run_plugin_build_command(&mut command, Duration::from_millis(20))
        .expect_err("a busy build must time out");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(error.to_string().contains("timed out"));
}
