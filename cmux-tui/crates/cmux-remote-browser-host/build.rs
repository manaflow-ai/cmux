//! macOS: compiles the CEF shim (csrc/rb_shim.mm) and CEF's C++ wrapper
//! (libcef_dll) against CEF_PATH, the unpacked fork release (remote-tab-r2.md
//! B5: cef-154.0.28-cmux.19, pinned by sha256). Elsewhere it does nothing: the
//! pure host core builds and tests without CEF.

use std::path::{Path, PathBuf};

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "cc" || e == "mm") {
            out.push(path);
        }
    }
}

fn main() {
    println!("cargo:rerun-if-changed=csrc/rb_shim.mm");
    println!("cargo:rerun-if-changed=csrc/rb_shim.h");
    println!("cargo:rerun-if-env-changed=CEF_PATH");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let cef = PathBuf::from(
        std::env::var("CEF_PATH")
            .expect("CEF_PATH must name the unpacked CEF fork release (remote-tab-r2.md B5)"),
    );
    let mut wrapper = Vec::new();
    sources(&cef.join("libcef_dll"), &mut wrapper);
    // CEF's own wrapper: its headers warn by the thousand under -Wall
    // -Wextra, so this build is quiet and sees CEF through -isystem.
    let mut wrapper_build = cc::Build::new();
    wrapper_build
        .cpp(true)
        .std("c++20")
        .warnings(false)
        .flag(format!("-isystem{}", cef.display()))
        .define("WRAPPING_CEF_SHARED", None)
        .flag("-fno-exceptions")
        .flag("-fno-rtti")
        .flag("-fobjc-arc")
        .flag("-mmacosx-version-min=12.0")
        .flag("-Wno-undefined-var-template")
        .files(wrapper);
    wrapper_build.compile("cmux_cef_wrapper");
    // Our shim: CEF headers as system headers (quiet), our code under -Wall
    // -Werror.
    let mut shim = cc::Build::new();
    shim.cpp(true)
        .std("c++20")
        .warnings(true)
        .warnings_into_errors(true)
        .flag(format!("-isystem{}", cef.display()))
        .include("csrc")
        .flag("-fno-exceptions")
        .flag("-fno-rtti")
        .flag("-fobjc-arc")
        .flag("-mmacosx-version-min=12.0")
        .file("csrc/rb_shim.mm");
    shim.compile("cmux_rb_shim");
    for framework in ["Cocoa", "AppKit", "IOSurface", "CoreGraphics"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
