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
        "#include \"cmux_launch_shell.h\"\nuint8_t (*check)(uint8_t, size_t) = cmux_launch_shell_input_disposition;\nbool (*replays)(uint8_t, bool, bool) = cmux_launch_shell_replays;\nbool (*plan)(const char *, const char *, const CmuxLaunchShellNow *, CmuxLaunchShellPlan *) = cmux_launch_shell_plan;\n_Static_assert(sizeof(CmuxLaunchShellPlan) == 1200, \"plan layout\");\nchar *(*cover_plan)(const char *, uint64_t, uint64_t, const CmuxLaunchShellDisplay *, size_t, const char *) = cmux_relaunch_cover_take_plan;\nbool (*cover_write)(const char *, const char *) = cmux_relaunch_cover_write;\nvoid (*cover_clear)(const char *, const char *) = cmux_relaunch_cover_clear;\nvoid (*cover_free)(char *) = cmux_relaunch_cover_string_free;\nCmuxRelaunchCoverReveal *(*reveal_new)(const char *, uint8_t, uint64_t) = cmux_relaunch_cover_reveal_new;\nvoid (*reveal_free)(CmuxRelaunchCoverReveal *) = cmux_relaunch_cover_reveal_free;\nchar *(*reveal_start)(CmuxRelaunchCoverReveal *) = cmux_relaunch_cover_reveal_start;\nchar *(*reveal_ready)(CmuxRelaunchCoverReveal *, const char *, const char *, uint64_t) = cmux_relaunch_cover_reveal_surface_ready;\nchar *(*reveal_mismatch)(CmuxRelaunchCoverReveal *, const char *) = cmux_relaunch_cover_reveal_mismatch;\nchar *(*reveal_tick)(CmuxRelaunchCoverReveal *, uint64_t, uint64_t *) = cmux_relaunch_cover_reveal_tick;\n",
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
            "_cmux_launch_shell_plan",
            "_cmux_relaunch_cover_string_free",
            "_cmux_relaunch_cover_write",
            "_cmux_relaunch_cover_take_plan",
            "_cmux_relaunch_cover_clear",
            "_cmux_relaunch_cover_reveal_new",
            "_cmux_relaunch_cover_reveal_free",
            "_cmux_relaunch_cover_reveal_start",
            "_cmux_relaunch_cover_reveal_surface_ready",
            "_cmux_relaunch_cover_reveal_mismatch",
            "_cmux_relaunch_cover_reveal_tick"
        ]
        .iter()
        .all(|symbol| exports.lines().any(|line| line == *symbol)),
        "missing packaged symbol"
    );
}
