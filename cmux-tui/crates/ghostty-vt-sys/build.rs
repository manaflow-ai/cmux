use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // The ghostty submodule at the cmux repo root is the default source.
    // CMUX_GHOSTTY_SRC overrides it for out-of-tree builds.
    let ghostty_dir = match env::var("CMUX_GHOSTTY_SRC") {
        Ok(p) => PathBuf::from(p),
        Err(_) => manifest_dir.join("../../../ghostty"),
    };
    let ghostty_dir = ghostty_dir.canonicalize().unwrap_or_else(|e| {
        panic!(
            "ghostty source not found at {} ({}). Run `git submodule update --init` \
             or set CMUX_GHOSTTY_SRC.",
            ghostty_dir.display(),
            e
        )
    });
    let ghostty_dir = strip_windows_verbatim(ghostty_dir);

    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_SRC");
    println!("cargo:rerun-if-env-changed=ZIG");
    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_VT_ZIG_CPU");
    println!("cargo:rerun-if-changed={}", ghostty_dir.join("include").display());
    println!("cargo:rerun-if-changed={}", ghostty_dir.join("build.zig").display());
    println!("cargo:rerun-if-changed={}", ghostty_dir.join("src").display());

    // Build libghostty-vt.a with zig. ReleaseFast regardless of the cargo
    // profile: the VT parser is on the PTY hot path and a debug zig build
    // is an order of magnitude slower.
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());
    let prefix = out_dir.join("ghostty-vt");
    let target = env::var("TARGET").unwrap();
    let host = env::var("HOST").unwrap();
    let mut command = Command::new(&zig);
    command
        .current_dir(&ghostty_dir)
        .arg("build")
        .arg("-Demit-lib-vt=true")
        .arg("-Demit-xcframework=false")
        .arg("-Doptimize=ReleaseFast");
    if target != host
        && let Some(zig_target) = zig_target_for_rust_target(&target)
    {
        command.arg(format!("-Dtarget={zig_target}"));
    }
    // Valgrind's instruction emulation doesn't cover every CPU-native SIMD
    // extension zig's default target detection can select (e.g. some AVX-512
    // variants), which SIGILLs under valgrind. CI's valgrind job sets this to
    // "baseline" to match the same workaround ghostty's own build.zig uses
    // for its valgrind step (see `Config.baselineTarget()`).
    if let Ok(cpu) = env::var("CMUX_GHOSTTY_VT_ZIG_CPU") {
        command.arg(format!("-Dcpu={cpu}"));
    }
    let status = command.arg("--prefix").arg(&prefix).status().unwrap_or_else(|e| {
        panic!("failed to run `{zig} build` in {}: {e}", ghostty_dir.display())
    });
    if !status.success() {
        panic!("zig build of libghostty-vt failed with {status}");
    }

    let lib_dir = prefix.join("lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
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

// std::fs::canonicalize on Windows returns \\?\-prefixed extended-length
// paths. clang accepts such a path for the root header but cannot resolve
// nested relative includes from it (ghostty/vt.h -> "ghostty/vt/types.h"
// fails with file-not-found), which broke the windows-gnu bindgen step.
// Strip the verbatim prefix so bindgen/clang see plain paths.
fn strip_windows_verbatim(path: PathBuf) -> PathBuf {
    if cfg!(windows) {
        let s = path.to_string_lossy();
        if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
            return PathBuf::from(format!(r"\\{rest}"));
        }
        if let Some(rest) = s.strip_prefix(r"\\?\") {
            return PathBuf::from(rest);
        }
    }
    path
}

fn zig_target_for_rust_target(target: &str) -> Option<&'static str> {
    match target {
        "x86_64-pc-windows-gnu" => Some("x86_64-windows-gnu"),
        "x86_64-pc-windows-msvc" => Some("x86_64-windows-msvc"),
        "aarch64-pc-windows-msvc" => Some("aarch64-windows-msvc"),
        // Cross-compiling libghostty-vt for the release distribution targets
        // (npm/PyPI `cmux` binaries). zig cross-compiles these cleanly and
        // pairs with cargo-zigbuild for the Rust link step.
        "x86_64-apple-darwin" => Some("x86_64-macos"),
        "aarch64-apple-darwin" => Some("aarch64-macos"),
        "x86_64-unknown-linux-gnu" => Some("x86_64-linux-gnu"),
        "aarch64-unknown-linux-gnu" => Some("aarch64-linux-gnu"),
        _ => None,
    }
}
