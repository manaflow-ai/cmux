//! Mirrors the app's RightColumnPlacementTests.

use std::collections::{BTreeMap, HashMap};

use super::*;

fn column(
    source: f64,
    panes: &[&str],
    widths: &[(&str, f64)],
    kinds: &[(&str, &[Kind])],
) -> Column {
    Column {
        source_width: Some(source),
        panes: panes.iter().map(|pane| (*pane).to_owned()).collect(),
        widths: widths.iter().map(|(pane, width)| ((*pane).to_owned(), *width)).collect(),
        kinds: kinds.iter().map(|(pane, kinds)| ((*pane).to_owned(), kinds.to_vec())).collect(),
    }
}

fn tab(pane: &str) -> Decision {
    Decision::Tab { pane: Some(pane.to_owned()) }
}

fn below(pane: &str) -> Decision {
    Decision::SplitBelow { pane: pane.to_owned() }
}

#[test]
fn nothing_on_the_right_splits_right() {
    assert_eq!(decide(&column(1400.0, &[], &[], &[]), None), Decision::SplitRight);
}

#[test]
fn something_on_the_right_splits_below_it() {
    assert_eq!(decide(&column(1400.0, &["diff"], &[("diff", 700.0)], &[]), None), below("diff"));
}

#[test]
fn a_full_column_takes_a_tab_in_its_lower_pane() {
    assert_eq!(decide(&column(1400.0, &["diff", "lower"], &[], &[]), None), tab("lower"));
}

#[test]
fn a_narrow_chat_or_column_never_splits() {
    // Half of 959 pt is under the chat's 480 pt.
    assert_eq!(decide(&column(959.0, &[], &[], &[]), None), Decision::Tab { pane: None });
    assert_eq!(decide(&column(960.0, &[], &[], &[]), None), Decision::SplitRight);
    assert_eq!(decide(&column(479.0, &["diff"], &[("diff", 700.0)], &[]), None), tab("diff"));
    assert_eq!(decide(&column(1400.0, &["diff"], &[("diff", 419.0)], &[]), None), tab("diff"));
}

#[test]
fn an_unknown_width_sets_no_floor() {
    assert_eq!(decide(&Column::default(), None), Decision::SplitRight);
    let one = Column { panes: vec!["diff".into()], ..Column::default() };
    assert_eq!(decide(&one, None), below("diff"));
}

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect { x, y, width, height }
}

fn frames(entries: &[(&str, Rect)]) -> BTreeMap<String, Rect> {
    entries.iter().map(|(pane, rect)| ((*pane).to_owned(), *rect)).collect()
}

/// The column is read from frames, never from which pane was focused last.
#[test]
fn the_right_column_is_every_pane_at_the_sources_right_edge_top_to_bottom() {
    let window = frames(&[
        ("chat", rect(0.0, 0.0, 700.0, 800.0)),
        ("lower", rect(706.0, 404.0, 600.0, 396.0)),
        ("upper", rect(706.0, 0.0, 600.0, 400.0)),
        ("far", rect(1312.0, 0.0, 300.0, 800.0)),
    ]);
    assert_eq!(beside("chat", &window, GAP), ["upper", "lower"]);
    assert_eq!(beside("upper", &window, GAP), ["far"]);
    assert!(beside("far", &window, GAP).is_empty());
    assert!(beside("missing", &window, GAP).is_empty());
    // A pane beside only the lower half of a half-height source is not in its column.
    let halves = frames(&[
        ("top", rect(0.0, 0.0, 700.0, 400.0)),
        ("bottom", rect(0.0, 404.0, 700.0, 396.0)),
        ("right-top", rect(706.0, 0.0, 600.0, 400.0)),
        ("right-bottom", rect(706.0, 404.0, 600.0, 396.0)),
    ]);
    assert_eq!(beside("top", &halves, GAP), ["right-top"]);
    // A column past a wide gap is not beside the source.
    let away =
        frames(&[("chat", rect(0.0, 0.0, 700.0, 800.0)), ("away", rect(800.0, 0.0, 300.0, 800.0))]);
    assert!(beside("chat", &away, GAP).is_empty());
}

/// Leo 2026-10-31: "imo in this case, just open it on the existing. you only need the rightmost
/// botom auto split when there's a terminal that gets opened when there's already a browser, and
/// vice versa".
#[test]
fn a_browser_or_terminal_goes_to_the_pane_that_already_holds_its_kind() {
    let browser = column(1400.0, &["web"], &[("web", 700.0)], &[("web", &[Kind::Browser])]);
    assert_eq!(decide(&browser, Some(Kind::Browser)), tab("web"));
    assert_eq!(decide(&browser, Some(Kind::Terminal)), below("web"));
    let terminal = column(1400.0, &["shell"], &[("shell", 700.0)], &[("shell", &[Kind::Terminal])]);
    assert_eq!(decide(&terminal, Some(Kind::Terminal)), tab("shell"));
    assert_eq!(decide(&terminal, Some(Kind::Browser)), below("shell"));
    // Both kinds already split: each goes to its own pane, not only the lower one.
    let both = column(
        1400.0,
        &["web", "shell"],
        &[],
        &[("web", &[Kind::Browser]), ("shell", &[Kind::Terminal])],
    );
    assert_eq!(decide(&both, Some(Kind::Browser)), tab("web"));
    assert_eq!(decide(&both, Some(Kind::Terminal)), tab("shell"));
    // A narrow column still takes the tab where its kind is; nothing on the right still splits.
    let narrow = column(479.0, &["web"], &[], &[("web", &[Kind::Browser])]);
    assert_eq!(decide(&narrow, Some(Kind::Browser)), tab("web"));
    assert_eq!(decide(&column(1400.0, &[], &[], &[]), Some(Kind::Browser)), Decision::SplitRight);
    // No kind (a chat, a subagent, a file page): the rule as before.
    assert_eq!(decide(&browser, None), below("web"));
}

