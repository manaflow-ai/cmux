use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

#[path = "build_support.rs"]
mod build_support;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // libghostty-vt comes from the `ghostty-next` submodule at the cmux repo
    // root (manaflow-ai/ghostty-next: upstream libghostty-vt with the snapshot
    // encoder, plus the ported fork VT patches). The `ghostty` submodule is
    // the Mac app's GhosttyKit source and is never used here: a missing
    // ghostty-next checkout is a hard error, not a fallback.
    // CMUX_GHOSTTY_SRC overrides the source for out-of-tree builds.
    // An empty CMUX_GHOSTTY_SRC means unset: CI workflows set it empty so a
    // runner-level value can never redirect the build away from the gitlink.
    let ghostty_dir = match env::var("CMUX_GHOSTTY_SRC") {
        Ok(p) if !p.is_empty() => PathBuf::from(p),
        _ => manifest_dir.join("../../../ghostty-next"),
    };
    let ghostty_dir = require_vt_source(&ghostty_dir);

    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_SRC");
    println!("cargo:rerun-if-env-changed=ZIG");
    println!("cargo:rerun-if-env-changed=CMUX_ZIG");
    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_VT_ZIG_CPU");
    println!("cargo:rerun-if-env-changed=CMUX_ZIG_MIRROR_ONLY");
    emit_cargo_path_directive("rerun-if-changed", &ghostty_dir.join("include"));
    // Keep the generated binding fingerprint tied to the public terminal API.
    // Hosted build caches can otherwise restore bindings from an older
    // submodule revision even after checkout replaced this header.
    emit_cargo_path_directive(
        "rerun-if-changed",
        &ghostty_dir.join("include/ghostty/vt/terminal.h"),
    );
    emit_cargo_path_directive("rerun-if-changed", &ghostty_dir.join("build.zig"));
    emit_cargo_path_directive("rerun-if-changed", &ghostty_dir.join("src"));

    // Build libghostty-vt.a with zig. ReleaseFast regardless of the cargo
    // profile: the VT parser is on the PTY hot path and a debug zig build
    // is an order of magnitude slower.
    let required_zig = build_support::zon_minimum_zig(&ghostty_dir.join("build.zig.zon"));
    let mut zig_candidates = vec![
        build_support::zig_program(env::var("ZIG").ok(), env::var("CMUX_ZIG").ok()),
        "zig".to_string(),
    ];
    if let Some(required) = &required_zig {
        zig_candidates.extend(build_support::installed_zig_paths(required));
    }
    let (zig, why) = build_support::select_zig(&zig_candidates, required_zig.as_deref(), |zig| {
        let output = Command::new(zig).arg("version").output().ok()?;
        output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
    });
    if let Some(why) = why {
        println!("cargo:warning={why}");
    }
    // No build fetches from a third-party host: every package this build
    // fetches comes from our mirror first (scripts/ci/zig-packages.lock), and in
    // CI Zig gets no route to anywhere else. codeberg.org's outage on
    // 2026-11-11 failed every cold build here (translate_c's aro is
    // git+https://codeberg.org/ziglang/arocc).
    let mirror_only = build_support::mirror_only(
        env::var("CMUX_ZIG_MIRROR_ONLY").ok().as_deref(),
        env::var("CI").ok().as_deref(),
    );
    seed_zig_packages(
        &zig,
        &ghostty_dir,
        &manifest_dir.join(build_support::ZIG_PACKAGE_LOCK),
        mirror_only,
    );
    let prefix = out_dir.join("ghostty-vt");
    let target = env::var("TARGET").unwrap();
    let host = env::var("HOST").unwrap();
    let mut command = Command::new(&zig);
    command
        .current_dir(&ghostty_dir)
        .arg("build")
        .arg("-Demit-lib-vt=true")
        .arg("-Demit-xcframework=false")
        // No build fetches packages it does not use, so each source archive
        // equals the real fetch list: libghostty-vt never needs the iTerm2
        // theme set (emit-themes defaults to true and fetches it lazily).
        .arg("-Demit-themes=false")
        .arg("-Doptimize=ReleaseFast");
    // ghostty-next publishes releases as git tags (xcframework-<sha>-<flavor>)
    // on main commits. Ghostty's build reads `git describe` and panics on a
    // tag that is not vX.Y.Z, so a checkout that fetched tags could not build.
    // An explicit version string skips git detection.
    if let Some(version) = build_support::zon_version(&ghostty_dir.join("build.zig.zon")) {
        command.arg(format!("-Dversion-string={version}"));
    }
    // Pass the target when cross-compiling, and always for windows-gnu:
    // zig defaults to the msvc ABI on Windows, so a native *-windows-gnu
    // host (no Visual Studio, e.g. a rustup gnu toolchain with MSYS2) would
    // otherwise get `-target native-native-msvc` and fail the zig build with
    // "failed to find libc installation: WindowsSdkNotFound".
    // macOS targets name Ghostty's own macOS minimum (see zig_target_arg).
    let config_zig = ghostty_dir.join("src/build/Config.zig");
    let macos_min = if target.ends_with("-apple-darwin") {
        std::fs::read_to_string(&config_zig)
            .ok()
            .and_then(|text| build_support::ghostty_macos_min(&text))
            .unwrap_or_else(|| {
                panic!("no macOS minimum (osVersionMin .macos) found in {}", config_zig.display())
            })
    } else {
        String::new()
    };
    if let Some(target_arg) = build_support::zig_target_arg(&target, &host, &macos_min) {
        command.arg(target_arg);
    }
    // macOS builds use a baseline CPU, not the build Mac's. Valgrind's
    // instruction emulation doesn't cover every CPU-native SIMD extension
    // zig's default target detection can select (e.g. some AVX-512 variants),
    // which SIGILLs under valgrind. CI's valgrind job sets
    // CMUX_GHOSTTY_VT_ZIG_CPU to "baseline" to match the same workaround
    // ghostty's own build.zig uses for its valgrind step (see
    // `Config.baselineTarget()`).
    let cpu = env::var("CMUX_GHOSTTY_VT_ZIG_CPU").ok();
    if let Some(cpu_arg) = build_support::zig_cpu_arg(&target, cpu.as_deref()) {
        command.arg(cpu_arg);
    }
    if mirror_only {
        for name in build_support::PROXY_VARS {
            command.env(name, build_support::NO_ROUTE_PROXY);
        }
        // An inherited bypass list (`NO_PROXY=*`, or a host) would route around the proxy.
        for name in build_support::NO_PROXY_VARS {
            command.env_remove(name);
        }
    }
    let status = command.arg("--prefix").arg(&prefix).status().unwrap_or_else(|e| {
        panic!("failed to run `{zig} build` in {}: {e}", ghostty_dir.display())
    });
    if !status.success() {
        if mirror_only {
            panic!(
                "zig build of libghostty-vt failed with {status}. Zig could fetch only from our \
                 mirror (CMUX_ZIG_MIRROR_ONLY, on in CI): a package it could not fetch is not in \
                 scripts/ci/zig-packages.lock's `vt` set or its mirror; see \
                 scripts/ci/zig_package_mirror.py"
            );
        }
        panic!("zig build of libghostty-vt failed with {status}");
    }

    let lib_dir = prefix.join("lib");
    emit_cargo_path_directive("rustc-link-search=native", &lib_dir);
    if target.contains("windows") {
        // zig installs the Windows static archive as `ghostty-vt-static.lib`
        // (distinct from the DLL import library `ghostty-vt.lib`), but rustc's
        // *-windows-gnu targets only search the MinGW name `lib<name>.a`.
        // Mirror the archive under that name; the contents are identical.
        if target.contains("windows-gnu") {
            let src = lib_dir.join("ghostty-vt-static.lib");
            let dst = lib_dir.join("libghostty-vt-static.a");
            std::fs::copy(&src, &dst).unwrap_or_else(|e| {
                panic!("failed to copy {} to {}: {e}", src.display(), dst.display())
            });
        }
        println!("cargo:rustc-link-lib=static=ghostty-vt-static");
    } else {
        println!("cargo:rustc-link-lib=static=ghostty-vt");
    }

    // Generate bindings from the public C header.
    let include_dir = ghostty_dir.join("include");
    let bindings = bindgen::Builder::default()
        .header(include_dir.join("ghostty/vt.h").to_str().unwrap().to_string())
        .clang_arg(format!("-I{}", include_dir.display()))
        .allowlist_function("ghostty_.*")
        .allowlist_type("Ghostty.*")
        .allowlist_var("GHOSTTY_.*")
        .prepend_enum_name(false)
        .derive_default(true)
        .layout_tests(false)
        .generate()
        .expect("bindgen failed for ghostty/vt.h");
    bindings.write_to_file(out_dir.join("bindings.rs")).expect("failed to write bindings.rs");
}

