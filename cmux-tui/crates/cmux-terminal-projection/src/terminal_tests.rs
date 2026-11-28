use super::*;

fn feed(term: &mut Terminal, text: &str) {
    for &b in text.as_bytes() {
        term.advance(b);
    }
}

fn text(term: &Terminal, row: &Row) -> String {
    row.cells
        .iter()
        .filter(|c| c.kind != WIDE_TAIL && c.kind != SPACER_HEAD)
        .map(|c| if c.ch == 0 { " ".to_string() } else { term.cell_text(*c) })
        .collect::<String>()
        .trim_end()
        .to_string()
}

#[test]
fn autowrap_marks_the_row() {
    let mut term = Terminal::new(5, 3, 100);
    feed(&mut term, "abcdefg");
    assert!(term.primary[0].wrapped);
    assert!(!term.primary[1].wrapped);
    assert_eq!(text(&term, &term.primary[0]), "abcde");
    assert_eq!(text(&term, &term.primary[1]), "fg");
    assert_eq!(term.primary_cursor(), (2, 1));
}

#[test]
fn rows_scroll_into_history() {
    let mut term = Terminal::new(10, 2, 100);
    feed(&mut term, "one\r\ntwo\r\nthree");
    assert_eq!(term.history.len(), 1);
    assert_eq!(text(&term, &term.history[0]), "one");
    assert_eq!(text(&term, &term.primary[1]), "three");
}

#[test]
fn wide_glyph_at_the_edge_wraps_with_a_spacer_head() {
    let mut term = Terminal::new(5, 3, 100);
    feed(&mut term, "abcd世");
    assert_eq!(term.primary[0].cells[4].kind, SPACER_HEAD);
    assert!(term.primary[0].wrapped);
    assert_eq!(term.primary[1].cells[0].kind, WIDE);
}

#[test]
fn cursor_reports_are_answered_in_host_cells() {
    let mut term = Terminal::new(80, 24, 100);
    feed(&mut term, "\x1b[5;9H\x1b[6n");
    assert_eq!(term.replies, b"\x1b[5;9R");
    assert!(term.passthrough.is_empty());
}

#[test]
fn key_modes_are_passed_on() {
    let mut term = Terminal::new(80, 24, 100);
    feed(&mut term, "\x1b[?2004h\x1b[?1h\x1b[>1u\x1b]0;title\x07\x1b[?25l");
    assert_eq!(term.passthrough, b"\x1b[?2004h\x1b[?1h\x1b[>1u\x1b]0;title\x07");
    assert!(!term.cursor_visible);
}

#[test]
fn alternate_screen_keeps_the_primary() {
    let mut term = Terminal::new(10, 3, 100);
    feed(&mut term, "shell$ \x1b[?1049h\x1b[2Jvim\x1b[?1049l");
    assert!(!term.is_alternate());
    assert_eq!(text(&term, &term.primary[0]), "shell$");
    assert_eq!(term.primary_cursor(), (7, 0));
}

#[test]
fn erase_display_clears_in_place_as_ghostty_does() {
    // No OSC 133 marks: `ED 2` is a plain clear (the rows do not go to
    // the scrollback), as Ghostty's.
    let mut term = Terminal::new(10, 3, 100);
    feed(&mut term, "a\r\nb\x1b[H\x1b[2J$ ");
    assert!(term.history.is_empty());
    assert_eq!(text(&term, &term.primary[0]), "$");
    // Kitty's scroll-clear moves them first.
    feed(&mut term, "\r\nc\x1b[H\x1b[22J");
    assert_eq!(term.history.len(), 2);
    feed(&mut term, "\x1b[3J");
    assert!(term.history.is_empty());
    assert!(term.reset_needed);
}

