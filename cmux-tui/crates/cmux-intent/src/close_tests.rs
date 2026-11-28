use super::*;

#[test]
fn the_cutoff_is_difflibs() {
    // Python: get_close_matches("--wiat", ["--wait", "--days"], 3, 0.75) == ["--wait"]
    assert_eq!(close_matches("--wiat", &["--wait", "--days"], 3, 0.75), ["--wait"]);
    assert!(close_matches("--days", &["--wait"], 3, 0.75).is_empty());
    assert!((ratio("abcd", "bcde") - 0.75).abs() < 1e-9);
}

#[test]
fn quoting_is_shlexs() {
    assert_eq!(shell_join(&["a b", "c", "", "it's"]), "'a b' c '' 'it'\"'\"'s'");
}
