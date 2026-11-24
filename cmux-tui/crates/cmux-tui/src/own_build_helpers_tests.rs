use super::*;

#[test]
fn own_build_folders_differ_per_executable_and_stay_put_per_build() {
    let a = Path::new("/opt/a/cmux-tui");
    let b = Path::new("/opt/b/cmux-tui");
    let (Some(dir_a), Some(dir_b)) = (build_dir(a), build_dir(b)) else {
        return; // No HOME in this environment: no data home to compare.
    };
    assert_ne!(dir_a, dir_b);
    assert_eq!(build_dir(a), Some(dir_a.clone()));
    assert_eq!(dir_a.file_name().unwrap().len(), 16);
    assert_eq!(dir_a.parent().unwrap().file_name().unwrap(), "builds");
}

/// Only existing cmux-tui shims in the shared folder are rewritten, to
/// name no build; a person's own file is kept and nothing is created.
/// What the rewritten shims run: tests/own_build_helpers.rs.
#[test]
fn shared_shims_are_rewritten_only_where_an_older_build_left_them() {
    use std::os::unix::fs::PermissionsExt as _;
    let root = tempfile::tempdir().unwrap();
    let write = |path: &Path, text: &str| {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    };
    let shared = root.path().join("data/cmux-tui/shims");
    write(
        &shared.join("claude"),
        "#!/bin/sh\n# cmux-tui-claude-shim\nif [ -x '/old build/cmux-tui' ]; then\n  exec '/old build/cmux-tui' agent claude-wrapper \"$@\"\nfi\nexec claude \"$@\"\n",
    );
    write(
        &shared.join("codex"),
        "#!/bin/sh\n# cmux-tui-codex-shim\nexec /gone/cmux agent codex-wrapper \"$@\"\n",
    );
    refresh_shared_shims_in(&shared);
    let first: Vec<String> = ["claude", "codex"]
        .iter()
        .map(|name| fs::read_to_string(shared.join(name)).unwrap())
        .collect();
    for script in &first {
        assert!(script.contains("CMUX_BUNDLED_CLI_PATH"), "{script}");
    }
    // The older shim's own target stays as a checked fallback, and a
    // second start reproduces the same bytes.
    assert!(first[0].contains("if [ -x '/old build/cmux-tui' ]"), "{}", first[0]);
    refresh_shared_shims_in(&shared);
    for (name, script) in ["claude", "codex"].iter().zip(&first) {
        assert_eq!(&fs::read_to_string(shared.join(name)).unwrap(), script, "{name}");
    }
    // Rewritten only when the bytes differ; a person's own file and a
    // missing one are left alone.
    let other = root.path().join("other");
    write(&other.join("claude"), "#!/bin/sh\nexec mine\n");
    refresh_shared_shims_in(&other);
    assert_eq!(fs::read_to_string(other.join("claude")).unwrap(), "#!/bin/sh\nexec mine\n");
    assert!(!other.join("codex").exists());
}

/// The build's helpers (its hook launcher, `claude` and `codex` shims and
/// Claude plugin) are written before the owner binds its socket, and a
/// start rewrites any that differ, so they are written without durable
/// syncs: on macOS each is a full fsync of the drive, and one of them
/// took 2.2 s of a 2.3 s first start on a fleet Mac (2026-11-09).
#[test]
fn own_build_helpers_are_written_without_durable_syncs() {
    let root = tempfile::tempdir().unwrap();
    let build = root.path().join("builds/0123456789abcdef");
    let executable = root.path().join("cmux-tui");
    fs::write(&executable, b"").unwrap();
    let before = agent_hook_install::durable_syncs_on_this_thread();
    let helper = hook_launcher(&build, &executable).unwrap();
    crate::claude_plugin::install(
        &build.join(crate::claude_plugin::PLUGIN_FOLDER),
        &executable,
        &helper,
    )
    .unwrap();
    let shims = build.join("shims");
    crate::claude_wrapper::install_shim(&shims, &executable).unwrap();
    crate::codex_wrapper::install_shim(&shims, &executable).unwrap();
    let synced = agent_hook_install::durable_syncs_on_this_thread() - before;
    assert_eq!(synced, 0, "the build's helpers made {synced} durable syncs");
    for path in [helper, shims.join("claude"), shims.join("codex")] {
        assert!(agent_hook_install::is_executable_file(&path), "{}", path.display());
    }
    assert!(
        build
            .join(crate::claude_plugin::PLUGIN_FOLDER)
            .join(".claude-plugin/plugin.json")
            .is_file()
    );
}

#[test]
fn own_build_launch_keeps_a_persons_hook_but_not_the_shared_one() {
    let dir = tempfile::tempdir().unwrap();
    let mine = dir.path().join("my-hook");
    agent_hook_install::atomic_write(&mine, b"#!/bin/sh\n", Some(0o755)).unwrap();
    let exe = dir.path().join("cmux-tui");
    agent_hook_install::atomic_write(&exe, b"", Some(0o755)).unwrap();
    let sibling = dir.path().join(HOOK_HELPER);
    agent_hook_install::atomic_write(&sibling, b"#!/bin/sh\n", Some(0o755)).unwrap();
    assert_eq!(launch_hook_helper(&exe, Some(mine.clone().into())), Some(mine));
    // A relative or missing value is not a helper: this build's own runs.
    assert_eq!(launch_hook_helper(&exe, Some("my-hook".into())), Some(sibling.clone()));
    assert_eq!(launch_hook_helper(&exe, None), Some(sibling.clone()));
    if let Some(shared) = agent_hook_install::runtime_helper_path()
        && agent_hook_install::is_executable_file(&shared)
    {
        assert_eq!(launch_hook_helper(&exe, Some(shared.into())), Some(sibling));
    }
}
