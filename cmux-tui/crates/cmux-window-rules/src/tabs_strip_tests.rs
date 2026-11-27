use super::*;

fn tab(id: &str, pinned: bool, closable: bool, group: Option<&str>) -> Tab {
    Tab { id: id.into(), pinned, closable, group: group.map(Into::into) }
}

/// home (pinned, cannot close), p1 pinned, t2, g:[t3 t4], t5.
fn strip(collapsed: &[&str]) -> Strip {
    Strip {
        tabs: vec![
            tab("home", true, false, None),
            tab("p1", true, true, None),
            tab("t2", false, true, None),
            tab("t3", false, true, Some("g")),
            tab("t4", false, true, Some("g")),
            tab("t5", false, true, None),
        ],
        collapsed: collapsed.iter().map(|group| group.to_string()).collect(),
    }
}

fn select(tab: &str) -> KeyboardClose {
    KeyboardClose::Select { tab: tab.into() }
}

#[test]
fn cmd_w_closes_a_pinned_tab_and_keeps_one_that_cannot_close() {
    let strip = strip(&[]);
    assert_eq!(strip.keyboard_close("p1"), KeyboardClose::Close);
    assert_eq!(strip.keyboard_close("gone"), KeyboardClose::Close);
    assert_eq!(strip.keyboard_close("home"), select("p1"));
    let alone = Strip { tabs: vec![tab("home", true, false, None)], ..Strip::default() };
    assert_eq!(alone.keyboard_close("home"), KeyboardClose::Ignore);
}

#[test]
fn cmd_w_on_a_kept_tab_skips_hidden_tabs_and_looks_back_at_the_end() {
    let mut strip = strip(&["g"]);
    strip.tabs[5].closable = false;
    strip.tabs.swap(2, 5);
    // home p1 t5(kept) g:[t3 t4] t2 -> t2 after the collapsed group.
    assert_eq!(strip.keyboard_close("t5"), select("t2"));
    strip.tabs.pop();
    assert_eq!(strip.keyboard_close("t5"), select("p1"));
}

#[test]
fn close_commands_never_close_pinned_tabs_or_one_that_cannot_close() {
    let closed = strip(&[]).closed_by("t3");
    assert_eq!(closed.others, ["t2", "t4", "t5"]);
    assert_eq!(closed.left, ["t2"]);
    assert_eq!(closed.right, ["t4", "t5"]);
    let gone = strip(&[]).closed_by("gone");
    assert_eq!(gone.others, ["t2", "t3", "t4", "t5"]);
    assert!(gone.left.is_empty() && gone.right.is_empty());
}

#[test]
fn a_close_command_selects_the_tab_acted_on_unless_the_selection_stays() {
    let kept: BTreeSet<String> = ["t4".to_string()].into();
    assert_eq!(selection_keeping(Some("t2"), "t3", &kept), Some("t3".into()));
    assert_eq!(selection_keeping(Some("t3"), "t3", &kept), None);
    assert_eq!(selection_keeping(Some("t4"), "t3", &kept), None);
    assert_eq!(selection_keeping(None, "t3", &kept), Some("t3".into()));
}

#[test]
fn moves_stay_in_their_section_and_step_past_a_group() {
    let strip = strip(&[]);
    assert_eq!(strip.move_index("p1", -1), Some(0));
    assert_eq!(strip.move_index("p1", 1), None);
    assert_eq!(strip.move_index("t2", -1), None);
    assert_eq!(strip.move_index("t2", 1), Some(4));
    assert_eq!(strip.move_index("t5", -1), Some(3));
    assert_eq!(strip.move_index("t3", 1), Some(4));
    assert_eq!(strip.move_index("t4", 1), None);
    assert_eq!(strip.move_index("t2", 0), None);
    assert_eq!(strip.move_index("gone", 1), None);
}

#[test]
fn next_and_previous_tab_wrap_and_skip_a_collapsed_group() {
    let strip = strip(&["g"]);
    assert_eq!(strip.adjacent(Some("t2"), 1), Some("t5".into()));
    assert_eq!(strip.adjacent(Some("t5"), 1), Some("home".into()));
    assert_eq!(strip.adjacent(Some("home"), -1), Some("t5".into()));
    // From a hidden tab it counts from its place.
    assert_eq!(strip.adjacent(Some("t3"), -1), Some("t2".into()));
    assert_eq!(strip.adjacent(None, 1), Some("home".into()));
    assert_eq!(strip.adjacent(None, -1), Some("t5".into()));
    assert_eq!(strip.adjacent(Some("t2"), 0), None);
    assert_eq!(Strip::default().adjacent(None, 1), None);
}
