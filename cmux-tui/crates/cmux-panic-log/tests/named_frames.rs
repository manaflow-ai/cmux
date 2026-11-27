//! A stripped release `bin/cmux` names its backtrace frames through the side
//! map the release strip writes (`scripts/write-app-symbol-map.py`, the
//! format `Contents/Resources/cmux-tui-symbols.bin` has). The executable's
//! frames are named only from the map, as in a binary with no symbol table.
#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};
use std::process::Command;

/// Set in the stripped copy's run: the panic log it writes.
const CHILD_LOG_ENV: &str = "CMUX_PANIC_LOG_TEST_CHILD_LOG";

/// Writes the map of `exe` to `out` with the release strip's own writer.
fn write_map(exe: &Path, out: &Path) {
    let writer =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../scripts/write-app-symbol-map.py");
    let status = Command::new("python3").arg("-I").arg(&writer).arg(exe).arg(out).status().unwrap();
    assert!(status.success(), "{writer:?} failed");
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-panic-log-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[inline(never)]
fn a_frame_only_the_map_names(map: &[u8]) -> String {
    let text = cmux_panic_log::backtrace::force_capture_with_map(map).expect("map of this build");
    std::hint::black_box(text)
}

#[test]
fn the_executable_frames_are_named_from_the_side_map() {
    let dir = scratch("map");
    let out = dir.join(cmux_panic_log::backtrace::SYMBOL_MAP_NAME);
    write_map(&std::env::current_exe().unwrap(), &out);
    let text = a_frame_only_the_map_names(&std::fs::read(&out).unwrap());
    let _ = std::fs::remove_dir_all(&dir);
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

#[inline(never)]
fn a_panicking_frame_in_the_stripped_copy() {
    // crash-allow: the panic under test
    panic!("forced panic in the stripped copy");
}

/// Runs only in the stripped copy (below): a worker thread panics through the panic log.
#[test]
fn stripped_copy_child_panics_into_the_log() {
    let Some(log) = std::env::var_os(CHILD_LOG_ENV) else { return };
    cmux_panic_log::install(PathBuf::from(log), cmux_panic_log::Fields::new(), |_| false);
    let joined = std::thread::Builder::new()
        .name("worker".into())
        .spawn(a_panicking_frame_in_the_stripped_copy)
        .unwrap()
        .join();
    assert!(joined.is_err());
}

/// The release layout end to end: this test binary copied to
/// `cmux.app/Contents/Resources/bin/cmux`, its map written beside `bin/` from
/// the unstripped binary, the copy stripped as the release strip does (plain
/// `strip`, then signed ad hoc again), and a forced panic in the copy. Its
/// panic log line names the panicking function, which the copy's own symbol
/// table no longer holds.
#[test]
fn a_panic_in_a_fully_stripped_bundle_binary_names_its_frames() {
    if std::env::var_os(CHILD_LOG_ENV).is_some() {
        return;
    }
    let dir = scratch("bundle");
    let resources = dir.join("cmux.app/Contents/Resources");
    std::fs::create_dir_all(resources.join("bin")).unwrap();
    let copy = resources.join("bin/cmux");
    // A child writes the copy: a write descriptor held here would reach a sibling test's child until its exec
    // and fail running the copy with ETXTBSY (check-test-determinism.py exec-of-a-file-written-in-process).
    assert!(
        Command::new("cp")
            .arg(std::env::current_exe().unwrap())
            .arg(&copy)
            .status()
            .unwrap()
            .success()
    );
    write_map(&copy, &resources.join(cmux_panic_log::backtrace::SYMBOL_MAP_NAME));
    assert!(Command::new("strip").arg(&copy).status().unwrap().success());
    let signed = Command::new("codesign").args(["-s", "-", "-f"]).arg(&copy).status().unwrap();
    assert!(signed.success());
    let nm = Command::new("nm").arg(&copy).output().unwrap();
    let left = String::from_utf8_lossy(&nm.stdout);
    assert!(!left.contains("a_panicking_frame_in_the_stripped_copy"), "strip kept it: {left}");

    let log = dir.join("panics.jsonl");
    let child = Command::new(&copy)
        .args(["--exact", "stripped_copy_child_panics_into_the_log", "--nocapture"])
        .env(CHILD_LOG_ENV, &log)
        .output()
        .unwrap();
    assert!(child.status.success(), "{}", String::from_utf8_lossy(&child.stderr));
    let text = std::fs::read_to_string(&log).unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    let line: serde_json::Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    let backtrace = line["backtrace"].as_str().unwrap();
    println!("{backtrace}");
    assert!(
        backtrace.contains("named_frames::a_panicking_frame_in_the_stripped_copy (cmux + 0x"),
        "{backtrace}"
    );
}
