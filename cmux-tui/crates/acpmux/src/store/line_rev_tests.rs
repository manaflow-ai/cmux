//! `for_each_line_rev` over a real file (`store.rs`).

use super::*;
use std::os::unix::fs::PermissionsExt;

/// Lines come newest first, whole, whatever blocks they span; blank lines are skipped.
#[test]
fn lines_across_blocks_come_back_whole_newest_first() {
    let path = std::env::temp_dir().join(format!(
        "acpmux-line-rev-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let lines =
        ["a".to_owned(), "x".repeat(200_000), String::new(), "b".repeat(65_535), "c".into()];
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let mut seen = Vec::new();
    for_each_line_rev(&path, &mut |line| {
        seen.push(String::from_utf8(line.to_vec()).unwrap());
        true
    })
    .unwrap();
    let _ = std::fs::remove_file(&path);
    let want: Vec<String> = lines.iter().rev().filter(|l| !l.is_empty()).cloned().collect();
    assert_eq!(seen.len(), want.len());
    assert!(seen == want, "lines came back changed or out of order");
}
