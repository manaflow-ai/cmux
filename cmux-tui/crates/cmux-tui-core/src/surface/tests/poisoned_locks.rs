//! A thread that panics while it holds a surface lock
//! poisons it; the surface keeps serving its reads and writes instead of
//! turning that one panic into a panic in every later caller.

use super::*;

/// Panic on another thread while `hold` runs with the lock taken.
fn poison_with(hold: impl FnOnce() + Send + 'static) {
    let joined = std::thread::spawn(hold).join();
    assert!(joined.is_err(), "the poisoning thread must panic");
}

#[test]
fn poisoned_title_and_name_locks_keep_serving() {
    let mux = Mux::new_for_test("poisoned-metadata", SurfaceOptions::default());
    let surface = Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux))
        .expect("test PTY should spawn");
    surface.set_name(Some("before".into()));

    let held = surface.clone();
    poison_with(move || {
        let pty = held.as_pty().expect("test PTY surface");
        let mut title = pty.title.lock().recover_poison();
        *title = "kept".into();
        let _name = held.name.lock().recover_poison();
        panic!("poison the title and name locks");
    });
    let pty = surface.as_pty().expect("test PTY surface");
    assert!(pty.title.lock().is_err(), "the title lock is poisoned");
    assert!(surface.name.lock().is_err(), "the name lock is poisoned");

    assert_eq!(surface.title(), "kept", "the title the panicking thread left is served");
    assert_eq!(surface.name().as_deref(), Some("before"));
    surface.set_name(Some("after".into()));
    assert_eq!(surface.name().as_deref(), Some("after"));
}

#[test]
fn poisoned_terminal_lock_keeps_scrolling() {
    let mux = Mux::new_for_test("poisoned-term", SurfaceOptions::default());
    let surface = Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux))
        .expect("test PTY should spawn");

    let held = surface.clone();
    poison_with(move || {
        let _term = held.as_pty().expect("test PTY surface").term.lock().recover_poison();
        panic!("poison the terminal lock");
    });

    let _ = surface.view_scrollbar();
    surface.view_scroll_to_bottom().expect("a poisoned terminal lock still serves a scroll");
}
