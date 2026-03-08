use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    // Without the link-ghostty feature, compile in stub mode — no zig build needed.
    if env::var("CARGO_FEATURE_LINK_GHOSTTY").is_err() {
        return;
    }

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let workspace_dir = manifest_dir.parent().unwrap();

    // Path to the ghostty submodule
    let ghostty_dir = workspace_dir.join("ghostty");

    if !ghostty_dir.join("build.zig").exists() {
        panic!(
            "ghostty submodule not found at {}. Run: git submodule update --init ghostty",
            ghostty_dir.display()
        );
    }

    // Build libghostty as a static library using zig build
    let output_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    let install_dir = output_dir.join("ghostty-install");

    let status = Command::new("zig")
        .arg("build")
        .arg("-Dapp-runtime=none") // none = libghostty (embedded runtime)
        .arg("-Doptimize=ReleaseFast")
        .arg("-Demit-terminfo=true")
        .arg("--prefix")
        .arg(install_dir.as_os_str())
        .current_dir(&ghostty_dir)
        .status()
        .expect("Failed to run zig build. Is zig installed?");

    if !status.success() {
        panic!("zig build failed with status: {}", status);
    }

    // `app-runtime=none` does not install resources, so generate the
    // Ghostty terminfo bundle ourselves for embedded hosts.
    let share_dir = install_dir.join("share");
    let resources_dir = share_dir.join("ghostty");
    let terminfo_dir = share_dir.join("terminfo");
    fs::create_dir_all(&resources_dir).expect("failed to create ghostty resources dir");
    fs::create_dir_all(&terminfo_dir).expect("failed to create ghostty terminfo dir");

    let terminfo_helper_src = output_dir.join("ghostty-terminfo.zig");
    fs::write(
        &terminfo_helper_src,
        r#"const std = @import("std");
const ghostty = @import("ghostty_terminfo").ghostty;

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout_writer.interface;
    try ghostty.encode(writer);
    try stdout_writer.end();
}
"#,
    )
    .expect("failed to write ghostty terminfo helper");

    let build_data_exe = output_dir.join("ghostty-terminfo");
    let ghostty_terminfo_module = ghostty_dir.join("src").join("terminfo").join("ghostty.zig");
    let status = Command::new("zig")
        .arg("build-exe")
        .arg("--dep")
        .arg("ghostty_terminfo")
        .arg(format!("-Mroot={}", terminfo_helper_src.display()))
        .arg(format!(
            "-Mghostty_terminfo={}",
            ghostty_terminfo_module.display()
        ))
        .arg("-O")
        .arg("ReleaseFast")
        .arg(format!("-femit-bin={}", build_data_exe.display()))
        .status()
        .expect("Failed to build ghostty-build-data helper");

    if !status.success() {
        panic!("zig build-exe failed with status: {}", status);
    }

    let terminfo_source = output_dir.join("ghostty.terminfo");
    let output = Command::new(&build_data_exe)
        .arg("+terminfo")
        .output()
        .expect("Failed to generate ghostty terminfo source");

    if !output.status.success() {
        panic!(
            "ghostty-build-data failed with status: {}",
            output.status
        );
    }

    fs::write(&terminfo_source, &output.stdout).expect("failed to write ghostty terminfo source");
    fs::write(terminfo_dir.join("ghostty.terminfo"), &output.stdout)
        .expect("failed to install ghostty terminfo source");

    let status = Command::new("tic")
        .arg("-x")
        .arg("-o")
        .arg(&terminfo_dir)
        .arg(&terminfo_source)
        .status()
        .expect("Failed to compile ghostty terminfo database with tic");

    if !status.success() {
        panic!("tic failed with status: {}", status);
    }

    // Compile GLAD (OpenGL loader) — ghostty's build excludes it from libghostty,
    // expecting the host application to provide it.
    let glad_dir = ghostty_dir.join("vendor").join("glad");
    cc::Build::new()
        .file(glad_dir.join("src").join("gl.c"))
        .include(glad_dir.join("include"))
        .compile("glad");

    // Link libghostty as a shared library (includes all vendored deps)
    let lib_dir = install_dir.join("lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib=ghostty");
    println!(
        "cargo:rustc-env=GHOSTTY_BUNDLED_RESOURCES_DIR={}",
        resources_dir.display()
    );

    // Rerun if ghostty source changes or feature flag changes
    println!("cargo:rerun-if-changed={}", ghostty_dir.display());
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_LINK_GHOSTTY");
}
