use std::path::{Path, PathBuf};

/// Files a libghostty-vt source tree must carry. The snapshot header is the
/// one the cmux `ghostty` fork lacks, so pointing the build at that tree (or
/// at an uninitialized, empty submodule directory) fails here instead of
/// later in bindgen or the session host.
pub const REQUIRED_VT_SOURCE_FILES: [&str; 3] =
    ["build.zig", "include/ghostty/vt.h", "include/ghostty/vt/snapshot.h"];

/// Resolve the libghostty-vt source tree, or explain how to fix it. Never
/// falls back to another tree.
pub fn resolve_vt_source(dir: &Path) -> Result<PathBuf, String> {
    let fix = "Run `git submodule update --init ghostty-next` at the cmux repo root, \
               or set CMUX_GHOSTTY_SRC to a manaflow-ai/ghostty-next checkout.";
    let resolved = dir.canonicalize().map_err(|error| {
        format!("libghostty-vt source not found at {} ({error}). {fix}", dir.display())
    })?;
    for required in REQUIRED_VT_SOURCE_FILES {
        if !resolved.join(required).is_file() {
            return Err(format!(
                "libghostty-vt source at {} is missing {required}: the ghostty-next \
                 submodule is empty or the tree is not manaflow-ai/ghostty-next. {fix}",
                resolved.display()
            ));
        }
    }
    Ok(resolved)
}

/// The `-Dtarget=` argument for zig, if any.
///
/// macOS builds always name the target with Ghostty's macOS minimum
/// (`ghostty_macos_min`). Ghostty's build (`src/build/Config.zig`) replaces a
/// macOS target with its generic macOS target at that minimum when the build
/// host is macOS, so neither MACOSX_DEPLOYMENT_TARGET nor rustc's default
/// reaches libghostty-vt's objects on a Mac. Naming the same minimum
/// explicitly gives the same objects on every build host.
pub fn zig_target_arg(target: &str, host: &str, ghostty_macos_min: &str) -> Option<String> {
    if let Some(arch) = macos_arch(target) {
        return Some(format!("-Dtarget={arch}-macos.{ghostty_macos_min}"));
    }
    // Preserve Zig's native target selection for other native builds. The
    // GNU Windows host is the exception: Zig otherwise defaults to MSVC and
    // requires a Windows SDK even when the Rust toolchain is MinGW-only.
    if target == host && !target.ends_with("-windows-gnu") {
        return None;
    }
    zig_target_for_rust_target(target).map(|zig_target| format!("-Dtarget={zig_target}"))
}

/// Ghostty's macOS minimum, `MAJOR.MINOR`: the `.macos` arm of `osVersionMin`
/// in a Ghostty `src/build/Config.zig`. `genericMacOSTarget` (the target a
/// macOS build host uses) takes its minimum from that function.
pub fn ghostty_macos_min(config_zig: &str) -> Option<String> {
    let body = &config_zig[config_zig.find("pub fn osVersionMin(")?..];
    let body = &body[..body.find("\n}").unwrap_or(body.len())];
    let arm = &body[body.find(".macos =>")?..];
    let arm = &arm[..arm.find("},").unwrap_or(arm.len())];
    let field = |name: &str| -> Option<u32> {
        let rest = &arm[arm.find(name)? + name.len()..];
        let rest = rest.trim_start().strip_prefix('=')?.trim_start();
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    };
    Some(format!("{}.{}", field(".major")?, field(".minor")?))
}

/// The `-Dcpu=` argument for zig, if any: `CMUX_GHOSTTY_VT_ZIG_CPU` when set,
/// else a baseline CPU for macOS. On a macOS build host Ghostty's generic
/// macOS target drops `-Dcpu` and resolves to the same baseline CPU, so the
/// override has no effect there for macOS targets.
pub fn zig_cpu_arg(target: &str, cpu_override: Option<&str>) -> Option<String> {
    match cpu_override {
        Some(cpu) => Some(format!("-Dcpu={cpu}")),
        None if macos_arch(target).is_some() => Some("-Dcpu=baseline".to_string()),
        None => None,
    }
}

fn macos_arch(target: &str) -> Option<&'static str> {
    match target {
        "aarch64-apple-darwin" => Some("aarch64"),
        "x86_64-apple-darwin" => Some("x86_64"),
        _ => None,
    }
}

fn zig_target_for_rust_target(target: &str) -> Option<&'static str> {
    match target {
        "x86_64-pc-windows-gnu" => Some("x86_64-windows-gnu"),
        "x86_64-pc-windows-msvc" => Some("x86_64-windows-msvc"),
        "aarch64-pc-windows-msvc" => Some("aarch64-windows-msvc"),
        // The iOS app links cmux-terminal-client as a static library inside an
        // xcframework (.github/workflows/cmux-terminal-client-xcframework.yml).
        "aarch64-apple-ios" => Some("aarch64-ios"),
        "aarch64-apple-ios-sim" => Some("aarch64-ios-simulator"),
        "x86_64-apple-ios" => Some("x86_64-ios-simulator"),
        "x86_64-unknown-linux-gnu" => Some("x86_64-linux-gnu"),
        "aarch64-unknown-linux-gnu" => Some("aarch64-linux-gnu"),
        "x86_64-unknown-linux-musl" => Some("x86_64-linux-musl"),
        "aarch64-unknown-linux-musl" => Some("aarch64-linux-musl"),
        _ => None,
    }
}

