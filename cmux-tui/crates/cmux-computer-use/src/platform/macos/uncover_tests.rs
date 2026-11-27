use super::*;
use crate::desktop::Rect;

fn w(id: u32, pid: i32, x: f64) -> CgWindow {
    CgWindow {
        id,
        pid,
        layer: 0,
        frame: Rect { x, y: 0.0, width: 100.0, height: 100.0 },
        title: String::new(),
        on_screen: true,
        alpha: 1.0,
    }
}

#[test]
fn same_app_window_on_top_covers() {
    let stack = [w(1, 7, 0.0), w(2, 9, 0.0), w(3, 7, 0.0)];
    assert_eq!(in_front(&stack, 3), Some((vec![1], true)));
}

#[test]
fn other_app_window_alone_does_not_count() {
    let stack = [w(2, 9, 0.0), w(3, 7, 0.0)];
    assert_eq!(in_front(&stack, 3), Some((vec![], false)));
}

#[test]
fn side_by_side_is_in_front_not_covering() {
    let stack = [w(1, 7, 500.0), w(3, 7, 0.0)];
    assert_eq!(in_front(&stack, 3), Some((vec![1], false)));
}

#[test]
fn helper_windows_are_skipped() {
    let mut tiny = w(1, 7, 0.0);
    tiny.frame.width = 1.0;
    let mut menu = w(2, 7, 0.0);
    menu.layer = 101;
    let stack = [tiny, menu, w(3, 7, 0.0)];
    assert_eq!(in_front(&stack, 3), Some((vec![], false)));
}

#[test]
fn missing_target_is_none() {
    assert_eq!(in_front(&[w(1, 7, 0.0)], 3), None);
}

#[test]
fn restore_raises_back_to_front() {
    assert_eq!(restore_order(&[1, 4, 5]), vec![5, 4, 1]);
}
