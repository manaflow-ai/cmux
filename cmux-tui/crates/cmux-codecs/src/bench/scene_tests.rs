use super::*;

#[test]
fn scenes_change_and_repeat() {
    for kind in SceneKind::ALL {
        let mut a = Scene::new(kind, 640, 360, 7);
        let mut b = Scene::new(kind, 640, 360, 7);
        let first = a.picture().clone();
        // The page scene holds each page for PAGE_FRAMES frames; the others move every frame.
        let steps = if kind == SceneKind::Page { PAGE_FRAMES } else { 1 };
        for _ in 0..steps {
            a.advance();
            b.advance();
        }
        assert_eq!(a.picture(), b.picture(), "{} is deterministic", kind.name());
        assert_ne!(&first, a.picture(), "{} changes within {steps} frames", kind.name());
    }
}
