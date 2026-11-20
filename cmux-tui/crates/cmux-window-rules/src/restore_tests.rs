use super::*;

fn window(id: &str, open: bool, made: bool) -> SavedWindow {
    SavedWindow { id: id.to_owned(), open, made }
}

#[test]
fn only_the_adopted_front_window_is_made_now_and_the_others_wait_front_to_back() {
    let windows = [window("a", true, true), window("b", true, false), window("c", true, false)];
    let order = order(&windows, Some("a"));
    assert_eq!(order.front.as_deref(), Some("a"));
    assert_eq!(order.later, ["b", "c"]);
}

#[test]
fn without_an_adopted_window_the_front_open_one_is_made_now() {
    let windows =
        [window("closed", false, false), window("b", true, false), window("c", true, false)];
    let order = order(&windows, None);
    assert_eq!(order.front.as_deref(), Some("b"));
    assert_eq!(order.later, ["c"]);
}

#[test]
fn an_adopted_window_that_is_not_the_most_recent_still_comes_first() {
    // The launch window adopts the front window that can show now; a more recent one whose workspaces are gone waits.
    let windows = [window("gone", true, false), window("a", true, true), window("c", true, false)];
    let order = order(&windows, Some("a"));
    assert_eq!(order.front.as_deref(), Some("a"));
    assert_eq!(order.later, ["gone", "c"]);
}

#[test]
fn closed_and_already_made_windows_never_wait() {
    let windows =
        [window("a", true, false), window("closed", false, false), window("made", true, true)];
    let order = order(&windows, None);
    assert_eq!(order.front.as_deref(), Some("a"));
    assert!(order.later.is_empty());
}

#[test]
fn no_open_window_has_no_front_and_nothing_waits() {
    let windows = [window("a", false, false)];
    assert_eq!(order(&windows, Some("a")), Order::default());
    assert_eq!(order(&[], None), Order::default());
}

#[test]
fn sixty_windows_make_one_now() {
    let windows: Vec<_> = (0..60).map(|i| window(&format!("w{i}"), true, false)).collect();
    let order = order(&windows, None);
    assert_eq!(order.front.as_deref(), Some("w0"));
    assert_eq!(order.later.len(), 59);
    assert_eq!(order.later.first().map(String::as_str), Some("w1"));
}
