//! The C ABI: publish fills the launch record's path and size, "no image" zeroes the output, null
//! arguments are refused, and the schedule round-trips.

use cmux_launch_image::ffi::*;
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::ptr;

fn dir(name: &str) -> CString {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("launch-image-ffi-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    CString::new(dir.into_os_string().into_string().unwrap()).unwrap()
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
    bytes.extend_from_slice(&13_u32.to_be_bytes());
    bytes.extend_from_slice(b"IHDR");
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&height.to_be_bytes());
    bytes.resize(64, 0);
    bytes
}

fn blank() -> CmuxLaunchImage {
    // SAFETY: all-zero is a valid CmuxLaunchImage (integers and a char array).
    let mut image: CmuxLaunchImage = unsafe { std::mem::zeroed() };
    image.generation = 99;
    image.path[0] = b'x' as c_char;
    image
}

fn path(image: &CmuxLaunchImage) -> String {
    // SAFETY: the ABI NUL-terminates `path`.
    unsafe { CStr::from_ptr(image.path.as_ptr()) }.to_str().unwrap().to_owned()
}

#[test]
fn publish_then_current_then_remove() {
    let dir = dir("roundtrip");
    let id = CString::new("win-1").unwrap();
    let bytes = png(2880, 1800);
    let mut out = blank();
    // SAFETY: valid strings, buffer and output.
    assert!(unsafe {
        cmux_launch_image_publish(dir.as_ptr(), id.as_ptr(), bytes.as_ptr(), bytes.len(), &mut out)
    });
    assert_eq!((out.pixel_width, out.pixel_height, out.bytes), (2880, 1800, 64));
    assert!(path(&out).ends_with(&format!("/win-1.{}.png", out.generation)), "{}", path(&out));
    let mut current = blank();
    // SAFETY: as above.
    assert!(unsafe { cmux_launch_image_current(dir.as_ptr(), id.as_ptr(), &mut current) });
    assert_eq!((path(&current), current.generation), (path(&out), out.generation));
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_launch_image_remove_window(dir.as_ptr(), id.as_ptr()) }, 1);
    let mut gone = blank();
    // SAFETY: as above.
    assert!(!unsafe { cmux_launch_image_current(dir.as_ptr(), id.as_ptr(), &mut gone) });
    assert_eq!(
        (gone.generation, gone.pixel_width, path(&gone)),
        (0, 0, String::new()),
        "no image zeroes the output"
    );
}

#[test]
fn bad_arguments_write_nothing() {
    let dir = dir("bad");
    let id = CString::new("win").unwrap();
    let bytes = png(1, 1);
    let mut out = blank();
    // SAFETY: null pointers are part of the contract.
    unsafe {
        assert!(!cmux_launch_image_publish(
            ptr::null(),
            id.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            &mut out
        ));
        assert!(!cmux_launch_image_publish(
            dir.as_ptr(),
            ptr::null(),
            bytes.as_ptr(),
            bytes.len(),
            &mut out
        ));
        assert!(!cmux_launch_image_publish(dir.as_ptr(), id.as_ptr(), ptr::null(), 0, &mut out));
        assert!(!cmux_launch_image_publish(
            dir.as_ptr(),
            id.as_ptr(),
            b"nope".as_ptr(),
            4,
            &mut out
        ));
        assert!(!cmux_launch_image_publish(
            dir.as_ptr(),
            id.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            ptr::null_mut()
        ));
        assert_eq!(cmux_launch_image_prune(dir.as_ptr(), ptr::null(), 3, 0), 0);
        assert_eq!(cmux_launch_image_remove_window(ptr::null(), id.as_ptr()), 0);
    }
    assert_eq!(out.generation, 0);
}

#[test]
fn prune_through_the_abi() {
    let dir = dir("prune");
    let (live, dead) = (CString::new("live").unwrap(), CString::new("dead").unwrap());
    let bytes = png(1, 1);
    let mut out = blank();
    // SAFETY: valid strings, buffer and output.
    unsafe {
        assert!(cmux_launch_image_publish(
            dir.as_ptr(),
            live.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            &mut out
        ));
        assert!(cmux_launch_image_publish(
            dir.as_ptr(),
            dead.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            &mut out
        ));
        let ids = [live.as_ptr()];
        assert_eq!(
            cmux_launch_image_prune(dir.as_ptr(), ids.as_ptr(), ids.len(), 0),
            1,
            "grace 0: everything not live goes"
        );
        assert!(cmux_launch_image_current(dir.as_ptr(), live.as_ptr(), &mut out));
        assert!(!cmux_launch_image_current(dir.as_ptr(), dead.as_ptr(), &mut out));
    }
}

#[test]
fn schedule_through_the_abi() {
    let s = cmux_launch_image_schedule_new(0);
    // SAFETY: `s` is live and used by this thread only; freed once.
    unsafe {
        assert_eq!(
            cmux_launch_image_schedule_note(s, 1, 10),
            CMUX_LAUNCH_IMAGE_NOT_DUE,
            "hidden: not due"
        );
        assert_eq!(
            cmux_launch_image_schedule_note(s, 3, 100),
            850,
            "shown at 100 + the 750 ms default"
        );
        assert_eq!(
            cmux_launch_image_schedule_note(s, 42, 200),
            850,
            "unknown event changes nothing"
        );
        assert!(!cmux_launch_image_schedule_take_due(s, 849));
        assert!(cmux_launch_image_schedule_take_due(s, 850));
        assert!(!cmux_launch_image_schedule_take_quit(s));
        let epoch = cmux_launch_image_schedule_epoch(s);
        assert!(cmux_launch_image_schedule_is_current(s, epoch));
        cmux_launch_image_schedule_note(s, 1, 900);
        assert!(!cmux_launch_image_schedule_is_current(s, epoch));
        cmux_launch_image_schedule_free(s);
        cmux_launch_image_schedule_free(ptr::null_mut());
        assert_eq!(
            cmux_launch_image_schedule_note(ptr::null_mut(), 1, 0),
            CMUX_LAUNCH_IMAGE_NOT_DUE
        );
        assert!(!cmux_launch_image_schedule_is_current(ptr::null(), 0));
    }
}

#[test]
fn page_region_paints_only_a_current_image() {
    let current = CmuxLaunchImagePageRegion {
        has_image: true,
        image_taken_ms: 5_000,
        has_image_version: true,
        image_version: 3,
        page_version: 3,
        has_page_changed: true,
        page_changed_ms: 4_000,
        composite_ms: 6_000,
    };
    // SAFETY: each pointer is null or a live region for the call.
    unsafe {
        assert_eq!(cmux_launch_image_page_region(&current), CMUX_LAUNCH_IMAGE_REGION_IMAGE);
        let navigated = CmuxLaunchImagePageRegion { page_version: 4, ..current };
        assert_eq!(cmux_launch_image_page_region(&navigated), 2);
        let no_image = CmuxLaunchImagePageRegion { has_image: false, ..current };
        assert_eq!(cmux_launch_image_page_region(&no_image), 1);
        let unversioned = CmuxLaunchImagePageRegion { has_image_version: false, ..current };
        assert_eq!(cmux_launch_image_page_region(&unversioned), 2);
        assert_eq!(cmux_launch_image_page_region(ptr::null()), 1);
    }
}
