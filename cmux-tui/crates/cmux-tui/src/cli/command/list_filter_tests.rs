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
    let named = ListFilter { name: Some("api".into()), cwd: None };
    assert!(named.name_matches(Some("api")));
    assert!(!named.name_matches(Some("api-2")));
    assert!(!named.name_matches(None));
    assert!(ListFilter::default().name_matches(None));
}
