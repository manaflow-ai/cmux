use super::*;

fn folded(path: &Path, max: u64) -> Vec<String> {
    let mut lines = Vec::new();
    fold_newest_lines(path, max, |line| {
        lines.push(String::from_utf8_lossy(line).into_owned());
    })
    .expect("read");
    lines
}

#[test]
fn the_newest_lines_are_read_from_a_whole_line_and_no_further_than_the_file_was() {
    let dir = std::env::temp_dir().join(format!("chat-index-lines-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("dir");
    let path = dir.join("t.jsonl");
    std::fs::write(&path, "first line\nsecond\nthird\n").expect("write");
    let all = |lines: &[&str]| lines.iter().map(|l| (*l).to_owned()).collect::<Vec<_>>();
    // Small enough to hold it all: every line.
    assert_eq!(folded(&path, 1024), all(&["first line", "second", "third"]));
    // The cut falls inside "second": that line is skipped, not read in part.
    assert_eq!(folded(&path, 10), all(&["third"]));
    // The cut falls on the start of "third": that line is whole and read.
    assert_eq!(folded(&path, 6), all(&["third"]));
    // A trailing partial line (still being written) is not read.
    std::fs::write(&path, "a\nb\npartial").expect("write");
    assert_eq!(folded(&path, 1024), all(&["a", "b"]));
    // The cut falls inside a last line that has no end yet: no line at all.
    assert_eq!(folded(&path, 3), Vec::<String>::new());
    let _ = std::fs::remove_dir_all(&dir);
}
