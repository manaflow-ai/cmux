use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-cu-swap-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A new file renamed over `path`, as a stager swaps a verified copy in.
fn replace(path: &Path, content: &str) {
    let next = path.with_extension("next");
    std::fs::write(&next, content).unwrap();
    std::fs::rename(&next, path).unwrap();
}

fn counting() -> (Arc<AtomicUsize>, impl Fn() + Send + Sync + 'static) {
    let fired = Arc::new(AtomicUsize::new(0));
    let hook = Arc::clone(&fired);
    (fired, move || {
        hook.fetch_add(1, Ordering::SeqCst);
    })
}

#[test]
fn a_replaced_helper_refuses_new_calls_and_drains_the_running_one_first() {
    let dir = scratch("drain");
    let exe = dir.join("cmux-screen-sharing");
    std::fs::write(&exe, "old").unwrap();
    let (fired, hook) = counting();
    let swap = Swap::new(exe.clone(), hook);
    // Unchanged: every call is admitted.
    let in_flight = swap.enter().expect("admitted");
    drop(swap.enter().expect("admitted"));
    assert_eq!(fired.load(Ordering::SeqCst), 0);
    replace(&exe, "the new helper");
    assert!(swap.replaced());
    // The next call goes to the new worker (refused here), while the in-flight one runs on.
    assert!(swap.enter().is_none());
    assert!(swap.enter().is_none());
    assert_eq!(fired.load(Ordering::SeqCst), 0, "a call is still running");
    drop(in_flight);
    assert_eq!(fired.load(Ordering::SeqCst), 1);
    // Once, however many calls come after.
    assert!(swap.enter().is_none());
    assert_eq!(fired.load(Ordering::SeqCst), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_replaced_helper_with_no_call_running_hands_over_on_the_next_call() {
    let dir = scratch("idle");
    let exe = dir.join("cmux-screen-sharing");
    std::fs::write(&exe, "old").unwrap();
    let (fired, hook) = counting();
    let swap = Swap::new(exe.clone(), hook);
    replace(&exe, "the new helper");
    // Nothing happens until a call comes: no watcher thread.
    assert_eq!(fired.load(Ordering::SeqCst), 0);
    assert!(swap.enter().is_none());
    assert_eq!(fired.load(Ordering::SeqCst), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_missing_or_unchanged_executable_keeps_serving() {
    let dir = scratch("missing");
    let exe = dir.join("cmux-screen-sharing");
    std::fs::write(&exe, "old").unwrap();
    let (fired, hook) = counting();
    let swap = Swap::new(exe.clone(), hook);
    assert!(!swap.replaced());
    std::fs::remove_file(&exe).unwrap();
    assert!(swap.enter().is_some());
    // No file when the worker started: nothing to compare, never replaced.
    let (_, hook) = counting();
    let none = Swap::new(dir.join("absent"), hook);
    std::fs::write(dir.join("absent"), "x").unwrap();
    assert!(none.enter().is_some());
    assert_eq!(fired.load(Ordering::SeqCst), 0);
    let _ = std::fs::remove_dir_all(&dir);
}
