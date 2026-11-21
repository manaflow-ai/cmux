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
        // iOS device and simulator targets.
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

/// The zig program the build runs: `ZIG` when set, else the pinned zig that
/// `scripts/install-zig-ci.sh` publishes as `CMUX_ZIG`, else `zig` on PATH.
/// PATH comes last because a runner may hold an older zig ahead of the pin.
pub fn zig_program(zig: Option<String>, cmux_zig: Option<String>) -> String {
    [zig, cmux_zig]
        .into_iter()
        .flatten()
        .find(|path| !path.is_empty())
        .unwrap_or_else(|| "zig".to_string())
}

/// `.minimum_zig_version` from a build.zig.zon (`X.Y.Z`), the Zig the tree
/// pins (scripts/ghostty-zig-version.sh reads the same field).
pub fn zon_minimum_zig(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines().find_map(|line| {
        let rest =
            line.trim().strip_prefix(".minimum_zig_version")?.trim_start().strip_prefix('=')?;
        let version = rest.trim().trim_end_matches(',').trim().trim_matches('"');
        let parts: Vec<&str> = version.split('.').collect();
        (parts.len() == 3 && parts.iter().all(|part| part.parse::<u32>().is_ok()))
            .then(|| version.to_string())
    })
}

/// Whether zig `actual` builds a tree that needs `required`: the same major and
/// minor and at least its patch (scripts/ghostty-zig-version.sh's rule).
pub fn zig_compatible(actual: &str, required: &str) -> bool {
    let parse = |v: &str| -> Option<(u32, u32, u32)> {
        let mut parts = v.trim().split('.').map(|part| part.parse::<u32>().ok());
        let version = (parts.next()??, parts.next()??, parts.next()??);
        parts.next().is_none().then_some(version)
    };
    match (parse(actual), parse(required)) {
        (Some(a), Some(r)) => a.0 == r.0 && a.1 == r.1 && a.2 >= r.2,
        _ => false,
    }
}

/// Where a host keeps zig `version` beside PATH: the fleet's Linux pool image
/// installs every Zig it carries as `/opt/zig-<version>`.
pub fn installed_zig_paths(version: &str) -> Vec<String> {
    vec![format!("/opt/zig-{version}/zig")]
}

/// The zig the build runs: the first of `candidates` (``zig_program``'s pick,
/// then PATH, then ``installed_zig_paths``) whose `zig version` serves
/// `required`. With no pin, or when none serves it, the first candidate, which
/// then fails with Ghostty's own version message. The second value says why a
/// later candidate replaced the first (a cargo warning).
///
/// A builder whose recipe still hands over an older zig (the Linux pool ran a
/// baked recipe with Zig 0.16 for days after ghostty-next moved to 0.17, while
/// its image already held /opt/zig-0.17.0) builds with the tree's pin instead.
pub fn select_zig(
    candidates: &[String],
    required: Option<&str>,
    version_of: impl Fn(&str) -> Option<String>,
) -> (String, Option<String>) {
    let first = candidates.first().cloned().unwrap_or_else(|| "zig".to_string());
    let Some(required) = required else { return (first, None) };
    let mut seen = Vec::new();
    for candidate in candidates.iter().filter(|c| !c.is_empty()) {
        if seen.contains(candidate) {
            continue;
        }
        seen.push(candidate.clone());
        if let Some(actual) = version_of(candidate)
            && zig_compatible(&actual, required)
        {
            let why = (candidate != &first).then(|| {
                format!(
                    "{first} does not serve the pinned Zig {required}; building libghostty-vt with {candidate} ({actual})"
                )
            });
            return (candidate.clone(), why);
        }
    }
    (first, None)
}

/// The lock of our Zig package mirror, from the crate directory
/// (scripts/ci/zig-packages.lock at the cmux repo root).
pub const ZIG_PACKAGE_LOCK: &str = "../../../scripts/ci/zig-packages.lock";

/// What Zig's HTTP client is pointed at when the mirror is the only source:
/// it reads these proxies (std.http.Client.initDefaultProxies) and nothing
/// listens on port 9, so any fetch Zig itself makes fails at once.
pub const NO_ROUTE_PROXY: &str = "http://127.0.0.1:9";
pub const PROXY_VARS: [&str; 6] =
    ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"];
