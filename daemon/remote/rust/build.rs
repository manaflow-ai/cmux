use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set"));
    let shim_dir = manifest_dir.join("ghostty-shim");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set"));
    let install_dir = out_dir.join("ghostty-shim-install");
    let rust_target = env::var("TARGET").expect("TARGET is set");
    let macos_deployment =
        env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "11.0".to_string());

    let ghostty_source = env::var_os("GHOSTTY_SOURCE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest_dir.join("../../../ghostty"));
    if !ghostty_source.join("build.zig").exists() {
        panic!(
            "Ghostty source not found at {}. Set GHOSTTY_SOURCE_DIR to the worktree ghostty checkout.",
            ghostty_source.display()
        );
    }

    let shim_link = shim_dir.join("ghostty");
    ensure_symlink(&ghostty_source, &shim_link)
        .expect("failed to link Ghostty source into shim workspace");

    // The embedded Ghostty VT hits debug-only assertions on real shell output.
    // Build the shim in release mode by default so the daemon stays alive.
    let optimize =
        env::var("CMUX_GHOSTTY_SHIM_OPTIMIZE").unwrap_or_else(|_| "ReleaseFast".to_string());
    let mut command = Command::new("zig");
    command
        .current_dir(&shim_dir)
        .arg("build")
        .arg("--prefix")
        .arg(&install_dir)
        .arg(format!("-Doptimize={optimize}"));
    if let Some(zig_target) = zig_target_for_rust(&rust_target, &macos_deployment) {
        command.arg(format!("-Dtarget={zig_target}"));
    }
    let status = command
        .status()
        .expect("failed to run zig build for cmux Ghostty shim");
    if !status.success() {
        panic!("zig build failed for cmux Ghostty shim");
    }

    println!(
        "cargo:rustc-link-search=native={}",
        install_dir.join("lib").display()
    );
    println!("cargo:rustc-link-lib=dylib=cmux-ghostty-shim");
    println!(
        "cargo:rustc-link-arg=-Wl,-rpath,{}",
        install_dir.join("lib").display()
    );
    let cpp_runtime = match rust_target.as_str() {
        target if target.contains("apple-darwin") => "c++",
        target if target.contains("linux") => "stdc++",
        _ => "c++",
    };
    println!("cargo:rerun-if-env-changed=GHOSTTY_SOURCE_DIR");
    println!("cargo:rerun-if-env-changed=CMUX_GHOSTTY_SHIM_OPTIMIZE");
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("build.rs").display()
    );
    println!("cargo:rustc-link-lib={cpp_runtime}");
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("ghostty-shim/build.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("ghostty-shim/build.zig.zon").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("ghostty-shim/src/root.zig").display()
    );
}

#[cfg(unix)]
fn ensure_symlink(target: &Path, link: &Path) -> Result<(), String> {
    use std::os::unix::fs as unix_fs;

    let target = target
        .canonicalize()
        .map_err(|err| format!("canonicalize {}: {err}", target.display()))?;

    if let Ok(existing) = fs::read_link(link) {
        let resolved = if existing.is_absolute() {
            existing
        } else {
            link.parent()
                .unwrap_or_else(|| Path::new("."))
                .join(existing)
        };
        if resolved == target {
            return Ok(());
        }
    }

    if let Ok(metadata) = fs::symlink_metadata(link) {
        if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
            fs::remove_dir_all(link)
                .map_err(|err| format!("remove_dir_all {}: {err}", link.display()))?;
        } else {
            fs::remove_file(link)
                .map_err(|err| format!("remove_file {}: {err}", link.display()))?;
        }
    }

    unix_fs::symlink(&target, link)
        .map_err(|err| format!("symlink {} -> {}: {err}", link.display(), target.display()))
}

#[cfg(not(unix))]
fn ensure_symlink(_target: &Path, _link: &Path) -> Result<(), String> {
    Err("cmux Ghostty shim only supports unix-like builds".to_string())
}

fn zig_target_for_rust(rust_target: &str, macos_deployment: &str) -> Option<String> {
    let arch = match rust_target {
        "aarch64-apple-darwin" => "aarch64",
        "x86_64-apple-darwin" => "x86_64",
        _ => return None,
    };
    Some(format!("{arch}-macos.{macos_deployment}"))
}
