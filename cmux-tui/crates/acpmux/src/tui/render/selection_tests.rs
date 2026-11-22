use super::*;

/// A user bubble's row text lines up with its display cells, so a
/// drag inside the bubble copies the words under the pointer.
#[test]
fn bubble_rows_align_text_with_cells() {
    let c = Chrome::dark();
    let mut t = Transcript::default();
    t.items.push(Item::User { text: "copy these words".into(), steer: false, queued: false });
    let rows = transcript_rows(&t, 80, false, false, &std::collections::HashSet::new(), &c);
    let row = rows.iter().find(|r| r.text.contains("❯")).expect("bubble row");
    let shown: String = row.line.spans.iter().map(|s| s.content.to_string()).collect();
    let cell_col = shown.chars().position(|ch| ch == '❯').unwrap();
    let text_col = row.text.chars().position(|ch| ch == '❯').unwrap();
    assert_eq!(cell_col, text_col, "shown={shown:?} text={:?}", row.text);
    let (lo, hi) = content_bounds(&row.text);
    assert_eq!(row.text.chars().skip(lo).take(hi - lo).collect::<String>(), "copy these words");
    let i = rows.iter().position(|r| std::ptr::eq(r, row)).unwrap();
    let sel = Selection {
        session: "s".into(),
        anchor: (i, lo + 5),
        head: (i, lo + 10),
        mode: SelectMode::Cell,
    };
    assert_eq!(sel.text(&rows.iter().map(|r| r.text.clone()).collect::<Vec<_>>()), "these");
}

#[test]
fn effort_label_reads_like_the_codex_app() {
    assert_eq!(effort_label("xhigh"), "Extra high");
    assert_eq!(effort_label("high"), "High");
    assert_eq!(effort_label("think-hard"), "think-hard");
}

#[test]
fn model_label_drops_date_stamps() {
    assert_eq!(model_label("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
    assert_eq!(model_label("gpt-6-astra"), "gpt-6-astra");
    assert_eq!(model_label("subrouter/gpt-6-astra"), "subrouter/gpt-6-astra");
    assert_eq!(model_label("20251001"), "20251001");
}

#[test]
fn selection_skips_gutter_markers_and_padding() {
    assert_eq!(content_bounds("  › hello   "), (4, 9));
    assert_eq!(content_bounds("  ▸ • hostname  execute"), (6, 23));
    assert_eq!(content_bounds("• reply"), (2, 7));
    assert_eq!(content_bounds("    - item"), (4, 10));
    let rows = vec!["  › first line   ".to_owned(), "  • second".to_owned(), "".to_owned()];
    let sel =
        Selection { session: "s".into(), anchor: (0, 0), head: (1, 100), mode: SelectMode::Cell };
    assert_eq!(sel.text(&rows), "first line\nsecond");
    assert_eq!(sel.cols_on_row(0, &rows[0]), Some((4, 14)));
}
