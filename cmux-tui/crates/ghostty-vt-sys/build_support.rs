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

pub fn zig_target_arg(target: &str, host: &str) -> Option<String> {
    // Preserve Zig's native target selection for existing native builds. The
    // GNU Windows host is the exception: Zig otherwise defaults to MSVC and
    // requires a Windows SDK even when the Rust toolchain is MinGW-only.
    if target == host && !target.ends_with("-windows-gnu") {
        return None;
    }
    zig_target_for_rust_target(target).map(|zig_target| format!("-Dtarget={zig_target}"))
}

fn zig_target_for_rust_target(target: &str) -> Option<&'static str> {
    match target {
        "x86_64-pc-windows-gnu" => Some("x86_64-windows-gnu"),
        "x86_64-pc-windows-msvc" => Some("x86_64-windows-msvc"),
        "aarch64-pc-windows-msvc" => Some("aarch64-windows-msvc"),
        // Cross-compiling libghostty-vt for the release distribution targets
        // (npm/PyPI `cmux` binaries). Zig cross-compiles these cleanly and
        // pairs with cargo-zigbuild for the Rust link step.
        "x86_64-apple-darwin" => Some("x86_64-macos"),
        "aarch64-apple-darwin" => Some("aarch64-macos"),
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

#[cfg(test)]
mod tests {
    use super::*;

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
            zig_target_arg("x86_64-pc-windows-gnu", "x86_64-pc-windows-gnu").as_deref(),
            Some("-Dtarget=x86_64-windows-gnu")
        );
    }

    #[test]
    fn native_non_windows_builds_keep_zigs_native_target() {
        assert_eq!(zig_target_arg("aarch64-apple-darwin", "aarch64-apple-darwin"), None);
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
            ("x86_64-apple-darwin", "aarch64-unknown-linux-gnu", "-Dtarget=x86_64-macos"),
            ("aarch64-apple-darwin", "x86_64-unknown-linux-gnu", "-Dtarget=aarch64-macos"),
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
            assert_eq!(zig_target_arg(target, host).as_deref(), Some(expected), "{target}");
        }
    }
}
