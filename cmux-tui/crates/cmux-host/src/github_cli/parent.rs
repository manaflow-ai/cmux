//! The parent of a process, from its stat line (Linux `/proc/<pid>/stat`).

use std::path::Path;

/// The parent that the stat line in the file `path` names, or None when the
/// line does not read. `pid (comm) state ppid ...`; comm may hold spaces and
/// parens.
pub(super) fn parent_in(path: impl AsRef<Path>) -> Option<u32> {
    let stat = std::fs::read_to_string(path).ok()?;
    let (_, after) = stat.rsplit_once(')')?;
    after.split_whitespace().nth(1)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::parent_in;

    /// The parent is read whatever bytes the name of the program has.
    #[test]
    fn the_parent_is_read_for_each_program_name() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("stat");
        // The system keeps 15 bytes of a name: here 7 characters of 2 bytes
        // and the first byte of the next one.
        let mut line = b"4321 (".to_vec();
        line.extend_from_slice("\u{e9}".repeat(7).as_bytes());
        line.push(0xc3);
        line.extend_from_slice(b") S 77 4321 4321 0 -1 4194304 0 0\n");
        std::fs::write(&path, line).unwrap();
        assert_eq!(parent_in(&path), Some(77));
        std::fs::write(&path, b"4321 (a ) name) S 78 4321\n").unwrap();
        assert_eq!(parent_in(&path), Some(78));
        assert_eq!(parent_in(dir.path().join("none")), None);
    }
}
