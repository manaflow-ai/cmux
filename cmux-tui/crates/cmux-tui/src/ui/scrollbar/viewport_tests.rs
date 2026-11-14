use super::*;

#[test]
fn viewport_thumb_is_absent_when_every_row_is_visible() {
    assert_eq!(viewport_thumb_geometry(8, 8, 0, 6), (0, 0));
    assert_eq!(viewport_thumb_geometry(0, 8, 0, 6), (0, 0));
    assert_eq!(viewport_thumb_geometry(8, 8, 0, 0), (0, 0));
}

#[test]
fn viewport_track_click_and_drag_cover_the_scroll_range() {
    assert_eq!(viewport_jump_offset(30, 6, 6, 0), 0);
    assert_eq!(viewport_jump_offset(30, 6, 6, 5), 24);
    assert_eq!(viewport_drag_offset(30, 6, 6, 0, 5), 24);
    assert_eq!(viewport_drag_offset(30, 6, 6, 24, -5), 0);
}

#[test]
fn shared_style_uses_the_terminal_thumb_glyphs_and_chrome_colors() {
    let chrome = ChromeTheme::dark();
    let style = ScrollbarStyle::from_chrome(chrome);
    let track = Rect { x: 0, y: 0, width: 1, height: 4 };
    let mut buffer = Buffer::empty(ratatui::layout::Rect::new(0, 0, 1, 4));

    style.draw_thumb(&mut buffer, track, (1, 1), Style::default(), ScrollbarState::Idle);
    assert_eq!(buffer[(0, 1)].symbol(), "▕");
    assert_eq!(buffer[(0, 1)].fg, chrome.scrollbar_thumb_fg);

    style.draw_thumb(&mut buffer, track, (2, 1), Style::default(), ScrollbarState::Expanded);
    assert_eq!(buffer[(0, 2)].symbol(), "▐");
    assert_eq!(buffer[(0, 2)].fg, chrome.scrollbar_thumb_active_fg);
}

#[test]
fn shared_style_clips_a_stale_track_to_the_current_buffer() {
    let style = ScrollbarStyle::from_chrome(ChromeTheme::dark());
    let mut buffer = Buffer::empty(ratatui::layout::Rect::new(0, 0, 2, 2));
    let stale_track = Rect { x: 1, y: 1, width: 1, height: 4 };

    style.draw_thumb(&mut buffer, stale_track, (0, 4), Style::default(), ScrollbarState::Idle);

    assert_eq!(buffer[(1, 1)].symbol(), "▕");
    assert_eq!(buffer[(0, 0)].symbol(), " ");
}
