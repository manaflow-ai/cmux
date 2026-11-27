use super::*;

#[test]
fn an_allowed_file_gives_its_request_folder_and_always_gives_the_copy() {
    assert_eq!(
        answered_folder("/w/local/requests/r1/notes.md", None).as_deref(),
        Some("/w/local/requests/r1")
    );
    assert_eq!(
        answered_folder("/w/local/proj-1/a/b.txt", Some("/w/local/proj-1")).as_deref(),
        Some("/w/local/proj-1")
    );
    assert_eq!(answered_folder("/x", None), None);
}

#[test]
fn a_path_outside_home_is_shown_whole() {
    assert_eq!(shown(Path::new("/nowhere-home/x")), "/nowhere-home/x");
}
