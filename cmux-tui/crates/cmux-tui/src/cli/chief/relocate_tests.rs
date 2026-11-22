use super::split_chief_home;

#[test]
fn relocate_splits_the_chief_home_out_of_the_move_arguments() {
    let args: Vec<String> =
        ["--to", "ssh:mini", "--chief-home", "/h", "--dry-run"].map(String::from).to_vec();
    let (home, rest) = split_chief_home(&args);
    assert_eq!(home.as_deref(), Some(std::path::Path::new("/h")));
    assert_eq!(rest, ["--to", "ssh:mini", "--dry-run"]);
    let (home, rest) = split_chief_home(&["--chief-home=/x".to_owned()]);
    assert_eq!(home.as_deref(), Some(std::path::Path::new("/x")));
    assert!(rest.is_empty());
}
