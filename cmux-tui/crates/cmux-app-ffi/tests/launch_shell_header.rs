use std::{path::Path, process::Command};

/// The header compiles as C and every function it declares is in the packaged library's exports.
#[test]
fn launch_shell_header_compiles_and_is_exported() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let temporary = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let source = temporary.join("launch_shell_header.c");
    let object = temporary.join("launch_shell_header.o");
    std::fs::write(
        &source,
        "#include \"cmux_launch_shell.h\"\nuint8_t (*check)(uint8_t, size_t) = cmux_launch_shell_input_disposition;\nbool (*replays)(uint8_t, bool, bool) = cmux_launch_shell_replays;\nuint8_t (*no_record)(const char *, const char *, const char *, bool) = cmux_launch_shell_no_record_reason;\n",
    )
    .unwrap();
    let output = Command::new("cc")
        .arg("-std=c11")
        .arg("-Werror")
        .arg("-I")
        .arg(crate_dir.join("../cmux-launch-shell/include"))
        .arg("-c")
        .arg(&source)
        .arg("-o")
        .arg(&object)
        .output()
        .unwrap();
    assert!(output.status.success(), "C header: {}", String::from_utf8_lossy(&output.stderr));
    let exports = Command::new("bash")
        .arg(crate_dir.join("../../../scripts/cmux-next/build-app-ffi.sh"))
        .arg("--list-exports")
        .output()
        .unwrap();
    assert!(exports.status.success(), "{}", String::from_utf8_lossy(&exports.stderr));
    let exports = String::from_utf8(exports.stdout).unwrap();
    assert!(
        [
            "_cmux_launch_shell_input_disposition",
            "_cmux_launch_shell_replays",
            "_cmux_launch_shell_no_record_reason",
        ]
        .iter()
        .all(|symbol| exports.lines().any(|line| line == *symbol)),
        "missing packaged symbol"
    );
}
