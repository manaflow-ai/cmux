use std::env;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let workspace_dir = manifest_dir.parent().unwrap();

    // Path to the ghostty submodule (will be initialized in Phase 0)
    let ghostty_dir = workspace_dir.join("ghostty");

    if ghostty_dir.join("build.zig").exists() {
        // Build libghostty as a static library using zig build
        let output_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

        let status = std::process::Command::new("zig")
            .arg("build")
            .arg("-Dapp-runtime=embedded")
            .arg("-Demit-static-lib=true")
            .arg("-Doptimize=ReleaseFast")
            .arg(&format!(
                "-Dprefix={}",
                output_dir.join("ghostty-install").display()
            ))
            .current_dir(&ghostty_dir)
            .status()
            .expect("Failed to run zig build. Is zig installed?");

        if !status.success() {
            panic!("zig build failed with status: {}", status);
        }

        // Link the static library
        let lib_dir = output_dir.join("ghostty-install").join("lib");
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
        println!("cargo:rustc-link-lib=static=ghostty");

        // System dependencies that libghostty requires
        println!("cargo:rustc-link-lib=dylib=GL");
        println!("cargo:rustc-link-lib=dylib=EGL");
        println!("cargo:rustc-link-lib=dylib=fontconfig");
        println!("cargo:rustc-link-lib=dylib=freetype");

        // Rerun if ghostty source changes (enumerate key files)
        println!("cargo:rerun-if-changed={}", ghostty_dir.join("build.zig").display());
        println!("cargo:rerun-if-changed={}", ghostty_dir.join("build.zig.zon").display());
        println!("cargo:rerun-if-changed={}", ghostty_dir.join("src").display());
    } else {
        // Ghostty submodule not initialized yet — build with stub mode
        println!(
            "cargo:warning=ghostty submodule not found at {}. Building in stub mode.",
            ghostty_dir.display()
        );
    }
}
