use super::*;

#[test]
fn rects_follow_core_graphics() {
    let a = Rect::new(0.0, 0.0, 10.0, 10.0);
    let b = Rect::new(10.0, 0.0, 5.0, 5.0);
    // Touching edges meet in an empty rect, which does not intersect.
    assert_eq!(a.intersection(&b), Some(Rect::new(10.0, 0.0, 0.0, 5.0)));
    assert!(!a.intersects(&b));
    assert_eq!(a.intersection(&Rect::new(11.0, 0.0, 1.0, 1.0)), None);
    assert_eq!(a.union(&b), Rect::new(0.0, 0.0, 15.0, 10.0));
    assert!(a.contains(Point { x: 0.0, y: 0.0 }));
    assert!(!a.contains(Point { x: 10.0, y: 5.0 }));
    assert_eq!(a.inset(-2.0, -2.0), Some(Rect::new(-2.0, -2.0, 14.0, 14.0)));
    assert_eq!(a.inset(6.0, 0.0), None);
}
