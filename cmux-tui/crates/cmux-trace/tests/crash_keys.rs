//! The crash-key page of a whole process ([`cmux_trace::crash_keys`]): a child of this test binary
//! sets keys inside a trace scope and a request and calls `abort()`; the page it leaves decodes.
//! Each case runs in a child, so each starts with fresh globals.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::path::{Path, PathBuf};

use cmux_trace::crash_keys::{self, HolderLink, Key};
use cmux_trace::{Role, trace_scope};

struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator; the counter is a const-initialised thread-local Cell.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

/// The method keys the child names (any nonzero numbers: the page stores what it is given).
const EARLY_METHOD: u64 = 0x1111;
const CRASHING_METHOD: u64 = 0xdead_beef_cafe;

fn scratch_dir(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-trace-crash-keys-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn run_child(mode: &str, dir: &Path) -> std::process::ExitStatus {
    std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args(["--exact", "crash_keys_child", "--nocapture", "--test-threads=1"])
        .env("CMUX_TRACE_TEST_CHILD", mode)
        .env("CMUX_TRACE_TEST_DIR", dir)
        .status()
        .expect("runs the child")
}

/// The child half (does nothing in a normal run).
#[test]
fn crash_keys_child() {
    let (Some(mode), Some(dir)) =
        (std::env::var_os("CMUX_TRACE_TEST_CHILD"), std::env::var_os("CMUX_TRACE_TEST_DIR"))
    else {
        return;
    };
    match mode.to_str() {
        Some("abort") => child_abort(Path::new(&dir)),
        other => panic!("unknown child mode {other:?}"),
    }
}

fn child_abort(dir: &Path) {
    // Keys set before the page has its file reach the file.
    crash_keys::set_holder_link(HolderLink::Linked);
    crash_keys::increment(Key::TerminalCount);
    let early = crash_keys::request(EARLY_METHOD);
    let open = cmux_trace::init_blackbox(dir, Role::Daemon).expect("first init");
    open.wait().expect("the black box moved into its file");
    assert!(crash_keys::page_path().is_some_and(Path::exists), "no page file");
    drop(early);
    crash_keys::increment(Key::TerminalCount);
    crash_keys::increment(Key::TerminalCount);
    crash_keys::decrement(Key::TerminalCount);

    let before = ALLOCATIONS.with(Cell::get);
    let _scope = trace_scope!(daemon, "daemon.request", 1u64, 2u64);
    let _request = crash_keys::request(CRASHING_METHOD);
    crash_keys::set_holder_link(HolderLink::Lost);
    assert_eq!(ALLOCATIONS.with(Cell::get), before, "setting crash keys allocated");
    std::process::abort();
}

#[cfg(unix)]
#[test]
fn crash_keys_page_decodes_after_an_abort_inside_a_scope() {
    let dir = scratch_dir("abort");
    assert!(!run_child("abort", &dir).success(), "the child was meant to abort");
    let pages: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("lists")
        .map(|entry| entry.expect("entry").path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "crashkeys"))
        .collect();
    assert_eq!(pages.len(), 1, "expected one page, got {pages:?}");
    let keys = crash_keys::decode(&std::fs::read(&pages[0]).expect("reads")).expect("decodes");
    assert_eq!(Role::from_raw(keys.role), Some(Role::Daemon));
    assert_ne!(keys.pid, std::process::id());
    assert_eq!(
        pages[0].file_name().and_then(|name| name.to_str()),
        Some(crash_keys::page_file_name(Role::Daemon, keys.pid).as_str())
    );
    assert_eq!(keys.build_version, cmux_trace::build_version());
    assert!(!keys.build_version_text().is_empty());
    assert_eq!(keys.build_uuid, cmux_trace::build_uuid(), "the same binary");
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    assert_ne!(keys.process_start_unix_us, 0, "the page has no process start");
    assert_eq!(keys.request_method, CRASHING_METHOD);
    assert_eq!(
        keys.requests_in_flight().collect::<Vec<_>>(),
        [CRASHING_METHOD],
        "the finished request is still named, or the crashing one is not"
    );
    assert_eq!(keys.requests_untracked, 0);
    assert_eq!(keys.terminal_count, 2);
    assert_eq!(HolderLink::from_raw(keys.holder_link), Some(HolderLink::Lost));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn crash_keys_without_a_file_stay_in_memory() {
    assert!(crash_keys::page_path().is_none());
    crash_keys::set(Key::RequestMethod, 5);
    assert_eq!(crash_keys::get(Key::RequestMethod), 5);
    crash_keys::decrement(Key::TerminalCount);
    assert_eq!(crash_keys::get(Key::TerminalCount), 0, "a count never goes below 0");
}
