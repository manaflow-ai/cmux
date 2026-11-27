use super::*;
use ratatui::Terminal;
use ratatui::backend::TestBackend;

#[test]
fn active_entry_keeps_the_shared_rail_when_it_has_a_status_indicator() {
    let mut terminal = Terminal::new(TestBackend::new(16, 3)).unwrap();
    let palette = RailPalette {
        base: Style::default(),
        dim: Style::default(),
        active: Style::default().add_modifier(Modifier::BOLD),
        border: Style::default(),
        border_symbol: "│",
        rail: Color::Cyan,
        rail_glyph: Some('▎'),
    };
    terminal
        .draw(|frame| {
            entry(
                frame,
                Rect { x: 0, y: 0, width: 16, height: 3 },
                0,
                Entry {
                    name: "machine",
                    subtitle: "running",
                    highlighted: true,
                    active: true,
                    indicator: Some(Indicator::dot(Color::Green)),
                    dimmed: false,
                },
                palette,
                RailMetrics { height: 2, stride: 3 },
            );
        })
        .unwrap();

    let buffer = terminal.backend().buffer();
    assert_eq!(buffer[(0, 0)].symbol(), "▎");
    assert_eq!(buffer[(0, 1)].symbol(), "▎");
    assert_eq!(buffer[(1, 0)].symbol(), "•");
    assert_eq!(buffer[(3, 0)].symbol(), "m");
    assert_eq!(buffer[(1, 1)].symbol(), "r");
}

#[test]
fn short_viewport_pins_footer_and_keeps_selected_action_visible() {
    let area = Rect { x: 2, y: 3, width: 20, height: 3 };
    let mut body_offset = 0;
    let mut footer_offset = 0;
    let viewport =
        viewport(area, 30, 4, &mut body_offset, &mut footer_offset, None, Some(RowSpan::new(3, 1)));

    assert_eq!(viewport.body.height, 0);
    assert_eq!(viewport.footer.height, 2);
    assert_eq!(viewport.footer.y, 4);
    assert_eq!(viewport.footer_offset, 2);
    assert_eq!(viewport.footer_y(RowSpan::new(3, 1)), Some(5));
}

#[test]
fn resizing_clamps_scroll_without_forgetting_a_visible_selection() {
    let mut body_offset = 12;
    let mut footer_offset = 0;
    let selected = RowSpan::new(15, 2);
    let small = viewport(
        Rect { x: 0, y: 0, width: 20, height: 8 },
        30,
        2,
        &mut body_offset,
        &mut footer_offset,
        Some(selected),
        None,
    );
    assert!(small.body_y(selected).is_some());

    let large = viewport(
        Rect { x: 0, y: 0, width: 20, height: 20 },
        30,
        2,
        &mut body_offset,
        &mut footer_offset,
        Some(selected),
        None,
    );
    assert!(large.body_y(selected).is_some());
    assert_eq!(body_offset, 12);
}
