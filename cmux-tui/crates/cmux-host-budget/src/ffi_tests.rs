//! The C ABI as the app calls it: bytes in, owned strings out, levels as numbers.

use super::*;
use crate::Budget;
use crate::tests::gray;
use std::ffi::CStr;

/// Takes a returned string, frees it and gives its text (`None` for null).
fn take(text: *mut c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    // SAFETY: a live string from a cmux_host_budget_*_json call.
    let owned = unsafe { CStr::from_ptr(text) }.to_str().unwrap().to_owned();
    // SAFETY: freed once.
    unsafe { cmux_host_budget_string_free(text) };
    Some(owned)
}

fn verdict(load: f64, pressure: u32) -> String {
    serde_json::to_string(&gray(load, pressure, 0.5, 0.0, &Budget::default())).unwrap()
}

#[test]
fn the_abi_version_is_one() {
    assert_eq!(cmux_host_budget_ffi_abi_version(), 1);
}

#[test]
fn a_verdict_is_judged_again_through_the_abi() {
    let fine = verdict(2.0, 1);
    // SAFETY: `fine` is readable for its length.
    let warned = take(unsafe { cmux_host_budget_with_pressure_json(fine.as_ptr(), fine.len(), 2) });
    let warned: serde_json::Value = serde_json::from_str(&warned.unwrap()).unwrap();
    assert_eq!(warned["over"], serde_json::json!(["memory pressure warn"]));
    // SAFETY: a null pointer is allowed.
    assert_eq!(take(unsafe { cmux_host_budget_with_pressure_json(std::ptr::null(), 0, 2) }), None);
    let bad = b"\xff\xfe";
    // SAFETY: `bad` is readable for its length.
    assert_eq!(
        take(unsafe { cmux_host_budget_with_pressure_json(bad.as_ptr(), bad.len(), 2) }),
        None
    );
}

#[test]
fn the_tracker_handle_moves_and_frees() {
    let tracker = cmux_host_pressure_tracker_new(1);
    let critical = verdict(2.0, 4);
    let calm = verdict(2.0, 1);
    // SAFETY: a live tracker and readable bytes, one thread.
    unsafe {
        assert_eq!(cmux_host_pressure_tracker_level(tracker), 0);
        assert_eq!(cmux_host_pressure_tracker_feed(tracker, critical.as_ptr(), critical.len()), 2);
        assert_eq!(cmux_host_pressure_tracker_feed(tracker, critical.as_ptr(), critical.len()), -1);
        assert_eq!(cmux_host_pressure_tracker_feed(tracker, b"{}".as_ptr(), 2), -2);
        assert_eq!(cmux_host_pressure_tracker_level(tracker), 2);
        assert_eq!(cmux_host_pressure_tracker_feed(tracker, calm.as_ptr(), calm.len()), 0);
        cmux_host_pressure_tracker_free(tracker);
        assert_eq!(cmux_host_pressure_tracker_level(std::ptr::null()), -2);
        assert_eq!(
            cmux_host_pressure_tracker_feed(std::ptr::null_mut(), calm.as_ptr(), calm.len()),
            -2
        );
        cmux_host_pressure_tracker_free(std::ptr::null_mut());
    }
}

#[test]
fn the_level_for_a_verdict_is_a_number() {
    let warned = verdict(9.0, 1);
    // SAFETY: readable bytes.
    unsafe {
        assert_eq!(cmux_host_pressure_level_for(warned.as_ptr(), warned.len(), 0), 1);
        // 8 is under the 75% line (9), but over it less the deadband (7.8) while raised.
        let held = verdict(8.0, 1);
        assert_eq!(cmux_host_pressure_level_for(held.as_ptr(), held.len(), 0), 0);
        assert_eq!(cmux_host_pressure_level_for(held.as_ptr(), held.len(), 1), 1);
        assert_eq!(cmux_host_pressure_level_for(held.as_ptr(), held.len(), 7), -2);
        assert_eq!(cmux_host_pressure_level_for(b"[]".as_ptr(), 2, 0), -2);
    }
}

#[test]
fn given_numbers_and_this_host_are_judged() {
    let input = br#"{"host":"x","sample":{"load1":15,"logical_cpus":15},"swap_mb_per_min":null}"#;
    // SAFETY: readable bytes.
    let judged = take(unsafe { cmux_host_budget_judge_json(input.as_ptr(), input.len()) }).unwrap();
    assert!(judged.contains(r#""load_limit":15.0"#), "{judged}");
    let local = (0..200)
        .find_map(|_| {
            let text = take(cmux_host_budget_local_verdict_json());
            if text.is_none() {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            text
        })
        .unwrap();
    assert!(crate::json::reading(&local).is_some(), "{local}");
}
