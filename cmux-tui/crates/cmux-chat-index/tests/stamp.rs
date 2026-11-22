use cmux_chat_index::{Change, FileStamp};

fn stamp(ino: u64, size: u64, mtime_ms: i64) -> FileStamp {
    FileStamp { dev: 1, ino, size, mtime_ms }
}

#[test]
fn growth_appends_and_shrink_or_new_inode_rewrites() {
    let prev = stamp(7, 100, 10);
    assert_eq!(Change::between(&prev, &stamp(7, 100, 10)), Change::Unchanged);
    assert_eq!(Change::between(&prev, &stamp(7, 150, 11)), Change::Appended);
    assert_eq!(Change::between(&prev, &stamp(7, 50, 11)), Change::Rewritten);
    assert_eq!(Change::between(&prev, &stamp(8, 150, 11)), Change::Rewritten);
    assert_eq!(Change::between(&prev, &stamp(7, 100, 12)), Change::Rewritten);
}
