use std::collections::hash_map::DefaultHasher;
use std::env;
use std::fs::{File, OpenOptions};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;

use fs2::FileExt;

fn main() {
    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_SRC");
    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_CONFIG_KIT");
    println!("cargo:rerun-if-env-changed=ZIG");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let ghostty_dir = env::var_os("CMUX_GHOSTTY_SRC")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest_dir.join("../../../ghostty"));
    let ghostty_dir = ghostty_dir.canonicalize().unwrap_or_else(|error| {
        panic!(
            "Ghostty source not found at {} ({error}); initialize the submodule or set CMUX_GHOSTTY_SRC",
            ghostty_dir.display()
        )
    });
    println!("cargo:rerun-if-changed={}", ghostty_dir.join("build.zig").display());
    println!("cargo:rerun-if-changed={}", ghostty_dir.join("include/ghostty_config.h").display());
    println!(
        "cargo:rerun-if-changed={}",
        ghostty_dir.join("src/config/StandaloneCApi.zig").display()
    );
    println!("cargo:rerun-if-changed={}", ghostty_dir.join("src/config/serialize.zig").display());
    println!(
        "cargo:rerun-if-changed={}",
        ghostty_dir.join("src/build/GhosttyConfigLib.zig").display()
    );

    let configured_kit = env::var_os("CMUX_GHOSTTY_CONFIG_KIT").map(PathBuf::from);
    let kit = configured_kit
        .clone()
        .unwrap_or_else(|| ghostty_dir.join("macos/GhosttyConfigKit.xcframework"));
    let archive = if configured_kit.is_some() {
        find_universal_archive(&kit).unwrap_or_else(|| {
            panic!(
                "CMUX_GHOSTTY_CONFIG_KIT does not contain libghostty-config.a: {}",
                kit.display()
            )
        })
    } else {
        // Hold the lock while inspecting as well as building. Another Cargo
        // process may have created the output path but not finished writing
        // its universal archive yet.
        let _lock = config_kit_build_lock(&ghostty_dir);
        find_universal_archive(&kit).unwrap_or_else(|| {
            build_config_kit(&ghostty_dir);
            find_universal_archive(&kit).unwrap_or_else(|| {
                panic!(
                    "GhosttyConfigKit build succeeded without producing the universal macOS archive under {}",
                    kit.display()
                )
            })
        })
    };
    verify_universal_archive(&archive);
    println!("cargo:rerun-if-changed={}", archive.display());
    println!("cargo:rustc-link-search=native={}", archive.parent().unwrap().display());
    println!("cargo:rustc-link-lib=static=ghostty-config");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
    println!("cargo:rustc-link-lib=dylib=objc");
}

fn find_universal_archive(path: &Path) -> Option<PathBuf> {
    if path.is_file() {
        if path.file_name()?.to_str()? != "libghostty-config.a" {
            return None;
        }
        return Some(path.to_owned());
    }
    let archive = path.join("macos-arm64_x86_64/libghostty-config.a");
    if archive.is_file() { Some(archive) } else { None }
}

fn verify_universal_archive(archive: &Path) {
    let status = Command::new("/usr/bin/lipo")
        .arg(archive)
        .args(["-verify_arch", "arm64", "x86_64"])
        .status()
        .unwrap_or_else(|error| {
            panic!("failed to inspect ConfigKit archive {}: {error}", archive.display())
        });
    if !status.success() {
        panic!(
            "ConfigKit archive must contain universal macOS arm64 and x86_64 slices: {}",
            archive.display()
        );
    }
}

fn build_config_kit(ghostty_dir: &Path) {
    let zig = env::var_os("ZIG").map(PathBuf::from).unwrap_or_else(|| {
        let homebrew = PathBuf::from("/opt/homebrew/opt/zig@0.15/bin/zig");
        if homebrew.is_file() { homebrew } else { PathBuf::from("zig") }
    });
    let status = Command::new(&zig)
        .current_dir(ghostty_dir)
        .args([
            "build",
            "-Dapp-runtime=none",
            "-Demit-xcframework=false",
            "-Demit-scene-xcframework=false",
            "-Demit-config-xcframework=true",
            "-Demit-macos-app=false",
            "-Dxcframework-target=universal",
            "-Doptimize=ReleaseFast",
        ])
        .status()
        .unwrap_or_else(|error| panic!("failed to run {}: {error}", zig.display()));
    if !status.success() {
        panic!("GhosttyConfigKit build failed with {status}");
    }
}

fn config_kit_build_lock(ghostty_dir: &Path) -> File {
    let mut hasher = DefaultHasher::new();
    ghostty_dir.hash(&mut hasher);
    let path =
        env::temp_dir().join(format!("cmux-ghostty-config-kit-{:016x}.lock", hasher.finish()));
    let file =
        OpenOptions::new().create(true).read(true).write(true).open(&path).unwrap_or_else(
            |error| panic!("failed to open build lock {}: {error}", path.display()),
        );
    FileExt::lock_exclusive(&file)
        .unwrap_or_else(|error| panic!("failed to lock {}: {error}", path.display()));
    file
}