/// Put the `vt` packages of our mirror into Zig's global cache as
/// p/<hash>.tar.gz, which Zig reads before it fetches a URL and checks against
/// the package hash (lib/compiler/Maker/Fetch.zig). A package already unpacked
/// in the source's zig-pkg/ or archived in p/ is skipped. A download that fails
/// is left to Zig: upstream outside CI, a named failure in mirror-only mode.
fn seed_zig_packages(zig: &str, ghostty_dir: &Path, lock: &Path, mirror_only: bool) {
    let Ok(text) = std::fs::read_to_string(lock) else {
        if mirror_only {
            println!(
                "cargo:warning=no Zig package lock at {}; Zig fetches nothing",
                lock.display()
            );
        }
        return;
    };
    let packages = build_support::mirrored_packages(&text, "vt");
    let cache =
        Command::new(zig).arg("env").output().ok().and_then(|out| {
            build_support::zig_env_global_cache(&String::from_utf8_lossy(&out.stdout))
        });
    let Some(cache) = cache else {
        println!(
            "cargo:warning=`{zig} env` named no global cache; the Zig package mirror is not used"
        );
        return;
    };
    let archives = cache.join("p");
    if let Err(error) = std::fs::create_dir_all(&archives) {
        println!("cargo:warning=cannot create {}: {error}", archives.display());
        return;
    }
    for package in packages {
        let archive = archives.join(format!("{}.tar.gz", package.hash));
        if archive.exists() || ghostty_dir.join("zig-pkg").join(&package.hash).exists() {
            continue;
        }
        // Under a name with no archive suffix until whole, so a cut-short
        // download never takes the name Zig reads.
        let part = archives.join(format!(".seed-{}-{}", package.hash, std::process::id()));
        let fetched = Command::new("curl")
            .args(["-fsSL", "--proto", "=https", "--retry", "3", "--retry-all-errors"])
            .args(["--connect-timeout", "20", "--max-time", "300", "-o"])
            .arg(&part)
            .arg(&package.url)
            .status()
            .is_ok_and(|status| status.success());
        if fetched && std::fs::rename(&part, &archive).is_ok() {
            continue;
        }
        let _ = std::fs::remove_file(&part);
        println!("cargo:warning=could not download {} from the Zig package mirror", package.url);
    }
}

