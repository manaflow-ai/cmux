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
    let candidate_dirs = [
        workspace_dir.join("ghostty"),
        workspace_dir
            .parent()
            .map(|parent| parent.join("ghostty"))
            .unwrap_or_else(|| workspace_dir.join("ghostty")),
    ];
    let ghostty_dir = candidate_dirs
        .into_iter()
        .find(|path| path.join("build.zig").exists())
        .unwrap_or_else(|| {
            panic!(
                "ghostty submodule not found. Checked: {} and {}",
                workspace_dir.join("ghostty").display(),
                workspace_dir
                    .parent()
                    .map(|parent| parent.join("ghostty"))
                    .unwrap_or_else(|| workspace_dir.join("ghostty"))
                    .display()
            )
        });

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

    // Newer upstream Ghostty installs the embedded `app-runtime=none` library as
    // `ghostty-internal.{so,a}` instead of `libghostty.{so,a}` (its SONAME is
    // still `libghostty.so`). Materialize the historical `libghostty.*` names so
    // the `-lghostty` link and runtime SONAME lookup below keep working across
    // both old and new Ghostty.
    let install_lib_dir = install_dir.join("lib");
    for (renamed, legacy) in [
        ("ghostty-internal.so", "libghostty.so"),
        ("ghostty-internal.a", "libghostty.a"),
    ] {
        let renamed_path = install_lib_dir.join(renamed);
        let legacy_path = install_lib_dir.join(legacy);
        if renamed_path.exists() && !legacy_path.exists() {
            fs::copy(&renamed_path, &legacy_path).unwrap_or_else(|error| {
                panic!(
                    "failed to alias {} to {}: {}",
                    renamed_path.display(),
                    legacy_path.display(),
                    error
                )
            });
        }
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
        panic!("ghostty-build-data failed with status: {}", output.status);
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
    let profile_dir = output_dir
        .ancestors()
        .nth(3)
        .expect("OUT_DIR should be nested under target/<profile>/build")
        .to_path_buf();
    let profile_deps_dir = profile_dir.join("deps");
    fs::create_dir_all(&profile_deps_dir).expect("failed to create target deps dir");
    copy_runtime_libraries(
        &lib_dir,
        &[profile_dir.as_path(), profile_deps_dir.as_path()],
    );

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

fn copy_runtime_libraries(lib_dir: &std::path::Path, destinations: &[&std::path::Path]) {
    let entries = fs::read_dir(lib_dir).expect("failed to list built Ghostty libs");
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let Some(file_name) = path.file_name() else {
            continue;
        };

        for destination in destinations {
            let target = destination.join(file_name);
            fs::copy(&path, &target).unwrap_or_else(|error| {
                panic!(
                    "failed to copy {} to {}: {}",
                    path.display(),
                    target.display(),
                    error
                )
            });
        }
    }
}
