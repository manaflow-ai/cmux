use std::{path::Path, process::Command};

/// The sweep's header compiles as C with the report layout that
/// `sign_clone_report_layout_matches_the_header` (src/sign_clone_sweep.rs)
/// asserts on the Rust side, and its function is in the packaged export list.
#[test]
fn sign_clone_sweep_header_compiles_and_is_exported() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let temporary = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let source = temporary.join("sign_clone_sweep_header.c");
    let object = temporary.join("sign_clone_sweep_header.o");
    std::fs::write(
        &source,
        "#include <stddef.h>\n#include \"cmux_sign_clone_sweep.h\"\n\
         bool (*sweep)(uint64_t, uint32_t, CmuxSignCloneSweepReport *) = cmux_sign_clone_sweep;\n\
         _Static_assert(sizeof(CmuxSignCloneSweepReport) == 32, \"size\");\n\
         _Static_assert(offsetof(CmuxSignCloneSweepReport, reclaimed_bytes) == 0, \"reclaimed\");\n\
         _Static_assert(offsetof(CmuxSignCloneSweepReport, free_space_delta_bytes) == 8, \"free\");\n\
         _Static_assert(offsetof(CmuxSignCloneSweepReport, removed) == 16, \"removed\");\n\
         _Static_assert(offsetof(CmuxSignCloneSweepReport, kept_in_use) == 20, \"in use\");\n\
         _Static_assert(offsetof(CmuxSignCloneSweepReport, kept_foreign) == 24, \"foreign\");\n\
         _Static_assert(offsetof(CmuxSignCloneSweepReport, more) == 28, \"more\");\n",
    )
    .unwrap();
    let output = Command::new("cc")
        .arg("-std=c11")
        .arg("-Werror")
        .arg("-I")
        .arg(crate_dir.join("include"))
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
    assert!(exports.lines().any(|line| line == "_cmux_sign_clone_sweep"));
}
