//! A stripped release `bin/cmux` names its backtrace frames through the side
//! map the release strip writes (`scripts/write-app-symbol-map.py`, the
//! format `Contents/Resources/cmux-tui-symbols.bin` has). The executable's
//! frames are named only from the map, as in a binary with no symbol table.
#![cfg(target_os = "macos")]

use std::path::Path;

/// The map of this test executable, written by the release strip's own writer.
fn map_of_this_executable() -> Vec<u8> {
    let exe = std::env::current_exe().unwrap();
    let writer =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../scripts/write-app-symbol-map.py");
    let dir = std::env::temp_dir().join(format!("cmux-panic-log-map-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = dir.join(cmux_panic_log::backtrace::SYMBOL_MAP_NAME);
    let status = std::process::Command::new("python3")
        .arg("-I")
        .arg(&writer)
        .arg(&exe)
        .arg(&out)
        .status()
        .unwrap();
    assert!(status.success(), "{writer:?} failed");
    let map = std::fs::read(&out).unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    map
}

#[inline(never)]
fn a_frame_only_the_map_names(map: &[u8]) -> String {
    let text = cmux_panic_log::backtrace::force_capture_with_map(map).expect("map of this build");
    std::hint::black_box(text)
}

#[test]
fn the_executable_frames_are_named_from_the_side_map() {
    let map = map_of_this_executable();
    let text = a_frame_only_the_map_names(&map);
    assert!(text.contains("named_frames::a_frame_only_the_map_names"), "{text}");
    assert!(
        text.contains("named_frames::the_executable_frames_are_named_from_the_side_map"),
        "{text}"
    );
    // Every frame keeps its image and offset, which the build's dSYM resolves to a line.
    assert!(text.contains(" (named_frames-"), "{text}");
    // Names are demangled as std prints them, without the hash.
    assert!(!text.contains("17h"), "{text}");
}

#[test]
fn another_build_map_names_nothing() {
    let other = b"CMXSYM1\0\x00\x00\x00\x00".to_vec();
    assert!(cmux_panic_log::backtrace::force_capture_with_map(&other).is_none());
}
