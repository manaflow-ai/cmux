//! With the `vp9` feature: builds libvpx (VP9 only, static) from a pinned source
//! tarball and generates its bindings. No system libvpx is used or needed.
//!
//! The source comes from `LIBVPX_SRC` (an unpacked libvpx tree, for offline
//! builds) or is downloaded from GitHub's tag archive and checked against
//! `LIBVPX_SHA256` before it is unpacked. Assembly needs nasm or yasm on PATH;
//! without either, libvpx builds its portable C (`--target=generic-gnu`) and the
//! build says so, since its timing is then not what a shipped build would see.

use std::env;
#[cfg(feature = "vp9")]
use std::path::{Path, PathBuf};
#[cfg(feature = "vp9")]
use std::process::Command;

#[cfg(feature = "vp9")]
const LIBVPX_VERSION: &str = "1.16.0";
#[cfg(feature = "vp9")]
const LIBVPX_URL: &str = "https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz";
#[cfg(feature = "vp9")]
const LIBVPX_SHA256: &str = "7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c";

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-env-changed=LIBVPX_SRC");
    if env::var_os("CARGO_FEATURE_VP9").is_none() {
        return;
    }
    #[cfg(feature = "vp9")]
    vp9::build();
}

#[cfg(feature = "vp9")]
fn run(cmd: &mut Command, what: &str) {
    let status = cmd.status().unwrap_or_else(|e| panic!("{what}: {e}"));
    assert!(status.success(), "{what} failed: {status}");
}

#[cfg(feature = "vp9")]
fn on_path(tool: &str) -> bool {
    Command::new(tool).arg("--version").output().is_ok_and(|o| o.status.success())
}

#[cfg(feature = "vp9")]
fn source(out: &Path) -> PathBuf {
    if let Some(dir) = env::var_os("LIBVPX_SRC") {
        return PathBuf::from(dir);
    }
    let dir = out.join(format!("libvpx-{LIBVPX_VERSION}"));
    if dir.join("configure").is_file() {
        return dir;
    }
    let tarball = out.join("libvpx.tar.gz");
    run(
        Command::new("curl").args(["-fsSL", "--retry", "3", "-o"]).arg(&tarball).arg(LIBVPX_URL),
        "download libvpx",
    );
    let sum = Command::new("sha256sum").arg(&tarball).output().expect("sha256sum");
    let sum = String::from_utf8_lossy(&sum.stdout);
    let got = sum.split_whitespace().next().unwrap_or("");
    assert_eq!(got, LIBVPX_SHA256, "libvpx tarball SHA-256 mismatch");
    run(Command::new("tar").arg("xzf").arg(&tarball).arg("-C").arg(out), "unpack libvpx");
    dir
}

#[cfg(feature = "vp9")]
mod vp9 {
    use super::*;

    pub fn build() {
        let out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
        let src = source(&out);
        let build = out.join("libvpx-build");
        let prefix = out.join("libvpx-install");
        let lib = prefix.join("lib").join("libvpx.a");
        if !lib.is_file() {
            let _ = std::fs::remove_dir_all(&build);
            std::fs::create_dir_all(&build).expect("build dir");
            let mut configure = Command::new(src.join("configure"));
            configure.current_dir(&build).arg(format!("--prefix={}", prefix.display())).args([
                "--disable-shared",
                "--enable-static",
                "--enable-pic",
                "--disable-vp8",
                "--enable-vp9",
                "--disable-examples",
                "--disable-tools",
                "--disable-docs",
                "--disable-unit-tests",
                "--disable-webm-io",
                "--disable-libyuv",
                "--enable-realtime-only",
            ]);
            let x86 = env::var("CARGO_CFG_TARGET_ARCH").is_ok_and(|a| a == "x86_64" || a == "x86");
            if x86 && !(on_path("nasm") || on_path("yasm")) {
                println!(
                    "cargo::warning=libvpx: no nasm or yasm on PATH, building portable C (slower than a shipped build)"
                );
                configure.arg("--target=generic-gnu");
            } else if x86 && on_path("nasm") && !on_path("yasm") {
                configure.arg("--as=nasm");
            }
            run(&mut configure, "libvpx configure");
            let jobs = env::var("NUM_JOBS").unwrap_or_else(|_| "4".into());
            run(Command::new("make").current_dir(&build).arg(format!("-j{jobs}")), "libvpx make");
            run(Command::new("make").current_dir(&build).arg("install"), "libvpx make install");
        }
        println!("cargo::rustc-link-search=native={}", prefix.join("lib").display());
        println!("cargo::rustc-link-lib=static=vpx");
        println!("cargo::rustc-link-lib=pthread");
        println!("cargo::rustc-link-lib=m");
        let include = prefix.join("include");
        bindgen::Builder::default()
            .header(include.join("vpx/vp8cx.h").display().to_string())
            .header(include.join("vpx/vp8dx.h").display().to_string())
            .header(include.join("vpx/vpx_encoder.h").display().to_string())
            .header(include.join("vpx/vpx_decoder.h").display().to_string())
            .clang_arg(format!("-I{}", include.display()))
            .allowlist_function("vpx_.*")
            .allowlist_type("vpx_.*|vp8e_.*|vp9e_.*|VP8E_.*|VP9E_.*")
            .allowlist_var("VPX_.*|VP8_.*|VP9E_.*|VP8E_.*")
            .layout_tests(false)
            .generate()
            .expect("libvpx bindings")
            .write_to_file(out.join("vpx_bindings.rs"))
            .expect("write libvpx bindings");
    }
}
