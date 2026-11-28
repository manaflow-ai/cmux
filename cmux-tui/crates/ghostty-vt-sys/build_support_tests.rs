use super::*;

fn scratch_tree(name: &str, files: &[&str]) -> PathBuf {
    let root = std::env::temp_dir().join(format!("ghostty-vt-sys-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    for file in files {
        let path = root.join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"").unwrap();
    }
    root
}

#[test]
fn vt_source_missing_directory_names_the_submodule() {
    let missing = std::env::temp_dir().join("ghostty-vt-sys-does-not-exist");
    let error = resolve_vt_source(&missing).unwrap_err();
    assert!(error.contains("git submodule update --init ghostty-next"), "{error}");
}

#[test]
fn vt_source_empty_submodule_is_a_hard_error() {
    let root = scratch_tree("empty", &[]);
    let error = resolve_vt_source(&root).unwrap_err();
    assert!(error.contains("missing build.zig"), "{error}");
    assert!(error.contains("ghostty-next"), "{error}");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn vt_source_without_snapshot_header_is_rejected() {
    // The shape of the Mac app's `ghostty` fork: lib-vt without snapshot.h.
    let root = scratch_tree("fork", &["build.zig", "include/ghostty/vt.h"]);
    let error = resolve_vt_source(&root).unwrap_err();
    assert!(error.contains("include/ghostty/vt/snapshot.h"), "{error}");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn vt_source_zon_version_is_read_for_an_explicit_version_string() {
    let root = scratch_tree("zon", &[]);
    let zon = root.join("build.zig.zon");
    std::fs::write(&zon, ".{\n    .name = .ghostty,\n    .version = \"1.3.2-dev\",\n}\n").unwrap();
    assert_eq!(zon_version(&zon).as_deref(), Some("1.3.2-dev"));
    std::fs::write(&zon, ".{ .name = .ghostty }\n").unwrap();
    assert_eq!(zon_version(&zon), None);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn vt_source_complete_tree_resolves() {
    let root = scratch_tree("complete", &REQUIRED_VT_SOURCE_FILES);
    assert_eq!(resolve_vt_source(&root).unwrap(), root.canonicalize().unwrap());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn native_windows_gnu_keeps_the_explicit_gnu_abi() {
    assert_eq!(
        zig_target_arg("x86_64-pc-windows-gnu", "x86_64-pc-windows-gnu", "13.0").as_deref(),
        Some("-Dtarget=x86_64-windows-gnu")
    );
}

#[test]
fn native_linux_builds_keep_zigs_native_target() {
    assert_eq!(
        zig_target_arg("x86_64-unknown-linux-gnu", "x86_64-unknown-linux-gnu", "13.0"),
        None
    );
    assert_eq!(zig_cpu_arg("x86_64-unknown-linux-gnu", None), None);
}

// On a macOS build host Ghostty's build replaces the macOS target with its
// generic macOS target at Ghostty's minimum. Every build host names that
// minimum, so the objects do not depend on where they were built.
#[test]
fn macos_builds_name_ghosttys_minimum_on_every_host() {
    let cases = [
        ("aarch64-apple-darwin", "aarch64-apple-darwin", "-Dtarget=aarch64-macos.13.0"),
        ("x86_64-apple-darwin", "aarch64-apple-darwin", "-Dtarget=x86_64-macos.13.0"),
        ("aarch64-apple-darwin", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-macos.13.0"),
        ("x86_64-apple-darwin", "x86_64-apple-darwin", "-Dtarget=x86_64-macos.13.0"),
    ];
    for (target, host, expected) in cases {
        assert_eq!(
            zig_target_arg(target, host, "13.0").as_deref(),
            Some(expected),
            "{target} on {host}"
        );
    }
}

#[test]
fn ghostty_macos_min_reads_the_macos_arm_of_os_version_min() {
    let config = r#"
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },
        .ios => .{ .semver = .{
            .major = 14,
            .minor = 0,
            .patch = 0,
        } },
        else => null,
    };
}
"#;
    assert_eq!(ghostty_macos_min(config).as_deref(), Some("13.0"));
    assert_eq!(ghostty_macos_min("pub fn other() void {}\n"), None);
}

#[test]
fn macos_builds_use_a_baseline_cpu_unless_overridden() {
    assert_eq!(zig_cpu_arg("aarch64-apple-darwin", None).as_deref(), Some("-Dcpu=baseline"));
    assert_eq!(zig_cpu_arg("x86_64-apple-darwin", None).as_deref(), Some("-Dcpu=baseline"));
    assert_eq!(
        zig_cpu_arg("aarch64-apple-darwin", Some("apple_m1")).as_deref(),
        Some("-Dcpu=apple_m1")
    );
    assert_eq!(
        zig_cpu_arg("x86_64-unknown-linux-gnu", Some("baseline")).as_deref(),
        Some("-Dcpu=baseline")
    );
}

#[test]
fn cross_targets_keep_their_explicit_zig_abi() {
    let cases = [
        ("x86_64-pc-windows-gnu", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-windows-gnu"),
        ("x86_64-pc-windows-msvc", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-windows-msvc"),
        ("aarch64-pc-windows-msvc", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-windows-msvc"),
        ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-linux-gnu"),
        ("aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-linux-gnu"),
        ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-linux-musl"),
        ("aarch64-unknown-linux-musl", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-linux-musl"),
    ];

    for (target, host, expected) in cases {
        assert_eq!(zig_target_arg(target, host, "13.0").as_deref(), Some(expected), "{target}");
    }
}

/// CI pins zig with `scripts/install-zig-ci.sh`, which publishes `CMUX_ZIG`.
/// A runner whose PATH holds an older zig first (glaeda-5: Zig 0.16 under
/// `~/.local/lib`, ahead of the pinned 0.17) must still build with the pin.
#[test]
fn the_pinned_zig_wins_over_path() {
    let pinned = "/runner/_temp/zig-aarch64-macos-0.17.0/zig".to_string();
    assert_eq!(zig_program(None, Some(pinned.clone())), pinned);
    assert_eq!(zig_program(Some("/opt/zig".into()), Some(pinned.clone())), "/opt/zig");
    assert_eq!(zig_program(Some(String::new()), Some(pinned.clone())), pinned);
    assert_eq!(zig_program(None, Some(String::new())), "zig");
    assert_eq!(zig_program(None, None), "zig");
}

#[test]
fn the_minimum_zig_comes_from_the_manifest() {
    let root = scratch_tree("zon-minimum", &[]);
    let zon = root.join("build.zig.zon");
    std::fs::write(
        &zon,
        ".{\n    .version = \"1.3.0-dev\",\n    .minimum_zig_version = \"0.17.0\",\n}\n",
    )
    .unwrap();
    assert_eq!(zon_minimum_zig(&zon).as_deref(), Some("0.17.0"));
    std::fs::write(&zon, ".{ .version = \"1.3.0\" }\n").unwrap();
    assert_eq!(zon_minimum_zig(&zon), None);
}

#[test]
fn a_zig_serves_its_own_series_only() {
    assert!(zig_compatible("0.17.0", "0.17.0"));
    assert!(zig_compatible("0.17.2", "0.17.0"));
    assert!(!zig_compatible("0.16.0", "0.17.0"));
    assert!(!zig_compatible("0.18.0", "0.17.0"));
    assert!(!zig_compatible("0.17.0-dev.1+abc", "0.17.0"));
}

/// The Linux pool's baked recipe put /opt/zig-0.16.0 first on PATH after
/// ghostty-next moved to Zig 0.17 (hq#8178); its image held /opt/zig-0.17.0.
#[test]
fn the_trees_pin_wins_over_a_recipe_that_hands_over_an_older_zig() {
    let versions = |path: &str| match path {
        "zig" | "/opt/zig-0.16.0/zig" => Some("0.16.0".to_string()),
        "/opt/zig-0.17.0/zig" => Some("0.17.0".to_string()),
        _ => None,
    };
    let mut candidates = vec!["zig".to_string()];
    candidates.extend(installed_zig_paths("0.17.0"));
    let (zig, why) = select_zig(&candidates, Some("0.17.0"), versions);
    assert_eq!(zig, "/opt/zig-0.17.0/zig");
    assert!(why.unwrap().contains("0.17.0"));
    // an explicit ZIG of the wrong series loses too; one of the right series wins with no warning
    let explicit = vec!["/opt/zig-0.16.0/zig".to_string(), "/opt/zig-0.17.0/zig".to_string()];
    assert_eq!(select_zig(&explicit, Some("0.17.0"), versions).0, "/opt/zig-0.17.0/zig");
    assert_eq!(
        select_zig(&explicit[1..], Some("0.17.0"), versions),
        ("/opt/zig-0.17.0/zig".to_string(), None)
    );
    // nothing serves the pin, or there is no pin: the first, as before
    assert_eq!(select_zig(&candidates[..1], Some("0.17.0"), versions), ("zig".to_string(), None));
    assert_eq!(select_zig(&candidates, None, versions), ("zig".to_string(), None));
}

/// cmux10s keeps a Zig 0.16 in ~/.cargo/bin, and in the Mac legs it came before setup-zig's
/// 0.17 on PATH (macos-cross-parity run 45000510727, after 7e85a5ac): the first `zig` on PATH
/// was the only PATH candidate, so the build failed on Ghostty's version check although the
/// pinned Zig was on PATH too.
#[test]
fn a_pinned_zig_later_on_path_wins_over_an_older_one_first_on_path() {
    let root = scratch_tree("zig-path", &["stale/zig", "tool/zig", "empty/.keep"]);
    let (stale, tool) = (root.join("stale/zig"), root.join("tool/zig"));
    let path =
        std::env::join_paths([root.join("empty"), root.join("stale"), root.join("tool")]).unwrap();
    let (stale_s, tool_s) = (stale.display().to_string(), tool.display().to_string());
    let versions = |zig: &str| {
        if zig == "zig" || zig == stale_s {
            Some("0.16.0".to_string())
        } else if zig == tool_s {
            Some("0.17.0".to_string())
        } else {
            None
        }
    };
    let candidates = zig_candidates("zig".to_string(), Some(path.as_os_str()), Some("0.17.0"));
    let (zig, why) = select_zig(&candidates, Some("0.17.0"), versions);
    assert_eq!(zig, tool_s);
    assert!(why.unwrap().contains("0.17.0"));
    // an explicit ZIG still comes first, and no PATH means the old list
    let explicit = zig_candidates("/x/zig".to_string(), Some(path.as_os_str()), None);
    assert_eq!(explicit.first().map(String::as_str), Some("/x/zig"));
    let mut no_path = vec!["zig".to_string(), "zig".to_string()];
    no_path.extend(installed_zig_paths("0.17.0"));
    assert_eq!(zig_candidates("zig".to_string(), None, Some("0.17.0")), no_path);
    let _ = std::fs::remove_dir_all(&root);
}

/// A dev Mac with Homebrew's Zig 0.16 on PATH and install-zig-ci.sh's 0.17 in
/// ~/.local/zig-ci failed in `zig build` (ghostty-next pins 0.17): the build never
/// looked there. It does now, and the pinned copy wins.
#[test]
fn install_zig_ci_copies_are_candidates_and_win_over_an_older_path_zig() {
    let home = std::ffi::OsStr::new("/Users/x");
    assert_eq!(
        local_zig_paths("0.17.0", Some(home), "aarch64", "macos"),
        vec![
            "/opt/zig-0.17.0/zig".to_string(),
            "/Users/x/.local/zig-ci/zig-aarch64-macos-0.17.0/zig".to_string(),
            "/tmp/cmux-zig-ci/zig-aarch64-macos-0.17.0/zig".to_string(),
        ]
    );
    assert_eq!(
        local_zig_paths("0.17.0", None, "x86_64", "linux"),
        vec![
            "/opt/zig-0.17.0/zig".to_string(),
            "/tmp/cmux-zig-ci/zig-x86_64-linux-0.17.0/zig".to_string()
        ]
    );
    let local = "/Users/x/.local/zig-ci/zig-aarch64-macos-0.17.0/zig";
    let versions = |zig: &str| match zig {
        "zig" | "/opt/homebrew/bin/zig" => Some("0.16.0".to_string()),
        z if z == local => Some("0.17.0".to_string()),
        _ => None,
    };
    let mut candidates = vec!["zig".to_string(), "/opt/homebrew/bin/zig".to_string()];
    candidates.extend(local_zig_paths("0.17.0", Some(home), "aarch64", "macos"));
    assert_eq!(select_zig(&candidates, Some("0.17.0"), versions).0, local);
}

#[test]
fn no_pinned_zig_says_what_was_tried_and_how_to_install_it() {
    let tried = vec![
        ("zig".to_string(), Some("0.16.0".to_string())),
        ("zig".to_string(), Some("0.16.0".to_string())),
        ("".to_string(), None),
        ("/opt/zig-0.17.0/zig".to_string(), None),
    ];
    let message = pin_unmet_message("0.17.0", &tried);
    assert!(message.contains("pins Zig 0.17.0"), "{message}");
    assert!(message.contains("\n  zig: 0.16.0"), "{message}");
    assert_eq!(message.matches("zig: 0.16.0").count(), 1, "each zig once: {message}");
    assert!(message.contains("/opt/zig-0.17.0/zig: not found"), "{message}");
    assert!(message.contains("scripts/install-zig-ci.sh"), "{message}");
    assert!(message.contains("ZIG"), "{message}");
}

#[test]
fn mirrored_packages_reads_the_tagged_lines() {
    let lock = "# comment\n\
                    mirror https://github.com/manaflow-ai/ghostty-next/releases/download/zig-packages/\n\
                    aro-0.0.0-A 0123 ghostty-next,vt git+https://codeberg.org/ziglang/arocc#d0c8 -\n\
                    gobject-0.3.2-B 4567 ghostty-next https://deps.example/gobject.tar.zst -\n\
                    translate_c-2.0.0-C 89ab vt https://deps.example/tc.tar.gz aro-0.0.0-A\n\
                    malformed line\n";
    let vt = mirrored_packages(lock, "vt");
    assert_eq!(
        vt,
        vec![
            MirroredPackage {
                hash: "aro-0.0.0-A".into(),
                url: "https://github.com/manaflow-ai/ghostty-next/releases/download/zig-packages/aro-0.0.0-A.tar.gz".into(),
            },
            MirroredPackage {
                hash: "translate_c-2.0.0-C".into(),
                url: "https://github.com/manaflow-ai/ghostty-next/releases/download/zig-packages/translate_c-2.0.0-C.tar.gz".into(),
            },
        ]
    );
    assert_eq!(mirrored_packages(lock, "ghostty-next").len(), 2);
    // a tag is a whole word of the list, and no mirror line means no packages
    assert!(mirrored_packages(lock, "ghostty").is_empty());
    assert!(mirrored_packages("aro-0.0.0-A 0123 vt u -\n", "vt").is_empty());
}

#[test]
fn the_checked_in_lock_mirrors_on_our_host() {
    let lock =
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(ZIG_PACKAGE_LOCK))
            .unwrap();
    let vt = mirrored_packages(&lock, "vt");
    assert!(vt.iter().any(|p| p.hash.starts_with("aro-")), "{vt:?}");
    assert!(vt.iter().all(|p| p.url.starts_with("https://github.com/manaflow-ai/")), "{vt:?}");
}

#[test]
fn mirror_only_is_on_in_ci_unless_turned_off() {
    assert!(mirror_only(None, Some("true")));
    assert!(!mirror_only(None, None));
    assert!(!mirror_only(None, Some("")));
    assert!(!mirror_only(Some("0"), Some("true")));
    assert!(mirror_only(Some("1"), None));
    assert!(mirror_only(Some(""), Some("true")));
}

#[test]
fn mirror_only_proxy_refuses_every_scheme_in_both_cases() {
    // Zig's HTTP client reads lower- and upper-case http, https and all proxies.
    for scheme in ["http_proxy", "https_proxy", "all_proxy"] {
        assert!(PROXY_VARS.contains(&scheme));
        assert!(PROXY_VARS.contains(&scheme.to_uppercase().as_str()));
    }
    assert_eq!(NO_ROUTE_PROXY, "http://127.0.0.1:9");
    assert_eq!(NO_PROXY_VARS, ["NO_PROXY", "no_proxy"]);
}

#[test]
fn zig_env_global_cache_reads_zon_and_json() {
    let zon = ".{\n    .zig_exe = \"/opt/zig/zig\",\n    .global_cache_dir = \"/home/runner/.cache/zig\",\n}\n";
    assert_eq!(zig_env_global_cache(zon), Some(PathBuf::from("/home/runner/.cache/zig")));
    let windows = ".{ .global_cache_dir = \"C:\\\\Users\\\\runner\\\\AppData\\\\Local\\\\zig\" }";
    assert_eq!(
        zig_env_global_cache(windows),
        Some(PathBuf::from("C:\\Users\\runner\\AppData\\Local\\zig"))
    );
    let json = "{\n \"global_cache_dir\": \"/Users/me/.cache/zig\",\n \"version\": \"0.14.0\"\n}";
    assert_eq!(zig_env_global_cache(json), Some(PathBuf::from("/Users/me/.cache/zig")));
    assert_eq!(zig_env_global_cache(".{ .version = \"0.17.0\" }"), None);
    assert_eq!(zig_env_global_cache(".{ .global_cache_dir = \"\" }"), None);
}