/// Bypass lists Zig honors; mirror-only removes them so nothing routes around the proxy.
pub const NO_PROXY_VARS: [&str; 2] = ["NO_PROXY", "no_proxy"];

/// One package of the mirror: its Zig package hash and the copy's URL.
#[derive(Debug, PartialEq, Eq)]
pub struct MirroredPackage {
    pub hash: String,
    pub url: String,
}

/// The packages of scripts/ci/zig-packages.lock tagged `tag` (`vt`: what this
/// crate's zig build fetches), at `<mirror><hash>.tar.gz`. Lines are
/// `mirror PREFIX` and `HASH SHA256 TAGS UPSTREAM DEPS`; a line that starts
/// with `#` is a comment.
pub fn mirrored_packages(lock: &str, tag: &str) -> Vec<MirroredPackage> {
    let lines: Vec<Vec<&str>> = lock
        .lines()
        .map(|line| line.split_whitespace().collect())
        // A line that starts with # is a comment (a git+ URL's #commit is not).
        .filter(|parts: &Vec<&str>| parts.first().is_some_and(|first| !first.starts_with('#')))
        .collect();
    let Some(mirror) = lines.iter().find_map(|parts| match parts.as_slice() {
        ["mirror", prefix] => Some(*prefix),
        _ => None,
    }) else {
        return Vec::new();
    };
    lines
        .iter()
        .filter_map(|parts| match parts.as_slice() {
            [hash, _sha, tags, _upstream, _deps] if tags.split(',').any(|t| t == tag) => {
                Some(MirroredPackage {
                    hash: (*hash).to_string(),
                    url: format!("{mirror}{hash}.tar.gz"),
                })
            }
            _ => None,
        })
        .collect()
}

/// Whether Zig may fetch only from our mirror: `CMUX_ZIG_MIRROR_ONLY` (1 or 0),
/// else on in CI (`CI=true`), off elsewhere.
pub fn mirror_only(setting: Option<&str>, ci: Option<&str>) -> bool {
    match setting.map(str::trim) {
        Some("1") | Some("true") => true,
        Some("0") | Some("false") => false,
        _ => ci.is_some_and(|ci| ci.trim().eq_ignore_ascii_case("true")),
    }
}

/// Zig's global cache directory from `zig env` (ZON: `.global_cache_dir = "..."`,
/// or the JSON older Zigs print).
pub fn zig_env_global_cache(output: &str) -> Option<PathBuf> {
    let start = output.find("global_cache_dir")? + "global_cache_dir".len();
    let rest = &output[start..];
    // Past the key's own closing quote (JSON), the `=` or `:`, then the value's quote.
    let sep = rest.find(['=', ':'])?;
    let open = sep + rest[sep..].find('"')?;
    let mut value = String::new();
    let mut chars = rest[open + 1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => value.push(chars.next()?),
            '"' => return (!value.is_empty()).then(|| PathBuf::from(value)),
            _ => value.push(c),
        }
    }
    None
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
        assert_eq!(
            select_zig(&candidates[..1], Some("0.17.0"), versions),
            ("zig".to_string(), None)
        );
        assert_eq!(select_zig(&candidates, None, versions), ("zig".to_string(), None));
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
        let windows =
            ".{ .global_cache_dir = \"C:\\\\Users\\\\runner\\\\AppData\\\\Local\\\\zig\" }";
        assert_eq!(
            zig_env_global_cache(windows),
            Some(PathBuf::from("C:\\Users\\runner\\AppData\\Local\\zig"))
        );
        let json =
            "{\n \"global_cache_dir\": \"/Users/me/.cache/zig\",\n \"version\": \"0.14.0\"\n}";
        assert_eq!(zig_env_global_cache(json), Some(PathBuf::from("/Users/me/.cache/zig")));
        assert_eq!(zig_env_global_cache(".{ .version = \"0.17.0\" }"), None);
        assert_eq!(zig_env_global_cache(".{ .global_cache_dir = \"\" }"), None);
    }
}
