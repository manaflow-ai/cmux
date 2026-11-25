use cmux_launch_record::{CmuxLaunchSidebarInput, CmuxLaunchWindow, CmuxLaunchWindowInput};
use std::{
    mem::{align_of, offset_of, size_of},
    path::Path,
    process::Command,
};

#[test]
fn launch_record_c_layout_and_exports_match_rust() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let temporary = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let source = temporary.join("launch_record_layout.c");
    let object = temporary.join("launch_record_layout.o");
    let mut c = String::from("#include <stddef.h>\n#include \"cmux_launch_record.h\"\n");
    macro_rules! check {
        ($ty:ty, $($field:ident),+ $(,)?) => {{
            c.push_str(&format!("_Static_assert(sizeof({}) == {}, \"size\");\n", stringify!($ty), size_of::<$ty>()));
            c.push_str(&format!("_Static_assert(_Alignof({}) == {}, \"align\");\n", stringify!($ty), align_of::<$ty>()));
            $(c.push_str(&format!("_Static_assert(offsetof({}, {}) == {}, \"offset\");\n", stringify!($ty), stringify!($field), offset_of!($ty, $field)));)+
        }};
    }
    check!(
        CmuxLaunchWindow,
        frame_x,
        frame_y,
        frame_width,
        frame_height,
        display_id,
        background_rgba,
        bar_rgba,
        image_pixel_width,
        image_pixel_height,
        window_id,
        image_key,
        backing_scale,
        screen_frame_x,
        screen_frame_y,
        screen_frame_width,
        screen_frame_height,
        appearance,
        appearance_follows_system,
        fullscreen
    );
    check!(
        CmuxLaunchWindowInput,
        frame_x,
        frame_y,
        frame_width,
        frame_height,
        display_id,
        background_rgba,
        bar_rgba,
        image_pixel_width,
        image_pixel_height,
        window_id,
        image_key,
        visible_workspace_id,
        visible_tab_ids,
        visible_tab_count,
        backing_scale,
        screen_frame_x,
        screen_frame_y,
        screen_frame_width,
        screen_frame_height,
        appearance,
        appearance_follows_system,
        fullscreen
    );
    check!(CmuxLaunchSidebarInput, id, title, icon_key);
    std::fs::write(&source, c).unwrap();
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
    for name in [
        "_cmux_launch_record_front_window",
        "_cmux_launch_record_write",
        "_cmux_launch_record_write_registry",
        "_cmux_launch_record_windows",
    ] {
        assert!(exports.lines().any(|line| line == name), "missing packaged symbol {name}");
    }
}
