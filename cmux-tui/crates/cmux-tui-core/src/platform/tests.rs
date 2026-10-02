use super::*;

#[cfg(windows)]
use std::ffi::OsString;
#[cfg(windows)]
use std::sync::Mutex;

#[cfg(windows)]
static RUNTIME_ENV_LOCK: Mutex<()> = Mutex::new(());

#[cfg(target_os = "macos")]
#[test]
fn explicit_xdg_ghostty_config_does_not_add_application_support_candidates() {
    let xdg = PathBuf::from("/tmp/cmux-test-xdg");
    let home = PathBuf::from("/tmp/cmux-test-home");
    let paths = ghostty_config_paths_from(Some(xdg.clone()), Some(home));

    assert_eq!(paths, vec![xdg.join("ghostty/config"), xdg.join("ghostty/config.ghostty")]);
}

#[cfg(unix)]
#[test]
fn private_socket_peer_uid_must_match_the_expected_user() {
    let (client, server) = std::os::unix::net::UnixStream::pair().unwrap();
    let owner = effective_uid();

    assert_eq!(unix_peer_uid(&client).unwrap(), owner);
    assert_eq!(unix_peer_uid(&server).unwrap(), owner);
    require_unix_peer_uid(&client, owner).unwrap();
    let error = require_unix_peer_uid(&client, owner.wrapping_add(1))
        .expect_err("a peer running as another user must be refused");
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
}

#[cfg(unix)]
#[test]
fn private_socket_listener_admits_only_the_owner_and_root() {
    assert!(transport::peer_may_connect(501, 501));
    assert!(transport::peer_may_connect(0, 501));
    assert!(transport::peer_may_connect(0, 0));
    assert!(!transport::peer_may_connect(502, 501));
    assert!(!transport::peer_may_connect(501, 0));
}

#[test]
fn default_terminal_cwd_prefers_a_live_launch_directory() {
    let dir = std::env::temp_dir().canonicalize().unwrap();
    assert_eq!(default_terminal_cwd_from(Some(&dir)), Some(dir.to_string_lossy().into_owned()));
}

