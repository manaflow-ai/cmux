use super::*;

#[test]
fn wrap_keeps_the_space_before_the_break_on_the_line() {
    assert_eq!(wrap("aa bb cc", 6), vec!["aa bb ".to_owned(), "cc".to_owned()]);
    assert_eq!(wrap("abcdefgh", 3), vec!["abc".to_owned(), "def".to_owned(), "gh".to_owned()]);
    assert_eq!(wrap("a\n\nb", 5), vec!["a".to_owned(), String::new(), "b".to_owned()]);
}

#[test]
fn a_blank_cell_looks_the_same_whatever_its_foreground() {
    let a = Cell { text: " ".into(), style: Style::fg(246) };
    let b = Cell { text: "\u{a0}".into(), style: Style::PLAIN };
    assert!(a.looks_same(&b));
    let c = Cell { text: "x".into(), style: Style::fg(246) };
    let d = Cell { text: "x".into(), style: Style::PLAIN };
    assert!(!c.looks_same(&d));
}

#[test]
fn runs_merge_cells_of_one_style() {
    let mut line = Line::new();
    line.push("ab", Style::fg(1)).push("c", Style::PLAIN);
    let grid = Grid { cols: 4, rows: 1, cells: vec![line.into_row(4)] };
    let runs = grid.runs(&xterm_palette());
    let texts: Vec<&str> = runs.iter().flatten().map(|r| r.text.as_str()).collect();
    assert_eq!(texts, vec!["ab", "c "]);
    assert_eq!(runs.first().and_then(|r| r.first()).and_then(|r| r.fg), Some((205, 0, 0)));
}
