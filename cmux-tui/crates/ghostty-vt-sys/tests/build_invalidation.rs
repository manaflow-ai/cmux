#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

struct TestTree {
    root: PathBuf,
}

impl TestTree {
    fn new() -> Self {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let root = std::env::temp_dir()
            .join(format!("cmux-ghostty-vt-invalidation-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        Self { root }
    }
}

impl Drop for TestTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn run_build(workspace: &Path, ghostty: &Path, target: &Path, zig: &Path, log: &Path) {
    let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
    let output = Command::new(cargo)
        .current_dir(workspace)
        .args(["build", "--quiet", "-p", "ghostty-vt-sys"])
        .env("CMUX_GHOSTTY_SRC", ghostty)
        .env("CARGO_TARGET_DIR", target)
        .env("ZIG", zig)
        .env("FAKE_ZIG_LOG", log)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "nested ghostty-vt-sys build failed:\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn native_archive_rebuilds_when_a_ghostty_package_source_changes() {
    let tree = TestTree::new();
    let ghostty = tree.root.join("ghostty");
    fs::create_dir_all(ghostty.join("include/ghostty")).unwrap();
    fs::create_dir(ghostty.join("src")).unwrap();
    fs::create_dir_all(ghostty.join("pkg/simdutf")).unwrap();
    fs::write(ghostty.join("build.zig"), b"// fake build").unwrap();
    fs::write(ghostty.join("build.zig.zon"), b".{}").unwrap();
    fs::write(ghostty.join("include/ghostty/vt.h"), b"typedef unsigned short GhosttyMode;\n")
        .unwrap();
    fs::write(ghostty.join("src/main.zig"), b"// fake source").unwrap();
    let package_input = ghostty.join("pkg/simdutf/input");
    fs::write(&package_input, b"one").unwrap();

    let zig = tree.root.join("fake-zig");
    fs::write(
        &zig,
        br#"#!/bin/sh
set -eu
printf 'run\n' >> "$FAKE_ZIG_LOG"
prefix=
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--prefix" ]; then
        shift
        prefix=$1
    fi
    shift
done
test -n "$prefix"
mkdir -p "$prefix/lib"
printf 'void cmux_ghostty_vt_test_archive(void) {}\n' > "$prefix/empty.c"
/usr/bin/cc -c "$prefix/empty.c" -o "$prefix/empty.o"
/usr/bin/ar crs "$prefix/lib/libghostty-vt.a" "$prefix/empty.o"
"#,
    )
    .unwrap();
    let mut permissions = fs::metadata(&zig).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&zig, permissions).unwrap();

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace = manifest_dir.ancestors().nth(2).unwrap();
    let target = tree.root.join("target");
    let log = tree.root.join("zig.log");
    run_build(workspace, &ghostty, &target, &zig, &log);
    assert_eq!(fs::read_to_string(&log).unwrap().lines().count(), 1);

    fs::write(package_input, b"two").unwrap();
    run_build(workspace, &ghostty, &target, &zig, &log);

    assert_eq!(
        fs::read_to_string(&log).unwrap().lines().count(),
        2,
        "Ghostty package changes did not rerun the native build script"
    );
}
