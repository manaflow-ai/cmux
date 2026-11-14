use super::*;

#[test]
fn overlapping_copy_scrolls_up() {
    let mut fb = Framebuffer::new(1, 3).unwrap();
    fb.fill(&Rect::new(0, 0, 1, 1), [1, 0, 0, 255]).unwrap();
    fb.fill(&Rect::new(0, 1, 1, 1), [2, 0, 0, 255]).unwrap();
    fb.fill(&Rect::new(0, 2, 1, 1), [3, 0, 0, 255]).unwrap();
    fb.copy(0, 1, &Rect::new(0, 0, 1, 2)).unwrap();
    assert_eq!(fb.pixels()[0], 2);
    assert_eq!(fb.pixels()[4], 3);
    assert_eq!(fb.pixels()[8], 3);
}

#[test]
fn rectangles_outside_are_refused() {
    let fb = Framebuffer::new(10, 10).unwrap();
    assert!(fb.check(&Rect::new(5, 5, 5, 5)).is_ok());
    assert!(fb.check(&Rect::new(5, 5, 6, 5)).is_err());
    assert!(fb.check(&Rect::new(u16::MAX, 0, 2, 1)).is_err());
    assert!(Framebuffer::new(MAX_SIDE + 1, 1).is_err());
}

#[test]
fn vnc_zero_sized_framebuffers_are_refused() {
    for (width, height) in [(0, 1), (1, 0), (0, 0)] {
        assert!(matches!(Framebuffer::new(width, height), Err(VncError::Protocol(_))));
        let mut fb = Framebuffer::new(2, 2).unwrap();
        let pixels = fb.pixels().to_vec();
        assert!(matches!(fb.resize(width, height), Err(VncError::Protocol(_))));
        assert_eq!((fb.width(), fb.height()), (2, 2));
        assert_eq!(fb.pixels(), pixels);
    }
}

#[test]
fn union_covers_both() {
    let a = Rect::new(0, 0, 2, 2);
    let b = Rect::new(5, 6, 1, 1);
    assert_eq!(a.union(&b), Rect::new(0, 0, 6, 7));
    assert_eq!(Rect::default().union(&b), b);
}
