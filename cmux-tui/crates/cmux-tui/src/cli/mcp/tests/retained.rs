//! What `cmux mcp serve` keeps of the v2 catalog for its whole life. Every agent runs one
//! server, so what the catalog leaves allocated is paid once per agent: parsed into one
//! tree, the ~1 MB catalog held ~17 MB of heap in each (about 160 servers on one Mac held
//! ~2.7 GB). The probe runs in a fresh copy of this test binary, so no other test has
//! filled the catalog first, and counts only its own thread's allocations.

use super::*;
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

thread_local! {
    /// Bytes this thread holds while counting is on (`Some`).
    static LIVE: Cell<Option<isize>> = const { Cell::new(None) };
}

struct LiveBytes;

fn count(delta: isize) {
    let _ = LIVE.try_with(|live| {
        if let Some(value) = live.get() {
            live.set(Some(value.saturating_add(delta)));
        }
    });
}

// Test-only allocator: counting is on per thread, so other tests running meanwhile do
// not change the probe's count.
unsafe impl GlobalAlloc for LiveBytes {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count(layout.size() as isize);
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count(layout.size() as isize);
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        count(-(layout.size() as isize));
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        count(size as isize - layout.size() as isize);
        unsafe { System.realloc(ptr, layout, size) }
    }
}

#[global_allocator]
static ALLOCATOR: LiveBytes = LiveBytes;

const PROBE_ENV: &str = "CMUX_TEST_MCP_RETAINED_PROBE";
const PROBE_LINE: &str = "retained bytes: ";
/// The index and the tool list: a few hundred small entries, far under one parsed tree.
const MAX_RETAINED: isize = 1 << 20;

/// Run only as the child of `listing_every_v2_tool_keeps_no_parsed_catalog`.
#[test]
fn retained_probe() {
    if std::env::var_os(PROBE_ENV).is_none() {
        return;
    }
    LIVE.with(|live| live.set(Some(0)));
    let listed: Vec<Value> = v2_tools::tools().iter().map(|tool| tool.descriptor_json()).collect();
    let schemas: Vec<Value> = v2_tools::tools().iter().map(|tool| tool.input_schema()).collect();
    assert!(!listed.is_empty() && listed.len() == schemas.len());
    drop((listed, schemas));
    let retained = LIVE.with(|live| live.replace(None)).unwrap_or_default();
    println!("{PROBE_LINE}{retained}");
}

#[test]
fn listing_every_v2_tool_keeps_no_parsed_catalog() {
    // The harness names a test by its module path without the crate's name.
    let module = module_path!().split_once("::").map_or(module_path!(), |(_, rest)| rest);
    let output = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args([&format!("{module}::retained_probe"), "--exact", "--nocapture", "--test-threads=1"])
        .env(PROBE_ENV, "1")
        .output()
        .expect("probe ran");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "probe failed: {stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let retained: isize = stdout
        .lines()
        // libtest prints `test <name> ... ` on the line the probe's output follows.
        .find_map(|line| line.split_once(PROBE_LINE).map(|(_, rest)| rest))
        .and_then(|rest| rest.split_whitespace().next()?.parse().ok())
        .unwrap_or_else(|| panic!("no probe result in: {stdout}"));
    assert!(
        retained < MAX_RETAINED,
        "listing every v2 tool left {retained} bytes allocated (at most {MAX_RETAINED}): the \
         catalog must stay an index of raw slices, not a parsed tree"
    );
}
