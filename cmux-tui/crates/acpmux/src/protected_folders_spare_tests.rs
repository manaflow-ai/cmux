use super::*;

#[test]
fn a_spare_may_start_in_the_home_folder_off_macos_only() {
    let home = Path::new("/home/someone");
    assert!(spare_refusal_in(home, Some(home), false).is_none());
    assert!(spare_refusal_in(Path::new("/home/someone/"), Some(home), false).is_none());
    assert!(spare_refusal_in(home, Some(home), true).is_some(), "macOS keeps the refusal");
    assert!(spare_refusal_in(Path::new("/"), Some(home), false).is_some());
    assert!(spare_refusal_in(Path::new("relative"), Some(home), false).is_some());
    assert!(spare_refusal_in(Path::new("/home/someone/work"), Some(home), false).is_none());
}
