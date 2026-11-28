use super::*;

fn row(text: &str) -> Row {
    Row {
        cells: text.chars().map(|c| Cell { ch: c as u32, style: 0, kind: 0 }).collect(),
        wrapped: false,
        prompt: false,
    }
}

#[test]
fn a_scroll_back_down_unholds_the_rows_it_brings_back() {
    let mut held = HeldRows::default();
    for i in 0..5 {
        held.push(row(&format!("line {i}")));
    }
    held.pop(2);
    assert_eq!(held.len(), 3);
    held.push(row("line 3"));
    assert_eq!(held.len(), 4, "line 3 is held once");
}

#[test]
fn the_store_is_capped() {
    let mut held = HeldRows::default();
    for i in 0..HELD_ROW_CAP + 500 {
        held.push(row(&format!("line {i}")));
    }
    assert_eq!(held.len(), HELD_ROW_CAP);
    let oldest = held.get(0).map(|r| r.cells.len());
    assert_eq!(oldest, Some(row("line 500").cells.len()));
}

#[test]
fn a_frame_with_a_spinner_replaces_the_last_one() {
    let mut held = HeldRows::default();
    let page = |spin: &str| vec![row("header"), row(spin), row("body"), row("footer")];
    held.push_frame(&page("|"));
    held.push_frame(&page("/"));
    held.push_frame(&page("-"));
    assert_eq!(held.len(), 4, "one screen: only the spinner changed");
    held.push_frame(&[row("a"), row("b"), row("c"), row("d")]);
    assert_eq!(held.len(), 8, "a new page is held after it");
    held.push_frame(&[row(""), row(""), row(""), row("")]);
    assert_eq!(held.len(), 8, "a blank screen is not held");
}
