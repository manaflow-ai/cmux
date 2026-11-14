#[test]
fn loopback_forward_lines_use_the_bulk_lane_in_both_directions() {
    for line in [
        &br#"{"id":1,"cmd":"loopback-open","stream":1,"host":"localhost","port":3000}"#[..],
        br#"{"cmd":"loopback-data","stream":1,"data":"eA=="}"#,
        br#"{"cmd":"loopback-credit","stream":1,"bytes":65536}"#,
        br#"{"cmd":"loopback-shutdown","stream":1}"#,
        br#"{"cmd":"loopback-close","stream":1}"#,
    ] {
        assert_eq!(classify_client_line(line), Lane::Bulk);
    }
    let tracker = MuxLaneTracker::default();
    for line in [
        &br#"{"event":"loopback-data","stream":1,"data":"eA=="}"#[..],
        br#"{"event":"loopback-credit","stream":1,"bytes":65536}"#,
        br#"{"event":"loopback-eof","stream":1}"#,
        br#"{"event":"loopback-closed","stream":1}"#,
    ] {
        assert_eq!(tracker.classify_server_line(line), Some(Lane::Bulk));
    }
    tracker.observe_request(br#"{"id":7,"cmd":"loopback-open"}"#, Lane::Bulk);
    assert_eq!(tracker.classify_server_line(br#"{"id":7,"ok":true}"#), Some(Lane::Bulk));
}

#[test]
fn agent_transfer_pages_use_the_bulk_lane() {
    for line in [
            &br#"{"id":1,"cmd":"agent-transfer-write","receive_id":"r","path":"a","offset":0,"data":""}"#[..],
            br#"{"id":2,"cmd":"agent-transfer-read","transfer_id":"t","path":"a","offset":0}"#,
        ] {
            assert_eq!(classify_client_line(line), Lane::Bulk);
        }
}

#[test]
fn agent_session_attach_lines_use_the_bulk_lane_in_both_directions() {
    for line in [
        &br#"{"id":1,"cmd":"agent-session-attach","surface":3}"#[..],
        br#"{"id":2,"cmd":"agent-session-events","surface":3,"after_seq":9}"#,
        br#"{"id":3,"cmd":"agent-session-prompt","surface":3,"prompt_id":"p","text":"hi"}"#,
        br#"{"id":4,"cmd":"agent-session-detach","surface":3}"#,
    ] {
        assert_eq!(classify_client_line(line), Lane::Bulk);
    }
    let tracker = MuxLaneTracker::default();
    for line in [
        &br#"{"event":"agent-session-record","surface":3,"record":{"seq":2}}"#[..],
        br#"{"event":"agent-session-permission","surface":3,"request":{}}"#,
        br#"{"event":"agent-session-closed","surface":3,"reason":"lagged"}"#,
    ] {
        assert_eq!(tracker.classify_server_line(line), Some(Lane::Bulk));
    }
    tracker.observe_request(br#"{"id":1,"cmd":"agent-session-attach"}"#, Lane::Bulk);
    assert_eq!(tracker.classify_server_line(br#"{"id":1,"ok":true}"#), Some(Lane::Bulk));
}

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use super::*;

struct CountingAllocator;

std::thread_local! {
    static COUNT_ALLOCATIONS: Cell<bool> = const { Cell::new(false) };
    static ALLOCATION_COUNT: Cell<usize> = const { Cell::new(0) };
}

// Rust installs this allocator for the whole cmux-remote unit-test binary;
// thread-local counting keeps unrelated test threads out of each sample.
#[global_allocator]
static TEST_ALLOCATOR: CountingAllocator = CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        COUNT_ALLOCATIONS
            .try_with(|enabled| {
                if enabled.get() {
                    ALLOCATION_COUNT.with(|count| count.set(count.get().saturating_add(1)));
                }
            })
            .ok();
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        COUNT_ALLOCATIONS
            .try_with(|enabled| {
                if enabled.get() {
                    ALLOCATION_COUNT.with(|count| count.set(count.get().saturating_add(1)));
                }
            })
            .ok();
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) };
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        COUNT_ALLOCATIONS
            .try_with(|enabled| {
                if enabled.get() {
                    ALLOCATION_COUNT.with(|count| count.set(count.get().saturating_add(1)));
                }
            })
            .ok();
        unsafe { System.realloc(pointer, layout, new_size) }
    }
}

#[test]
fn keystrokes_and_terminal_output_use_distinct_lanes() {
    let tracker = MuxLaneTracker::default();
    let request = br#"{"id":7,"cmd":"send","surface":1,"bytes":"YQ=="}"#;
    let lane = classify_client_line(request);
    assert_eq!(lane, Lane::Interactive);
    tracker.observe_request(request, lane);
    assert_eq!(tracker.classify_server_line(br#"{"id":7,"ok":true}"#), Some(Lane::Interactive));
    assert_eq!(
        tracker.classify_server_line(br#"{"event":"output","surface":1,"data":"Yg=="}"#),
        Some(Lane::Bulk)
    );
}

#[test]
fn snapshot_and_digest_share_the_output_lane() {
    let tracker = MuxLaneTracker::default();
    let output = br#"{"event":"output","surface":1,"data":"Yg==","generation":2,"offset":9}"#;
    let output = tracker.classify_server_line(output);
    assert_eq!(output, Some(Lane::Bulk));
    for line in [
            &br#"{"event":"snapshot","surface":1,"phase":"ready","generation":2,"offset":9,"version":1,"cols":80,"rows":24,"data":""}"#[..],
            br#"{"event":"snapshot","surface":1,"phase":"history","generation":2,"offset":9,"version":1,"compression":"deflate","raw_bytes":0,"data":"","done":true}"#,
            br#"{"event":"digest","surface":1,"generation":2,"offset":9,"version":1,"sha256":"00"}"#,
        ] {
            let lane = tracker.classify_server_line(line);
            assert_eq!(lane, output, "{}", String::from_utf8_lossy(line));
        }
    // The attach reply that starts the stream rides the same lane too.
    let attach = br#"{"id":3,"cmd":"attach-surface","surface":1}"#;
    let lane = classify_client_line(attach);
    tracker.observe_request(attach, lane);
    assert_eq!(tracker.classify_server_line(br#"{"id":3,"ok":true}"#), output);
}
