//! Where a Windows terminal host listens (EndpointPolicy): one owner-only
//! directory per user under the per-user temp folder,
//! `%TEMP%\cmux-th-<USERNAME>\<terminal_hex>.sock`, made and checked by
//! `cmux::local_socket` (`listen`: owner-only protected DACL, the socket
//! file's owner set to the token user; `connect_same_user`: that owner is
//! ours). Unix uses `/tmp/cmux-th-<uid>/<terminal_hex>.sock`.

use std::path::{Path, PathBuf};

/// The endpoint directory for `user` under `temp`.
pub fn endpoint_dir_in(temp: &Path, user: &str) -> PathBuf {
    temp.join(format!("cmux-th-{}", sanitize(user)))
}

/// This user's endpoint directory.
pub fn endpoint_dir() -> PathBuf {
    endpoint_dir_in(
        &std::env::temp_dir(),
        &std::env::var("USERNAME").unwrap_or_else(|_| "user".into()),
    )
}

/// The socket of terminal `terminal_hex` (32 lowercase hex digits).
pub fn endpoint_path_in(dir: &Path, terminal_hex: &str) -> Option<PathBuf> {
    is_terminal_hex(terminal_hex).then(|| dir.join(format!("{terminal_hex}.sock")))
}

/// Whether a record's endpoint is exactly where this user's host for
/// `terminal_hex` listens (record validation; a record naming any other
/// path is refused).
pub fn endpoint_matches(dir: &Path, terminal_hex: &str, endpoint: &Path) -> bool {
    endpoint_path_in(dir, terminal_hex).is_some_and(|want| same_path(&want, endpoint))
}

fn is_terminal_hex(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A user name as one path component: no separators, no `..`, no drive
/// colon; anything else is kept (Windows names are case-insensitive).
fn sanitize(user: &str) -> String {
    let cleaned: String = user
        .chars()
        .map(|c| if matches!(c, '\\' | '/' | ':' | '.' | '\0') { '_' } else { c })
        .collect();
    if cleaned.is_empty() { "user".into() } else { cleaned }
}

/// Windows paths compare case-insensitively, with either separator.
fn same_path(a: &Path, b: &Path) -> bool {
    let norm = |p: &Path| p.to_string_lossy().replace('/', "\\").to_lowercase();
    norm(a) == norm(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn the_endpoint_is_the_users_directory_and_the_terminal_hex() {
        let dir = endpoint_dir_in(Path::new(r"C:\Users\u\AppData\Local\Temp"), "u");
        assert_eq!(dir, Path::new(r"C:\Users\u\AppData\Local\Temp\cmux-th-u"));
        assert_eq!(endpoint_path_in(&dir, ID).unwrap(), dir.join(format!("{ID}.sock")));
        assert!(endpoint_matches(&dir, ID, &dir.join(format!("{ID}.sock"))));
        assert!(endpoint_matches(
            &dir,
            ID,
            Path::new(&format!(r"c:/users/U/appdata/local/temp/CMUX-TH-U/{ID}.SOCK"))
        ));
    }

    #[test]
    fn other_paths_and_malformed_ids_are_refused() {
        let dir = endpoint_dir_in(Path::new(r"C:\t"), "u");
        assert!(endpoint_path_in(&dir, "..\\evil").is_none());
        assert!(endpoint_path_in(&dir, &ID.to_uppercase()).is_none());
        assert!(!endpoint_matches(&dir, ID, Path::new(&format!(r"C:\t\cmux-th-other\{ID}.sock"))));
        assert!(!endpoint_matches(
            &dir,
            ID,
            Path::new(r"C:\t\cmux-th-u\0123456789abcdef0123456789abcdee.sock")
        ));
    }

    #[test]
    fn a_user_name_never_leaves_its_directory() {
        assert_eq!(endpoint_dir_in(Path::new(r"C:\t"), r"..\x"), Path::new(r"C:\t\cmux-th-___x"));
        assert_eq!(endpoint_dir_in(Path::new(r"C:\t"), ""), Path::new(r"C:\t\cmux-th-user"));
    }
}
