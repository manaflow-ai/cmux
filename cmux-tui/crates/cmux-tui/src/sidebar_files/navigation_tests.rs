use std::fs::{self, create_dir};

use super::*;

#[test]
fn follows_until_navigation_pins_then_reroot_unpins() {
    let temp = std::env::temp_dir().join(format!(
        "cmux-tui-sidebar-navigation-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = fs::remove_dir_all(&temp);
    fs::create_dir_all(&temp).unwrap();
    let first = temp.join("first");
    let second = temp.join("second");
    let manual = temp.join("manual");
    create_dir(&first).unwrap();
    create_dir(&second).unwrap();
    create_dir(&manual).unwrap();

    let mut navigation = Navigation::new(first.clone());
    assert!(navigation.follow_focused_cwd(&second));
    assert_eq!(navigation.current_dir(), second);

    assert!(navigation.navigate(manual.clone()));
    assert!(navigation.is_pinned());
    assert!(!navigation.follow_focused_cwd(&first));
    assert_eq!(navigation.current_dir(), manual);

    assert!(navigation.reroot(first.clone()));
    assert!(!navigation.is_pinned());
    assert_eq!(navigation.current_dir(), first);
    assert!(navigation.follow_focused_cwd(&second));
    fs::remove_dir_all(temp).unwrap();
}
