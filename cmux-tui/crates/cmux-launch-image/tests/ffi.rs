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
fn publish_with_hands_the_new_image_to_the_record_only_when_written() {
    unsafe extern "C" fn record(image: *const CmuxLaunchImage, context: *mut std::ffi::c_void) {
        // SAFETY: the ABI passes a valid image for the call; `context` is the test's `Vec<String>`.
        let (image, seen) = unsafe { (&*image, &mut *context.cast::<Vec<String>>()) };
        assert!(std::path::Path::new(&path(image)).exists());
        seen.push(path(image));
    }
    let dir = dir("handoff");
    let id = CString::new("win").unwrap();
    let bytes = png(4, 3);
    let mut seen: Vec<String> = Vec::new();
    let mut out = blank();
    let context = ptr::from_mut(&mut seen).cast();
    // SAFETY: valid strings, buffer, output, and a hand-off that reads `context` as `seen`.
    assert!(unsafe {
        cmux_launch_image_publish_with(
            dir.as_ptr(),
            id.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            &mut out,
            Some(record),
            context,
        )
    });
    assert_eq!(seen, [path(&out)]);
    // Not a PNG: nothing written, no hand-off.
    // SAFETY: as above.
    assert!(!unsafe {
        cmux_launch_image_publish_with(
            dir.as_ptr(),
            id.as_ptr(),
            b"nope".as_ptr(),
            4,
            &mut out,
            Some(record),
            context,
        )
    });
    assert_eq!(seen.len(), 1);
    // A null hand-off publishes like `cmux_launch_image_publish`.
    // SAFETY: as above.
    assert!(unsafe {
        cmux_launch_image_publish_with(
            dir.as_ptr(),
            id.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            &mut out,
            None,
            ptr::null_mut(),
        )
    });
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

/// The record's `image_key` the stage-0 window reads (cmux-launch-shell `ImageKey`): split on `/`
/// into build, window key and generation, it names the very file the publish wrote,
/// `<image dir>/<window key>.<generation>.png`, and never a path.
#[test]
fn record_key_names_the_published_file() {
    let dir = dir("record-key");
    for raw_id in ["front", "a window/with:odd id"] {
        let id = CString::new(raw_id).unwrap();
        let bytes = png(2880, 1800);
        let mut out = blank();
        // SAFETY: valid strings, buffer and output.
        assert!(unsafe {
            cmux_launch_image_publish(
                dir.as_ptr(),
                id.as_ptr(),
                bytes.as_ptr(),
                bytes.len(),
                &mut out,
            )
        });
        let (version, commit) = (CString::new("4294").unwrap(), CString::new("abc123").unwrap());
        let mut key = [1 as c_char; CMUX_LAUNCH_IMAGE_KEY_CAPACITY];
        // SAFETY: valid strings and a buffer of `key.len()` bytes.
        assert!(unsafe {
            cmux_launch_image_record_key(
                version.as_ptr(),
                commit.as_ptr(),
                id.as_ptr(),
                out.generation,
                key.as_mut_ptr(),
                key.len(),
            )
        });
        // SAFETY: the ABI NUL-terminates `key`.
        let key = unsafe { CStr::from_ptr(key.as_ptr()) }.to_str().unwrap().to_owned();
        let parts: Vec<&str> = key.split('/').collect();
        assert_eq!(parts.len(), 3, "{key}");
        assert_eq!(parts[0], "4294+abc123");
        assert_eq!(parts[1], cmux_launch_image::window_key(raw_id));
        assert_eq!(parts[2], out.generation.to_string());
        let named =
            PathBuf::from(dir.to_str().unwrap()).join(format!("{}.{}.png", parts[1], parts[2]));
        assert_eq!(named.to_str().unwrap(), path(&out), "the key names the published file");
        assert!(!key.starts_with('/') && !key.contains(".png"), "a key, not a path: {key}");
    }
    let id = CString::new("front").unwrap();
    let mut small = [1 as c_char; 8];
    // SAFETY: a null version and commit are allowed; the buffer has `small.len()` bytes.
    assert!(!unsafe {
        cmux_launch_image_record_key(
            ptr::null(),
            ptr::null(),
            id.as_ptr(),
            1,
            small.as_mut_ptr(),
            small.len(),
        )
    });
    assert_eq!(small[0], 0, "a key that does not fit leaves an empty string");
    // SAFETY: as above.
    assert!(!unsafe {
        cmux_launch_image_record_key(
            ptr::null(),
            ptr::null(),
            ptr::null(),
            1,
            small.as_mut_ptr(),
            small.len(),
        )
    });
}