#[test]
fn default_terminal_cwd_rejects_roots_and_vanished_directories() {
    let root = if cfg!(windows) { PathBuf::from("C:\\") } else { PathBuf::from("/") };
    let home = home_dir().map(|path| path.to_string_lossy().into_owned());
    assert_eq!(default_terminal_cwd_from(Some(&root)), home);
    let gone = std::env::temp_dir().join(format!("cmux-cwd-gone-{}", std::process::id()));
    assert_eq!(default_terminal_cwd_from(Some(&gone)), home);
    assert_eq!(default_terminal_cwd_from(None), home);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn foreground_cwd_lookup_reads_a_live_child_directory_and_fails_closed() {
    let target = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("cmux-foreground-cwd-{}", std::process::id()));
    std::fs::create_dir_all(&target).unwrap();
    let mut child = std::process::Command::new("/bin/sleep")
        .arg("30")
        .current_dir(&target)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let observed = process_cwd(child.id());
    child.kill().unwrap();
    child.wait().unwrap();
    assert_eq!(
        observed.map(PathBuf::from),
        Some(target.clone()),
        "the live child working directory was not observed"
    );
    assert_eq!(process_cwd(u32::MAX), None, "an impossible PID did not fail closed");
    std::fs::remove_dir(&target).unwrap();
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn foreground_cwd_requires_a_controlling_terminal() {
    // The child starts its own session, so it deterministically has no
    // controlling terminal and the foreground lookup must fail closed
    // instead of inventing a directory.
    use std::os::unix::process::CommandExt as _;
    let mut command = std::process::Command::new("/bin/sleep");
    command
        .arg("30")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // SAFETY: setsid is async-signal-safe and the closure does not
    // allocate between fork and exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn().unwrap();
    let observed = foreground_process_group(child.id());
    child.kill().unwrap();
    child.wait().unwrap();
    assert_eq!(observed, None);
    assert_eq!(foreground_cwd(u32::MAX), None);
}

fn position(candidates: &[GhosttyInstallation], expected: impl AsRef<Path>) -> usize {
    let expected = expected.as_ref();
    candidates
        .iter()
        .position(|candidate| candidate.binary == expected)
        .unwrap_or_else(|| panic!("missing Ghostty candidate {}", expected.display()))
}

#[test]
fn packaged_and_pinned_ghostty_precede_path_and_system_installs() {
    let browser = Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui");
    let home = Path::new("/Users/tester");
    let path_binary = PathBuf::from("/opt/homebrew/bin/ghostty");
    let candidates = ghostty_installation_candidates(
        None,
        None,
        Some(browser),
        Some(home),
        Some(path_binary.clone()),
    );

    let packaged = Path::new("/tmp/cmux-browser.app/Contents/Resources/bin/ghostty");
    let pinned = home
        .join("Applications")
        .join("Ghostty-cmux-pinned.app")
        .join("Contents")
        .join("MacOS")
        .join("ghostty");
    let system = Path::new("/Applications/Ghostty.app/Contents/MacOS/ghostty");
    assert!(position(&candidates, packaged) < position(&candidates, &pinned));
    assert!(position(&candidates, &pinned) < position(&candidates, &path_binary));
    assert!(position(&candidates, &path_binary) < position(&candidates, system));

    let packaged_installation = &candidates[position(&candidates, packaged)];
    assert_eq!(
        packaged_installation.resources_dir.as_deref(),
        Some(Path::new("/tmp/cmux-browser.app/Contents/Resources/ghostty"))
    );
}

#[cfg(windows)]
#[test]
fn terminal_pwd_rejects_unc_verbatim_and_device_paths() {
    for path in [
        r"\\server\share\src",
        "//server/share/src",
        r"\\?\UNC\server\share\src",
        r"\\.\PhysicalDrive0",
        r"\\?\C:\src",
        r"\??\C:\src",
        r"C:drive-relative",
        r"\rooted-without-drive",
        "file://server/share/src",
        "file:////server/share/src",
    ] {
        assert_eq!(terminal_pwd_to_local_path(path), None, "{path}");
    }
    assert_eq!(terminal_pwd_to_local_path(r"C:\Users\alice\src"), None);
    assert_eq!(terminal_pwd_to_local_path("file:///C:/Users/alice/src"), None);
}

#[cfg(windows)]
#[test]
fn windows_sync_directory_accepts_existing_directory() {
    let root = std::env::temp_dir().join(format!(
        "cmux-sync-directory-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();

    sync_directory(&root).unwrap();

    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_parent_paths_preserve_component_semantics() {
    let path = PathBuf::from(format!(r"C:\{}\..\state", "segment".repeat(42)));
    let normalized = normalize_filesystem_path(path.clone());
    let text = normalized.to_string_lossy();
    assert_eq!(normalized, path, "{text}");
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_relative_failures_preserve_original_spelling() {
    let parent = vec!["segment"; 36].join(r"\");
    for path in
        [PathBuf::from(format!(r"{parent}\..\state")), PathBuf::from(format!(r"{parent}\state."))]
    {
        let normalized = normalize_filesystem_path(path.clone());
        assert_eq!(normalized, path, "{}", normalized.display());
    }
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_root_relative_paths_preserve_current_drive_semantics() {
    let path = PathBuf::from(format!(r"\{}\state", "segment".repeat(42)));
    let normalized = normalize_filesystem_path(path.clone());
    assert_eq!(normalized, path, "{}", normalized.display());
}

#[test]
fn normalize_windows_paths_preserves_drive_relative_and_rooted_controls() {
    let drive_relative = PathBuf::from(r"C:state");
    assert_eq!(normalize_filesystem_path(drive_relative.clone()), drive_relative);

    let relative = PathBuf::from("state");
    assert_eq!(normalize_filesystem_path(relative.clone()), relative);

    for rooted in [PathBuf::from(r"C:\state"), PathBuf::from(r"\\server\share\state")] {
        assert_eq!(normalize_filesystem_path(rooted.clone()), rooted);
    }
}

#[test]
fn windows_verbatim_component_guard_rejects_win32_semantic_changes() {
    for component in [
        "state.",
        "state ",
        "CON",
        "nul.txt",
        "Com9.log",
        "LPT¹",
        "CONIN$",
        "CONOUT$",
        "conin$.log",
        "ConOut$.log",
    ] {
        let wide = component.encode_utf16().collect::<Vec<_>>();
        assert!(!windows_component_is_verbatim_safe(&wide), "{component}");
    }
}

#[test]
fn windows_verbatim_component_guard_accepts_ordinary_names() {
    for component in ["state", "state data.v1", ".state", "COM10", "日本語"] {
        let wide = component.encode_utf16().collect::<Vec<_>>();
        assert!(windows_component_is_verbatim_safe(&wide), "{component}");
    }
}

#[test]
fn windows_verbatim_path_guard_requires_drive_or_unc_root() {
    for path in [r"C:\state", r"\\server\share\state"] {
        let wide = path.encode_utf16().collect::<Vec<_>>();
        assert!(windows_absolute_path_is_verbatim_safe(&wide), "{path}");
    }
    for path in [r"C:state", r"\state", "state"] {
        let wide = path.encode_utf16().collect::<Vec<_>>();
        assert!(!windows_absolute_path_is_verbatim_safe(&wide), "{path}");
    }
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_trailing_dot_or_space_paths_preserve_component_semantics() {
    let parent = vec!["segment"; 36].join(r"\");
    for child in ["state.", "state "] {
        let path = PathBuf::from(format!(r"C:\{parent}\{child}"));
        let normalized = normalize_filesystem_path(path.clone());
        assert_eq!(normalized, path, "{}", normalized.display());
    }
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_reserved_device_paths_preserve_component_semantics() {
    let parent = vec!["segment"; 36].join(r"\");
    for child in ["CON", "nul.txt", "Com9.log", "LPT¹"] {
        let path = PathBuf::from(format!(r"C:\{parent}\{child}"));
        let normalized = normalize_filesystem_path(path.clone());
        assert_eq!(normalized, path, "{}", normalized.display());
    }
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_valid_components_use_the_verbatim_namespace() {
    let parent = vec!["segment"; 36].join(r"\");
    let path = PathBuf::from(format!(r"C:\{parent}\state data.v1"));
    let normalized = normalize_filesystem_path(path);
    let text = normalized.to_string_lossy();
    assert!(text.starts_with(r"\\?\C:\"), "{text}");
    assert!(text.ends_with(r"\state data.v1"), "{text}");
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_file_with_trailing_separator_keeps_directory_requirement() {
    let root = std::env::temp_dir().join(format!(
        "cmux-path-separator-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let deep_parent = root.join(vec!["segment"; 30].join(r"\"));
    let normalized_parent = normalize_filesystem_path(deep_parent.clone());
    std::fs::create_dir_all(&normalized_parent).unwrap();

    let file = deep_parent.join("state.bin");
    let normalized_file = normalize_filesystem_path(file.clone());
    std::fs::write(&normalized_file, b"state").unwrap();

    let with_separator = PathBuf::from(format!(r"{}\", file.display()));
    let normalized_with_separator = normalize_filesystem_path(with_separator);
    let text = normalized_with_separator.to_string_lossy().into_owned();
    let metadata = std::fs::metadata(&normalized_with_separator);

    let _ = std::fs::remove_file(normalized_file);
    let _ = std::fs::remove_dir_all(normalize_filesystem_path(root));

    assert!(text.ends_with(r"\"), "{text}");
    assert!(metadata.is_err(), "a trailing separator opened a regular file: {text}");
}

#[cfg(windows)]
#[test]
fn normalize_long_windows_unc_paths_preserves_the_share_boundary() {
    let path = PathBuf::from(format!(r"\\server\share\{}", "segment".repeat(42)));
    let normalized = normalize_filesystem_path(path);
    let text = normalized.to_string_lossy();
    assert!(text.starts_with(r"\\?\UNC\server\share\"), "{text}");
}

#[test]
fn windows_path_classifier_accepts_only_rooted_local_drives() {
    for path in [r"C:\Users\alice\src", "z:/src/cmux", r"D:\"] {
        assert!(windows_path_is_rooted_local_drive(path), "{path}");
    }
    for path in [
        r"\\server\share\src",
        "//server/share/src",
        r"\\?\UNC\server\share\src",
        r"\\.\PhysicalDrive0",
        r"\\?\C:\src",
        r"\??\C:\src",
        r"C:drive-relative",
        r"\rooted-without-drive",
        "/unix/absolute",
        "",
    ] {
        assert!(!windows_path_is_rooted_local_drive(path), "{path}");
    }
}

#[cfg(windows)]
#[test]
fn invalid_runtime_dir_uses_the_runtime_temp_precedence() {
    let _lock = RUNTIME_ENV_LOCK.lock().unwrap();
    let old_temp = std::env::var_os("TEMP");
    let old_tmp = std::env::var_os("TMP");
    let old_userprofile = std::env::var_os("USERPROFILE");
    let temp = OsString::from(r"C:\cmux-preferred-temp");
    let tmp = OsString::from(r"D:\cmux-secondary-temp");
    let userprofile = OsString::from(r"E:\cmux-user-profile");

    // SAFETY: this test serializes its process-global environment changes.
    unsafe {
        std::env::set_var("TEMP", &temp);
        std::env::set_var("TMP", &tmp);
        std::env::set_var("USERPROFILE", &userprofile);
    }
    let path = invalid_runtime_dir();
    // SAFETY: this test serializes its process-global environment changes.
    unsafe {
        match old_temp {
            Some(value) => std::env::set_var("TEMP", value),
            None => std::env::remove_var("TEMP"),
        }
        match old_tmp {
            Some(value) => std::env::set_var("TMP", value),
            None => std::env::remove_var("TMP"),
        }
        match old_userprofile {
            Some(value) => std::env::set_var("USERPROFILE", value),
            None => std::env::remove_var("USERPROFILE"),
        }
    }

    assert_eq!(path.parent(), Some(Path::new(r"D:\cmux-secondary-temp")));
}

#[cfg(windows)]
#[test]
fn invalid_runtime_dir_falls_back_to_tmp_when_temp_is_unset() {
    let _lock = RUNTIME_ENV_LOCK.lock().unwrap();
    let old_temp = std::env::var_os("TEMP");
    let old_tmp = std::env::var_os("TMP");
    let tmp = OsString::from(r"D:\cmux-secondary-temp");

    // SAFETY: this test serializes its process-global environment changes.
    unsafe {
        std::env::remove_var("TEMP");
        std::env::set_var("TMP", &tmp);
    }
    let path = invalid_runtime_dir();
    // SAFETY: this test serializes its process-global environment changes.
    unsafe {
        match old_temp {
            Some(value) => std::env::set_var("TEMP", value),
            None => std::env::remove_var("TEMP"),
        }
        match old_tmp {
            Some(value) => std::env::set_var("TMP", value),
            None => std::env::remove_var("TMP"),
        }
    }

    assert_eq!(path.parent(), Some(Path::new(r"D:\cmux-secondary-temp")));
}

#[cfg(windows)]
#[test]
fn invalid_runtime_dir_falls_back_to_userprofile_when_temp_is_unset() {
    let _lock = RUNTIME_ENV_LOCK.lock().unwrap();
    let old_temp = std::env::var_os("TEMP");
    let old_tmp = std::env::var_os("TMP");
    let old_userprofile = std::env::var_os("USERPROFILE");
    let userprofile = OsString::from(r"E:\cmux-user-profile");

    // SAFETY: this test serializes its process-global environment changes.
    unsafe {
        std::env::remove_var("TEMP");
        std::env::remove_var("TMP");
        std::env::set_var("USERPROFILE", &userprofile);
    }
    let path = invalid_runtime_dir();
    // SAFETY: this test serializes its process-global environment changes.
    unsafe {
        match old_temp {
            Some(value) => std::env::set_var("TEMP", value),
            None => std::env::remove_var("TEMP"),
        }
        match old_tmp {
            Some(value) => std::env::set_var("TMP", value),
            None => std::env::remove_var("TMP"),
        }
        match old_userprofile {
            Some(value) => std::env::set_var("USERPROFILE", value),
            None => std::env::remove_var("USERPROFILE"),
        }
    }

    assert_eq!(path.parent(), Some(Path::new(r"E:\cmux-user-profile")));
}

#[test]
fn explicit_ghostty_installation_remains_authoritative() {
    let explicit = PathBuf::from("/custom/pinned/bin/ghostty");
    let resources = PathBuf::from("/custom/pinned/share/ghostty");
    let candidates = ghostty_installation_candidates(
        Some(explicit.clone()),
        Some(resources.clone()),
        Some(Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui")),
        Some(Path::new("/Users/tester")),
        Some(PathBuf::from("/usr/local/bin/ghostty")),
    );

    assert_eq!(candidates[0].binary, explicit);
    assert_eq!(candidates[0].resources_dir, Some(resources));
}

#[test]
fn inherited_resource_hint_does_not_outrank_pinned_installation() {
    let home = Path::new("/Users/tester");
    let inherited_resources = PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty");
    let candidates = ghostty_installation_candidates(
        None,
        Some(inherited_resources),
        Some(Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui")),
        Some(home),
        Some(PathBuf::from("/usr/local/bin/ghostty")),
    );
    let pinned = home
        .join("Applications")
        .join("Ghostty-cmux-pinned.app")
        .join("Contents")
        .join("MacOS")
        .join("ghostty");
    let inherited_helper = Path::new("/Applications/cmux.app/Contents/Resources/bin/ghostty");

    assert!(position(&candidates, &pinned) < position(&candidates, inherited_helper));
}

#[test]
fn packaged_theme_resources_precede_legacy_ghostty_resources() {
    let browser = Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui");
    let home = Path::new("/Users/tester");
    let path_binary = PathBuf::from("/opt/homebrew/bin/ghostty");
    let inherited = PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty");
    let candidates = ghostty_installation_candidates(
        None,
        Some(inherited.clone()),
        Some(browser),
        Some(home),
        Some(path_binary),
    )
    .into_iter()
    .filter_map(|candidate| candidate.resources_dir)
    .collect::<Vec<_>>();

    let packaged = Path::new("/tmp/cmux-browser.app/Contents/Resources/ghostty");
    let pinned =
        Path::new("/Users/tester/Applications/Ghostty-cmux-pinned.app/Contents/Resources/ghostty");
    let global_pinned =
        Path::new("/Applications/Ghostty-cmux-pinned.app/Contents/Resources/ghostty");
    let system = Path::new("/Applications/Ghostty.app/Contents/Resources/ghostty");
    let position = |expected: &Path| {
        candidates
            .iter()
            .position(|candidate| candidate == expected)
            .unwrap_or_else(|| panic!("missing Ghostty resources {}", expected.display()))
    };
    assert!(position(packaged) < position(pinned));
    assert!(position(pinned) < position(&inherited));
    assert!(position(global_pinned) < position(&inherited));
    assert!(position(pinned) < position(system));
}

#[test]
fn derives_resource_paths_for_app_bundle_and_packaged_helper() {
    assert_eq!(
        ghostty_resources_for_binary(Path::new("/Applications/Ghostty.app/Contents/MacOS/ghostty")),
        Some(PathBuf::from("/Applications/Ghostty.app/Contents/Resources/ghostty"))
    );
    assert_eq!(
        ghostty_resources_for_binary(Path::new(
            "/Applications/cmux-browser.app/Contents/Resources/bin/ghostty"
        )),
        Some(PathBuf::from("/Applications/cmux-browser.app/Contents/Resources/ghostty"))
    );
}

#[cfg(unix)]
#[test]
fn terminal_pwd_converts_local_osc7_urls_without_trusting_remote_hosts() {
    let mut hostname = [0_u8; 256];
    assert_eq!(unsafe { libc::gethostname(hostname.as_mut_ptr().cast(), hostname.len()) }, 0);
    let hostname_end = hostname.iter().position(|byte| *byte == 0).unwrap_or(hostname.len());
    let hostname = std::str::from_utf8(&hostname[..hostname_end]).unwrap();

    assert_eq!(
        terminal_pwd_to_local_path(&format!("file://{hostname}/tmp/a%20b")),
        Some(PathBuf::from("/tmp/a b"))
    );
    assert_eq!(
        terminal_pwd_to_local_path("file://localhost/tmp/local"),
        Some(PathBuf::from("/tmp/local"))
    );
    assert_eq!(terminal_pwd_to_local_path("file:///tmp/hostless"), None);
    // Hostless absolute paths are ambiguous for hosted terminals. A
    // remote shell can emit one and otherwise redirect a local spawn.
    assert_eq!(terminal_pwd_to_local_path("/tmp/plain"), None);
    assert_eq!(terminal_pwd_to_local_path("file://remote.invalid/tmp/nope"), None);
}

#[cfg(unix)]
#[test]
fn terminal_pwd_accepts_ghostty_kitty_shell_cwd_reports() {
    let hostname = local_hostname().unwrap();
    assert_eq!(
        terminal_pwd_to_local_path(&format!("kitty-shell-cwd://{hostname}/tmp/a b")),
        Some(PathBuf::from("/tmp/a b"))
    );
    assert_eq!(
        terminal_pwd_to_local_path("kitty-shell-cwd://localhost/tmp/local"),
        Some(PathBuf::from("/tmp/local"))
    );
    assert_eq!(terminal_pwd_to_local_path("kitty-shell-cwd:///tmp/hostless"), None);
    assert_eq!(terminal_pwd_to_local_path("kitty-shell-cwd://remote.invalid/tmp"), None);
    assert_eq!(
        local_terminal_pwd_to_local_path("kitty-shell-cwd:///tmp/hostless"),
        Some(PathBuf::from("/tmp/hostless"))
    );
    assert_eq!(local_terminal_pwd_to_local_path("kitty-shell-cwd://remote.invalid/tmp"), None);
}

#[cfg(unix)]
#[test]
fn local_terminal_pwd_keeps_hostless_osc7_urls() {
    assert_eq!(
        local_terminal_pwd_to_local_path("file:///tmp/hostless"),
        Some(PathBuf::from("/tmp/hostless"))
    );
}

#[test]
fn spawn_cwd_preserves_trusted_relative_paths() {
    assert_eq!(spawn_cwd_to_local_path("subdir"), Some(PathBuf::from("subdir")));
    assert_eq!(spawn_cwd_to_local_path("build:debug"), Some(PathBuf::from("build:debug")));
    assert_eq!(
        spawn_cwd_to_local_path(r"C:\Users\alice\src"),
        Some(PathBuf::from(r"C:\Users\alice\src"))
    );
    assert_eq!(spawn_cwd_to_local_path("/tmp/foo://bar"), Some(PathBuf::from("/tmp/foo://bar")));
    assert_eq!(spawn_cwd_to_local_path("file:///tmp/hostless"), None);
    assert_eq!(
        snapshot_cwd_to_local_path(
            "cmux-tui:spawn-cwd:v1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef:subdir",
            Some("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
        ),
        Some(PathBuf::from("subdir"))
    );
}

#[test]
fn snapshot_cwd_rejects_forged_spawn_marker_from_osc7() {
    assert_eq!(
        snapshot_cwd_to_local_path("cmux-tui:spawn-cwd:/tmp/attacker-controlled", None),
        None
    );
    assert_eq!(
        snapshot_cwd_to_local_path(
            "cmux-tui:spawn-cwd:v1:bad-token:/tmp/attacker-controlled",
            Some("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
        ),
        None
    );
}

#[cfg(unix)]
#[test]
fn local_hostname_decoder_accepts_non_utf8_os_bytes() {
    assert_eq!(decode_local_hostname(b"host\xff"), Some("host�".to_string()));
    assert_eq!(decode_local_hostname(b""), None);
}