#[test]
fn erase_display_at_a_marked_prompt_scrolls_into_history() {
    // Ctrl+L at a prompt the shell marked (OSC 133): the screen goes to
    // the scrollback first, as Ghostty's "clearing at a prompt".
    let mut term = Terminal::new(10, 3, 100);
    feed(&mut term, "out\r\n\x1b]133;A\x07$ \x1b]133;B\x07\x1b[H\x1b[2J");
    assert_eq!(term.history.len(), 2);
    // Output after the prompt (the command ran): a plain clear again.
    let mut term = Terminal::new(10, 3, 100);
    feed(&mut term, "\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07file\x1b[H\x1b[2J");
    assert!(term.history.is_empty());
}

#[test]
fn split_utf8_and_sequences_across_chunks() {
    let mut term = Terminal::new(10, 3, 100);
    let bytes = "\x1b[31mé世".as_bytes();
    for &b in bytes {
        term.advance(b);
    }
    assert_eq!(text(&term, &term.primary[0]), "é世");
    assert_eq!(term.styles.get(term.primary[0].cells[0].style).fg, crate::style::Color::Indexed(1));
}

#[test]
fn combining_marks_join_the_previous_glyph() {
    let mut term = Terminal::new(10, 3, 100);
    feed(&mut term, "e\u{301}x");
    assert_eq!(text(&term, &term.primary[0]), "e\u{301}x");
    assert_eq!(term.primary_cursor(), (2, 0));
}

/// The glyphs of row `y` as (text, wide), blanks skipped.
fn glyphs(term: &Terminal, y: usize) -> Vec<(String, bool)> {
    term.primary[y]
        .cells
        .iter()
        .filter(|c| c.ch != 0 && c.kind != WIDE_TAIL)
        .map(|c| (term.cell_text(*c), c.kind == WIDE))
        .collect()
}

#[test]
fn grapheme_clusters_are_one_glyph_as_in_ghostty() {
    let mut term = Terminal::new(20, 3, 100);
    feed(
        &mut term,
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}",
    );
    assert_eq!(
        glyphs(&term, 0),
        vec![
            ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".to_string(), true),
            ("x".to_string(), false),
            ("\u{1F1EF}\u{1F1F5}".to_string(), true),
            ("\u{1F1FA}\u{1F1F8}".to_string(), true),
        ]
    );
    assert_eq!(term.primary_cursor(), (7, 0));
}

#[test]
fn variation_selectors_set_the_glyph_width() {
    let mut term = Terminal::new(20, 3, 100);
    // VS16 widens an emoji base (a keycap too), VS15 narrows one, and
    // on a base it does not vary it is dropped.
    feed(&mut term, "\u{2764}\u{FE0F}|1\u{FE0F}\u{20E3}|\u{231A}\u{FE0E}|a\u{FE0F}|");
    assert_eq!(
        glyphs(&term, 0),
        vec![
            ("\u{2764}\u{FE0F}".to_string(), true),
            ("|".to_string(), false),
            ("1\u{FE0F}\u{20E3}".to_string(), true),
            ("|".to_string(), false),
            ("\u{231A}\u{FE0E}".to_string(), false),
            ("|".to_string(), false),
            ("a".to_string(), false),
            ("|".to_string(), false),
        ]
    );
    assert_eq!(term.primary_cursor(), (10, 0));
}

#[test]
fn a_glyph_widened_in_the_last_column_wraps() {
    let mut term = Terminal::new(10, 3, 100);
    feed(&mut term, &format!("{}\u{2764}\u{FE0F}z", "x".repeat(9)));
    assert!(term.primary[0].wrapped);
    assert_eq!(term.primary[0].cells[9].kind, SPACER_HEAD);
    assert_eq!(
        glyphs(&term, 1),
        vec![("\u{2764}\u{FE0F}".to_string(), true), ("z".to_string(), false)]
    );
    assert_eq!(term.primary_cursor(), (3, 1));
}

#[test]
fn indic_spacing_marks_and_conjuncts_cluster() {
    let mut term = Terminal::new(20, 3, 100);
    // A spacing mark makes its cluster wide, as Ghostty sizes it.
    feed(&mut term, "\u{915}\u{93F}.");
    assert_eq!(
        glyphs(&term, 0),
        vec![("\u{915}\u{93F}".to_string(), true), (".".to_string(), false)]
    );
}
