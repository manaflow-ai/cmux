//! Validating a manifest keeps a compiled schema validator alive for the
//! whole daemon. Every cmux-tui daemon validates the first-party apps at
//! startup, so the memory that validator retains is paid by each daemon
//! (two per cmux NEXT window). jsonschema 0.30 cloned the `$ref` subtrees of
//! the v2 schema into about 200 MB; this pins the retained cost low.

use std::alloc::{GlobalAlloc, Layout, System};
use std::path::Path;
use std::sync::atomic::{AtomicIsize, Ordering};

use cmux_app_manifest::validate_package_file;

struct Counting;

static LIVE: AtomicIsize = AtomicIsize::new(0);

// SAFETY: forwards to the system allocator and only counts bytes.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LIVE.fetch_add(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        LIVE.fetch_add(new_size as isize - layout.size() as isize, Ordering::Relaxed);
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    // The only test in this binary: another test validating first would
    // build the validator before `before` is read and hide its cost.
    #[test]
    fn validating_a_manifest_retains_under_32_mib() {
        let sample =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../samples/apps/agent-status");
        let before = LIVE.load(Ordering::Relaxed);
        let report = validate_package_file(&sample, "cmux-app.v2.json");
        assert!(report.is_valid(), "{:?}", report.issues);
        drop(report);
        let retained = LIVE.load(Ordering::Relaxed) - before;
        assert!(retained < 32 << 20, "manifest validation retained {} MiB", retained >> 20);
    }
}
