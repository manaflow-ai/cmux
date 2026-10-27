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
    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_VT_ZIG_CPU");
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
    // is an order of magnitude slower. A fuzzing build (cargo fuzz passes
    // `--cfg fuzzing`) goes through fuzzing/build.zig instead: ReleaseSafe
    // with SanitizerCoverage, so libFuzzer sees the parser's edges and a Zig
    // safety check failure is a crash.
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());
    let prefix = out_dir.join("ghostty-vt");
    let target = env::var("TARGET").unwrap();
    let host = env::var("HOST").unwrap();
    let fuzzing = env::var_os("CARGO_CFG_FUZZING").is_some();
    emit_cargo_path_directive("rerun-if-changed", &manifest_dir.join("fuzzing/build.zig"));
    let mut command = Command::new(&zig);
    if fuzzing {
        let project = out_dir.join("ghostty-vt-fuzz");
        write_fuzzing_project(&project, &ghostty_dir);
        command.current_dir(&project).arg("build");
    } else {
        command
            .current_dir(&ghostty_dir)
            .arg("build")
            .arg("-Demit-lib-vt=true")
            .arg("-Demit-xcframework=false")
            // No build fetches packages it does not use, so each source
            // archive equals the real fetch list: libghostty-vt never needs
            // the iTerm2 theme set (emit-themes defaults to true and fetches
            // it lazily).
            .arg("-Demit-themes=false")
            .arg("-Doptimize=ReleaseFast");
    }
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
    let status = command.arg("--prefix").arg(&prefix).status().unwrap_or_else(|e| {
        panic!("failed to run `{zig} build` in {}: {e}", ghostty_dir.display())
    });
    if !status.success() {
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
    if fuzzing {
        move_coverage_to_extra_counters(&lib_dir.join("libghostty-vt.a"), &host);
        // fuzzing/build.zig installs the SIMD archives beside libghostty-vt.a
        // instead of merging them into it; they come after it on the link line.
        for name in build_support::fuzzing_extra_archives(&lib_dir) {
            println!("cargo:rustc-link-lib=static={name}");
        }
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

/// Zig's -ffuzz writes a one-word-per-PC table (`__sancov_pcs1`) that
/// libFuzzer cannot read, and libFuzzer refuses to start when its counters
/// and PC tables differ in length. libghostty-vt's counters go to libFuzzer's
/// extra-counters section instead (FuzzerExtraCounters.cpp), which feeds
/// coverage features with no PC table; its PC tables are renamed out of the
/// way. llvm-objcopy comes from the fuzz toolchain's llvm-tools-preview.
fn move_coverage_to_extra_counters(archive: &Path, host: &str) {
    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let output = Command::new(&rustc)
        .args(["--print", "sysroot"])
        .output()
        .unwrap_or_else(|e| panic!("failed to run `{rustc} --print sysroot`: {e}"));
    let sysroot = String::from_utf8(output.stdout).expect("rustc sysroot is not UTF-8");
    let objcopy = Path::new(sysroot.trim()).join("lib/rustlib").join(host).join("bin/llvm-objcopy");
    let mut command = Command::new(&objcopy);
    for rename in build_support::FUZZING_SECTION_RENAMES {
        command.arg("--rename-section").arg(rename);
    }
    let status = command.arg(archive).status().unwrap_or_else(|e| {
        panic!("failed to run {} (rustup component add llvm-tools-preview): {e}", objcopy.display())
    });
    if !status.success() {
        panic!("llvm-objcopy on {} failed with {status}", archive.display());
    }
}

/// The zig project of a fuzzing build: fuzzing/build.zig and a build.zig.zon
/// whose `ghostty` dependency is the libghostty-vt tree (zig accepts only a
/// path relative to the project).
fn write_fuzzing_project(project: &Path, ghostty_dir: &Path) {
    std::fs::create_dir_all(project)
        .unwrap_or_else(|e| panic!("failed to create {}: {e}", project.display()));
    let project = canonical_dir(project);
    let dependency = build_support::relative_path(&project, ghostty_dir);
    let files = [
        ("build.zig", include_str!("fuzzing/build.zig").to_string()),
        ("build.zig.zon", build_support::fuzzing_zon(&dependency)),
    ];
    for (name, contents) in files {
        let path = project.join(name);
        std::fs::write(&path, contents)
            .unwrap_or_else(|e| panic!("failed to write {}: {e}", path.display()));
    }
}

fn canonical_dir(dir: &Path) -> PathBuf {
    let resolved =
        dir.canonicalize().unwrap_or_else(|e| panic!("failed to resolve {}: {e}", dir.display()));
    strip_windows_verbatim(resolved)
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