/// The `.version = "X.Y.Z[-pre]"` of a Ghostty `build.zig.zon`.
pub fn zon_version(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines().find_map(|line| {
        let rest = line.trim().strip_prefix(".version")?.trim_start().strip_prefix('=')?;
        let version = rest.trim().trim_end_matches(',').trim().trim_matches('"');
        let core = version.split(['-', '+']).next()?;
        let parts: Vec<&str> = core.split('.').collect();
        (parts.len() == 3 && parts.iter().all(|part| part.parse::<u32>().is_ok()))
            .then(|| version.to_string())
    })
}

/// `to` relative to `from`, both absolute: the `..` steps up from `from` to
/// their common ancestor, then down to `to`.
pub fn relative_path(from: &Path, to: &Path) -> String {
    let from: Vec<_> = from.components().collect();
    let to: Vec<_> = to.components().collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut parts: Vec<String> = vec!["..".to_string(); from.len() - common];
    parts.extend(to[common..].iter().map(|part| part.as_os_str().to_string_lossy().into_owned()));
    if parts.is_empty() { ".".to_string() } else { parts.join("/") }
}

/// The build.zig.zon of the fuzzing zig project (fuzzing/build.zig), whose
/// `ghostty` dependency is the libghostty-vt tree at `ghostty_relative`.
/// zig checks the fingerprint against the package name; both stay fixed.
pub fn fuzzing_zon(ghostty_relative: &str) -> String {
    let escaped = ghostty_relative.replace('\\', "/").replace('"', "\\\"");
    format!(
        ".{{\n    .name = .cmux_ghostty_vt_fuzz,\n    .version = \"0.0.0\",\n    \
         .fingerprint = 0xcbd6195d5070663f,\n    .minimum_zig_version = \"0.16.0\",\n    \
         .dependencies = .{{ .ghostty = .{{ .path = \"{escaped}\" }} }},\n    \
         .paths = .{{\"\"}},\n}}\n"
    )
}

/// llvm-objcopy `--rename-section` arguments for the fuzzing libghostty-vt.a:
/// its SanitizerCoverage counters become libFuzzer extra counters and its PC
/// tables (Zig's one-word `__sancov_pcs1`, clang's `__sancov_pcs` from the
/// SIMD C++ files) leave the sections libFuzzer reads.
pub const FUZZING_SECTION_RENAMES: [&str; 3] = [
    "__sancov_cntrs=__libfuzzer_extra_counters",
    "__sancov_pcs=__ghostty_vt_sancov_pcs",
    "__sancov_pcs1=__ghostty_vt_sancov_pcs1",
];

/// The library names of the `lib<name>.a` archives in `lib_dir` other than
/// libghostty-vt.a, sorted: what fuzzing/build.zig installed for
/// libghostty-vt to link.
pub fn fuzzing_extra_archives(lib_dir: &Path) -> Vec<String> {
    let entries = std::fs::read_dir(lib_dir)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", lib_dir.display()));
    let mut names: Vec<String> = entries
        .filter_map(|entry| {
            let file = entry.ok()?.file_name().into_string().ok()?;
            let name = file.strip_prefix("lib")?.strip_suffix(".a")?;
            (name != "ghostty-vt").then(|| name.to_string())
        })
        .collect();
    names.sort();
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzing_counters_become_libfuzzer_extra_counters() {
        assert!(FUZZING_SECTION_RENAMES.contains(&"__sancov_cntrs=__libfuzzer_extra_counters"));
        for rename in FUZZING_SECTION_RENAMES {
            let (from, to) = rename.split_once('=').unwrap();
            assert!(from.starts_with("__sancov_"), "{rename}");
            assert!(!to.starts_with("__sancov_"), "{rename}");
        }
    }

    #[test]
    fn fuzzing_links_every_installed_archive_after_ghostty_vt() {
        let root = scratch_tree(
            "fuzz-archives",
            &["libghostty-vt.a", "libsimdutf.a", "libhighway.a", "README"],
        );
        assert_eq!(fuzzing_extra_archives(&root), ["highway", "simdutf"]);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn fuzzing_project_names_ghostty_by_a_relative_path() {
        assert_eq!(
            relative_path(Path::new("/work/out/ghostty-vt-fuzz"), Path::new("/repo/ghostty-next")),
            "../../../repo/ghostty-next"
        );
        assert_eq!(relative_path(Path::new("/a/b"), Path::new("/a/b/c")), "c");
        assert_eq!(relative_path(Path::new("/a/b"), Path::new("/a/b")), ".");
        let zon = fuzzing_zon("../../../repo/ghostty-next");
        assert!(zon.contains(".ghostty = .{ .path = \"../../../repo/ghostty-next\" }"), "{zon}");
        assert!(zon.contains(".name = .cmux_ghostty_vt_fuzz,"), "{zon}");
    }

    fn scratch_tree(name: &str, files: &[&str]) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("ghostty-vt-sys-{name}-{}", std::process::id()));
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
        std::fs::write(&zon, ".{\n    .name = .ghostty,\n    .version = \"1.3.2-dev\",\n}\n")
            .unwrap();
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
            (
                "aarch64-pc-windows-msvc",
                "x86_64-unknown-linux-gnu",
                "-Dtarget=aarch64-windows-msvc",
            ),
            ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-linux-gnu"),
            ("aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-linux-gnu"),
            (
                "x86_64-unknown-linux-musl",
                "aarch64-unknown-linux-gnu",
                "-Dtarget=x86_64-linux-musl",
            ),
            (
                "aarch64-unknown-linux-musl",
                "x86_64-unknown-linux-gnu",
                "-Dtarget=aarch64-linux-musl",
            ),
        ];

        for (target, host, expected) in cases {
            assert_eq!(zig_target_arg(target, host, "13.0").as_deref(), Some(expected), "{target}");
        }
    }
}
