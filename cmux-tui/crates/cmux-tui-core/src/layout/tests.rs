use super::*;

#[test]
fn zero_extent_terminal_splits_preserve_empty_rect() {
    for dir in [SplitDir::Right, SplitDir::Down] {
        let area = Rect { x: u16::MAX, y: u16::MAX, width: 0, height: 0 };
        let (first, second) = split_sides(area, dir, 0.5);

        assert_eq!(first, area);
        assert_eq!(second, area);
    }
}

#[test]
fn zero_extent_virtual_splits_preserve_empty_rect() {
    for dir in [SplitDir::Right, SplitDir::Down] {
        let area = VirtualRect { x: u64::MAX, y: u16::MAX, width: 0, height: 0 };
        let (first, second) = split_virtual_sides(area, dir, 0.5);

        assert_eq!(first, area);
        assert_eq!(second, area);
    }
}
