use super::*;

fn filter(path: &str, base: &str) -> CwdFilter {
    CwdFilter::new(path, Path::new(base))
}

#[test]
fn cwd_matches_the_folder_and_what_is_inside_it_only() {
    let projects = filter("/nonexistent-cmux/projects/", "/");
    assert!(projects.contains("/nonexistent-cmux/projects"));
    assert!(projects.contains("/nonexistent-cmux/projects/"));
    assert!(projects.contains("/nonexistent-cmux/projects/app/src"));
    assert!(!projects.contains("/nonexistent-cmux/projects-old"));
    assert!(!projects.contains("/nonexistent-cmux"));
    assert!(filter("/", "/").contains("/anything"));
}

#[cfg(windows)]
#[test]
fn cwd_matches_inside_a_windows_folder() {
    let projects = filter(r"C:\work\projects", r"C:\");
    assert!(projects.contains(r"C:\work\projects\app"));
    assert!(projects.contains(r"C:\work\projects"));
    assert!(!projects.contains(r"C:\work\projects-old"));
}

#[test]
fn cwd_is_made_absolute_against_the_current_folder() {
    let relative = filter("../b/./c", "/nonexistent-cmux/a");
    assert_eq!(relative.roots, vec!["/nonexistent-cmux/b/c".to_owned()]);
    assert!(relative.contains("/nonexistent-cmux/b/c/d"));
}

#[test]
fn name_matches_exactly() {
    let named = ListFilter { name: Some("api".into()), ..ListFilter::default() };
    assert!(named.name_matches(Some("api")));
    assert!(!named.name_matches(Some("api-2")));
    assert!(!named.name_matches(None));
    assert!(ListFilter::default().name_matches(None));
}

#[test]
fn id_matches_one_of_the_ids_or_a_prefix_of_one() {
    let by_id = ListFilter { ids: vec!["ws_7aee".into(), "ws_5899".into()], ..Default::default() };
    assert!(by_id.id_matches(Some("ws_7aee67b9a4766d8f988977bc5c1380ba")));
    assert!(by_id.id_matches(Some("ws_5899901293e83f3696104e5260ca3de6")));
    assert!(!by_id.id_matches(Some("ws_fddd5e")));
    assert!(!by_id.id_matches(None));
    assert!(ListFilter::default().id_matches(None));
}