/// Leo 2026-11-03, of the Changes viewer: "just put it in a tab???".
#[test]
fn a_diff_is_a_tab_in_the_pane_on_the_right() {
    let browser = column(1400.0, &["web"], &[("web", 700.0)], &[("web", &[Kind::Browser])]);
    assert_eq!(decide(&browser, Some(Kind::Document)), tab("web"));
    assert_eq!(
        decide(&column(1400.0, &["web", "shell"], &[], &[]), Some(Kind::Document)),
        tab("shell")
    );
    assert_eq!(decide(&column(479.0, &["web"], &[], &[]), Some(Kind::Document)), tab("web"));
    assert_eq!(decide(&column(1400.0, &[], &[], &[]), Some(Kind::Document)), Decision::SplitRight);
    // Never a tab beside the chat.
    assert_eq!(decide(&column(959.0, &[], &[], &[]), Some(Kind::Document)), Decision::SplitRight);
}

/// Lawrence 2026-11-03: a pane on the right that already shows a diff takes the next one.
#[test]
fn a_diff_goes_to_the_pane_that_already_shows_a_diff() {
    let first = column(
        1400.0,
        &["diffs", "shell"],
        &[],
        &[("diffs", &[Kind::Document]), ("shell", &[Kind::Terminal])],
    );
    assert_eq!(decide(&first, Some(Kind::Document)), tab("diffs"));
    let lowest = column(
        1400.0,
        &["web", "diffs"],
        &[],
        &[("web", &[Kind::Browser]), ("diffs", &[Kind::Document])],
    );
    assert_eq!(decide(&lowest, Some(Kind::Document)), tab("diffs"));
}

/// A window of a chat and the column on its right: a pane whose last tab closes goes away.
#[derive(Default)]
struct Window {
    column: Vec<String>,
    pane_of: HashMap<String, String>,
    events: Vec<String>,
    panes: usize,
}

impl Window {
    fn occupy(&mut self, key: &str) {
        self.panes += 1;
        let pane = format!("right{}", self.panes);
        self.column.push(pane.clone());
        self.pane_of.insert(key.to_owned(), pane);
    }

    fn live(&self) -> Vec<String> {
        self.column
            .iter()
            .filter(|pane| self.pane_of.values().any(|held| held == *pane))
            .cloned()
            .collect()
    }

    fn measured(&self) -> Column {
        let live = self.live();
        Column {
            source_width: Some(1400.0),
            widths: live.iter().map(|pane| (pane.clone(), 700.0)).collect(),
            panes: live,
            kinds: HashMap::new(),
        }
    }

    fn place(&mut self, decision: Decision, key: &str) -> String {
        self.column = self.live();
        let pane = match decision {
            Decision::SplitRight => {
                self.panes += 1;
                let pane = format!("right{}", self.panes);
                self.column = vec![pane.clone()];
                self.events.push("split right".into());
                pane
            }
            Decision::SplitBelow { pane: above } => {
                self.panes += 1;
                let pane = format!("right{}", self.panes);
                let at = self
                    .column
                    .iter()
                    .position(|pane| *pane == above)
                    .unwrap_or(self.column.len() - 1);
                self.column.insert(at + 1, pane.clone());
                self.events.push(format!("split below {above}"));
                pane
            }
            Decision::Tab { pane } => {
                let pane = pane.unwrap_or_else(|| "chat".into());
                self.events.push(format!("tab in {pane}"));
                pane
            }
        };
        self.pane_of.insert(key.to_owned(), pane.clone());
        pane
    }
}

#[test]
fn closing_the_lower_pane_collapses_the_split_and_the_next_open_splits_again() {
    let mut window = Window::default();
    window.occupy("diff");
    let lower = window.place(decide(&window.measured(), None), "one");
    assert_eq!(window.live(), ["right1".to_owned(), lower]);
    window.pane_of.remove("one");
    assert_eq!(window.live(), ["right1"]);
    window.place(decide(&window.measured(), None), "two");
    assert_eq!(window.events, ["split below right1", "split below right1"]);
}

#[test]
fn a_fourth_open_is_a_tab_not_another_split() {
    let mut window = Window::default();
    for key in ["one", "two", "three", "four"] {
        window.place(decide(&window.measured(), None), key);
    }
    assert_eq!(
        window.events,
        ["split right", "split below right1", "tab in right2", "tab in right2"]
    );
    assert_eq!(window.live().len(), 2);
}
