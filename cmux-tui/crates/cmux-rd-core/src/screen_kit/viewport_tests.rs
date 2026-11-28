use super::*;

const VIEW: Size = Size::new(400.0, 800.0);

#[test]
fn fit_and_centre() {
    let rect = Rect::new(0.0, 0.0, 1600.0, 1000.0);
    assert_eq!(fit_scale(rect, VIEW), 0.25);
    assert_eq!(fit_scale(Rect::ZERO, VIEW), 1.0);
    let offset = centered_offset(rect, 0.25, VIEW);
    assert_eq!(offset, Point::new(0.0, -(800.0 - 250.0) / 2.0));
    let second = Rect::new(1600.0, 0.0, 1600.0, 1000.0);
    assert_eq!(centered_offset(second, 0.25, VIEW).x, 400.0);
    assert_eq!(maximum_zoom(0.25), 2.0);
    assert_eq!(maximum_zoom(0.5), 3.0);
    assert!(same_zoom(0.25, 0.2505) && !same_zoom(0.25, 0.252));
}

#[test]
fn clamping_centres_a_small_axis_and_bounds_a_large_one() {
    let rect = Rect::new(0.0, 0.0, 1600.0, 1000.0);
    // At 1: wider and taller than the view.
    let clamped = clamped_offset(Point::new(-50.0, 5000.0), rect, 1.0, VIEW, false);
    assert_eq!(clamped, Point::new(0.0, 200.0));
    assert_eq!(clamped_offset(Point::new(5000.0, 0.0), rect, 1.0, VIEW, false).x, 1200.0);
    assert_eq!(
        clamped_offset(Point::new(-50.0, 0.0), rect, 1.0, VIEW, true).x,
        -50.0,
        "paging leaves x free"
    );
    // At fit: the height is smaller than the view, centred.
    assert_eq!(clamped_offset(Point::new(0.0, 0.0), rect, 0.25, VIEW, false).y, -275.0);
}

#[test]
fn a_swipe_pages_by_speed_or_distance() {
    assert_eq!(page_target(0, 3, 0.5, 0.0, 400.0), 1);
    assert_eq!(page_target(0, 3, 0.0, 101.0, 400.0), 1);
    assert_eq!(page_target(0, 3, 0.0, 99.0, 400.0), 0);
    assert_eq!(page_target(2, 3, 1.0, 0.0, 400.0), 2, "the last page stays");
    assert_eq!(page_target(1, 3, -0.5, 0.0, 400.0), 0);
    assert_eq!(page_target(0, 3, -0.5, 0.0, 400.0), 0);
    assert_eq!(page_target(1, 3, 0.0, -101.0, 400.0), 0);
    assert_eq!(page_target(0, 0, 1.0, 0.0, 400.0), 0);
}

#[test]
fn the_first_page_is_the_main_display() {
    let screens = [Rect::new(-1920.0, 0.0, 1920.0, 1080.0), Rect::new(0.0, 0.0, 1512.0, 982.0)];
    assert_eq!(initial_page(&screens), 1);
    assert_eq!(initial_page(&[Rect::new(5.0, 0.0, 1.0, 1.0)]), 0);
}

#[test]
fn insets_centre_or_letterbox() {
    assert_eq!(
        content_insets(true, VIEW, Size::new(10.0, 10.0)),
        Insets { top: 800.0, left: 400.0, bottom: 800.0, right: 400.0 }
    );
    assert_eq!(
        content_insets(false, VIEW, Size::new(300.0, 1000.0)),
        Insets { top: 0.0, left: 50.0, bottom: 0.0, right: 50.0 }
    );
}

#[test]
fn scrolling_keeps_the_remainder() {
    let mut q = ScrollQuantizer::default();
    assert_eq!(q.scroll(Point::new(10.0, -10.0), false, 1.0), (0, 0));
    assert_eq!(q.scroll(Point::new(10.0, -10.0), false, 1.0), (1, -1));
    assert_eq!(q.remainder, Point::new(2.0, -2.0));
    q.reset();
    assert_eq!(q.scroll(Point::new(1.3, 0.2), true, 2.0), (2, 0));
    assert!((q.remainder.x - 0.3).abs() < 1e-9 && (q.remainder.y - 0.2).abs() < 1e-9);
    assert_eq!(pixels_per_point(0.5), 2.0);
    assert_eq!(pixels_per_point(0.0), 100.0);
}

#[test]
fn the_cursor_stays_in_view_and_on_its_display() {
    // margin = 48 on a 400-wide view.
    assert_eq!(
        follow_cursor(Point::new(0.0, 0.0), Point::new(200.0, 400.0), VIEW),
        Point::new(0.0, 0.0)
    );
    assert_eq!(
        follow_cursor(Point::new(0.0, 0.0), Point::new(390.0, 10.0), VIEW),
        Point::new(38.0, -38.0)
    );
    let insets = Insets { top: 10.0, left: 10.0, bottom: 10.0, right: 10.0 };
    let content = Size::new(1000.0, 1000.0);
    assert_eq!(
        clamp_to_content(Point::new(-50.0, 900.0), insets, content, VIEW),
        Point::new(-10.0, 210.0)
    );
    let rect = Rect::new(100.0, 0.0, 50.0, 50.0);
    assert_eq!(clamp_to_rect(Point::new(0.0, 80.0), rect), Point::new(100.0, 49.0));
    assert_eq!(clamp_to_rect(Point::new(3.0, 3.0), Rect::ZERO), Point::new(0.0, 0.0));
}

#[test]
fn layout_demand_and_pointer() {
    let display = Size::new(3024.0, 1964.0);
    assert_eq!(stream_layout_size(Size::new(1512.0, 982.0), Some(display)), display);
    assert_eq!(
        stream_layout_size(Size::new(1000.0, 1000.0), Some(display)),
        Size::new(1000.0, 1000.0)
    );
    assert_eq!(stream_layout_size(Size::new(1512.0, 982.0), None), Size::new(1512.0, 982.0));
    assert_eq!(demand_long_edge(Size::new(1512.0, 982.0), 0.26, 3.0), 1180);
    assert_eq!(normalized(Point::new(50.0, 25.0), Size::new(100.0, 0.0)), Point::new(0.5, 25.0));
    assert_eq!(
        clamp_to_frame(Point::new(-5.0, 500.0), Size::new(100.0, 100.0)),
        Point::new(0.0, 99.0)
    );
}
