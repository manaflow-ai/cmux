use cmux_launch_shell::ffi::{CmuxLaunchShellDisplay, CmuxLaunchShellNow, CmuxLaunchShellPlan};
use std::{
    mem::{align_of, offset_of, size_of},
    path::Path,
    process::Command,
};

#[test]
fn launch_shell_c_layout_and_exports_match_rust() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let temporary = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let source = temporary.join("launch_shell_layout.c");
    let object = temporary.join("launch_shell_layout.o");
    let mut c = String::from("#include <stddef.h>\n#include \"cmux_launch_shell.h\"\n");
    macro_rules! check {
        ($ty:ty, $($field:ident),+ $(,)?) => {{
            c.push_str(&format!("_Static_assert(sizeof({}) == {}, \"size\");\n", stringify!($ty), size_of::<$ty>()));
            c.push_str(&format!("_Static_assert(_Alignof({}) == {}, \"align\");\n", stringify!($ty), align_of::<$ty>()));
            $(c.push_str(&format!("_Static_assert(offsetof({}, {}) == {}, \"offset\");\n", stringify!($ty), stringify!($field), offset_of!($ty, $field)));)+
        }};
    }
    check!(CmuxLaunchShellDisplay, x, y, width, height, scale);
    check!(CmuxLaunchShellNow, build, appearance, displays, display_count);
    check!(
        CmuxLaunchShellPlan,
        frame_x,
        frame_y,
        frame_width,
        frame_height,
        background_rgba,
        bar_rgba,
        appearance,
        reason,
        shows_window,
        uses_default_frame,
        window_id,
        image_path
    );
    std::fs::write(&source, c).unwrap();
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
    assert!(
        output.status.success(),
        "C header layout: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let exports = Command::new("bash")
        .arg(crate_dir.join("../../../scripts/cmux-next/build-app-ffi.sh"))
        .arg("--list-exports")
        .output()
        .unwrap();
    assert!(exports.status.success(), "{}", String::from_utf8_lossy(&exports.stderr));
    let exports = String::from_utf8(exports.stdout).unwrap();
    for name in ["_cmux_launch_shell_plan", "_cmux_launch_shell_input_disposition"] {
        assert!(exports.lines().any(|line| line == name), "missing packaged symbol {name}");
    }
}