fn require_vt_source(dir: &Path) -> PathBuf {
    match build_support::resolve_vt_source(dir) {
        Ok(resolved) => strip_windows_verbatim(resolved),
        Err(message) => panic!("{message}"),
    }
}

fn emit_cargo_path_directive(directive: &str, path: &Path) {
    let value = path
        .to_str()
        .unwrap_or_else(|| panic!("cargo:{directive} path is not valid UTF-8: {}", path.display()));
    if value.bytes().any(|byte| matches!(byte, b'\r' | b'\n')) {
        panic!("cargo:{directive} path contains CR or LF: {}", path.display());
    }
    println!("cargo:{directive}={value}");
}

// std::fs::canonicalize on Windows returns \\?\-prefixed extended-length
// paths. clang accepts such a path for the root header but cannot resolve
// nested relative includes from it (ghostty/vt.h -> "ghostty/vt/types.h"
// fails with file-not-found), which broke the windows-gnu bindgen step.
// Strip the verbatim prefix so bindgen/clang see plain paths.
fn strip_windows_verbatim(path: PathBuf) -> PathBuf {
    if cfg!(windows) {
        let s = path.to_str().unwrap_or_else(|| {
            panic!("canonical Ghostty source path is not valid UTF-8: {}", path.display())
        });
        if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
            return PathBuf::from(format!(r"\\{rest}"));
        }
        if let Some(rest) = s.strip_prefix(r"\\?\") {
            return PathBuf::from(rest);
        }
    }
    path
}
