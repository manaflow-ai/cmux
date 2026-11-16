//! Tests of what the stores of an owner do after its release
//! ([`OwnerRelease`]).

use super::tests::database;
use super::*;

/// A writer that fails each write, as stderr does on a full disk or
/// when its reader ended.
struct FailingLine;

impl std::io::Write for FailingLine {
    fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
        Err(std::io::Error::other("the line has no place to go"))
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A writer that panics at each write.
struct PanickingLine;

impl std::io::Write for PanickingLine {
    fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
        panic!("the line's writer panicked")
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// One row before the owner's release and one write after it, on a
/// connection with the product's commit hook whose line goes to `line`.
/// Returns that late write's result and the rows that the table holds
/// after it.
fn write_after_the_release(
    name: &str,
    line: Box<dyn std::io::Write + Send>,
) -> (Result<usize, String>, i64) {
    let (dir, connection) = database(name);
    let released = OwnerRelease::default();
    released.set_line_for_test(line);
    let _durability = WalDurability::attach_with_commit_delay(
        &connection,
        &dir.join("r.sqlite"),
        None,
        false,
        None,
        released.clone(),
    );
    connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
    released.set();
    // A thread of its own: a thread says the line at its first refused
    // commit only.
    let written = std::thread::spawn(move || {
        let late =
            connection.execute("INSERT INTO t VALUES (2)", []).map_err(|error| error.to_string());
        let rows =
            connection.query_row("SELECT count(*) FROM t", [], |row| row.get::<_, i64>(0)).unwrap();
        (late, rows)
    })
    .join()
    .expect("the thread of the late write ended with a panic");
    let _ = std::fs::remove_dir_all(&dir);
    written
}

/// The commit hook says a line at a thread's first refused commit. The
/// SQLite binding reads a panic in a commit hook as "commit", so a line
/// whose write fails must not be a panic: that commit would land in the
/// store that the next owner has.
#[test]
fn a_commit_after_the_release_is_refused_also_when_its_stderr_line_fails() {
    let (late, rows) = write_after_the_release("refused-line-fails", Box::new(FailingLine));
    assert!(
        late.is_err() && rows == 1,
        "a commit after the owner's release landed, because the write of the hook's stderr \
         line failed: the late write: {late:?}; rows: {rows} (1 before the release)"
    );
}

/// The same for a line that panics for another reason: nothing changes
/// the hook's answer once the release is read.
#[test]
fn a_commit_after_the_release_is_refused_also_when_its_stderr_line_panics() {
    let (late, rows) = write_after_the_release("refused-line-panics", Box::new(PanickingLine));
    assert!(
        late.is_err() && rows == 1,
        "a commit after the owner's release landed, because the hook's stderr line \
         panicked: the late write: {late:?}; rows: {rows} (1 before the release)"
    );
}
