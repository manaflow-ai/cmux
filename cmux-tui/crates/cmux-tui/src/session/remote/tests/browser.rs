//! Remote browser frames, state, and pointer authority.

use super::*;

#[test]
fn browser_state_cannot_grant_new_authority_to_cached_pixels() {
    let surface = RemoteSurface {
        id: 1,
        kind: SurfaceKind::Browser,
        term: Mutex::new(Terminal::new(10, 5, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    };
    surface.update_browser_frame(&json!({
        "seq": 8,
        "width": 80,
        "height": 40,
        "data": "b2xk",
        "status": "live",
        "pointer_frame_seq": 8,
    }));
    surface.update_browser_state(&json!({
        "url": "https://old.test",
        "title": "same document",
        "status": "live",
        "frames_stalled": false,
        "pointer_frame_seq": 8,
    }));
    assert_eq!(
        surface.browser_frame_seq(),
        Some(8),
        "state may retain authority already paired with the cached pixels"
    );

    surface.update_browser_state(&json!({
        "url": "https://new.test",
        "title": "new document",
        "status": "live",
        "frames_stalled": false,
        "pointer_frame_seq": 9,
    }));
    assert_eq!(surface.browser_frame().map(|frame| frame.seq), Some(8));
    assert_eq!(
        surface.browser_frame_seq(),
        None,
        "state must not authorize old pixels with a token belonging to a delayed frame"
    );

    surface.update_browser_frame(&json!({
        "seq": 9,
        "width": 80,
        "height": 40,
        "data": "bmV3",
        "status": "live",
        "pointer_frame_seq": 9,
    }));
    assert_eq!(surface.browser_frame().map(|frame| frame.seq), Some(9));
    assert_eq!(surface.browser_frame_seq(), Some(9));
}

#[test]
fn browser_pointer_range_does_not_authorize_unacknowledged_presentations() {
    let surface = RemoteSurface {
        id: 1,
        kind: SurfaceKind::Browser,
        term: Mutex::new(Terminal::new(10, 5, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    };
    surface.update_browser_frame(&json!({
        "seq": 9,
        "width": 80,
        "height": 40,
        "data": "bmV3",
        "status": "live",
        "pointer_frame_floor_seq": 8,
        "pointer_frame_seq": 9,
    }));

    assert!(
        !surface.browser_accepts_pointer_frame(8),
        "route membership must not imply that the client presented an older frame"
    );
    assert!(
        !surface.browser_accepts_pointer_frame(9),
        "receiving a frame must not acknowledge its presentation"
    );
    assert!(!surface.browser_accepts_pointer_frame(7));
    assert!(!surface.browser_accepts_pointer_frame(10));

    assert!(surface.acknowledge_browser_pointer_frame(8));
    assert!(surface.browser_accepts_pointer_frame(8));
    assert!(!surface.browser_accepts_pointer_frame(9));

    surface.update_browser_frame(&json!({
        "seq": 10,
        "width": 80,
        "height": 40,
        "data": "bmV3ZXN0",
        "status": "live",
        "pointer_frame_floor_seq": 8,
        "pointer_frame_seq": 10,
    }));
    assert!(
        surface.browser_accepts_pointer_frame(8),
        "receiving a repaint must preserve the exact frame still on screen"
    );
    assert!(surface.acknowledge_browser_pointer_frame(10));
    assert!(!surface.browser_accepts_pointer_frame(8));
    assert!(surface.browser_accepts_pointer_frame(10));
    assert!(
        !surface.acknowledge_browser_pointer_frame(9),
        "a delayed acknowledgement must not roll authority backward"
    );
}

#[test]
fn stale_frame_does_not_restore_failed_browser_pointer_admission() {
    let surface = RemoteSurface {
        id: 1,
        kind: SurfaceKind::Browser,
        term: Mutex::new(Terminal::new(10, 5, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    };
    surface.update_browser_state(&json!({
        "url": "https://failed.test",
        "title": "browser failed: navigation failed",
        "status": "failed",
        "error": "navigation failed",
        "frames_stalled": false,
        "pointer_frame_seq": null,
    }));

    surface.update_browser_frame(&json!({
        "seq": 9,
        "width": 80,
        "height": 40,
        "data": "c3RhbGU=",
        "status": "failed",
        "error": "navigation failed",
        "pointer_frame_seq": null,
    }));

    assert!(
        matches!(surface.browser_status(), BrowserStatus::Failed(ref error) if error == "navigation failed"),
        "a stale screencast frame must not hide the authoritative navigation failure"
    );
    assert_eq!(
        surface.browser_frame_seq(),
        None,
        "a stale failed-navigation frame must remain pointer-ineligible"
    );
    assert_eq!(
        surface.browser.lock().unwrap().frame.as_ref().map(|frame| frame.frame.seq),
        Some(9),
        "the stale frame may remain cached for a later explicit recovery"
    );

    surface.update_browser_frame(&json!({
        "seq": 10,
        "width": 80,
        "height": 40,
        "data": "ZnJlc2g=",
        "status": "live",
        "error": null,
        "pointer_frame_seq": 10,
    }));
    assert_eq!(surface.browser_status(), BrowserStatus::Live);
    assert_eq!(
        surface.browser_frame_seq(),
        Some(10),
        "explicit live frame metadata must restore pointer admission"
    );
}
