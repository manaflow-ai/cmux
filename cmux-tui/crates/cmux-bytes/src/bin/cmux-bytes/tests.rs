use super::*;

#[test]
fn a_missing_folder_is_an_error_and_an_empty_one_is_not() {
    let empty = std::env::temp_dir().join(format!("cmux-bytes-empty-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    let ok = parse(&["--folder".into(), format!("empty={}", empty.display())]);
    let gone = parse(&["--folder".into(), format!("gone={}/missing", empty.display())]);
    std::fs::remove_dir(&empty).unwrap();
    assert!(ok.is_ok());
    assert!(gone.err().unwrap().contains("gone="));
}
