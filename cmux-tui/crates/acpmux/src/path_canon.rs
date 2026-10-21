//! One spelling for each file a tool call names, so a client can tell that
//! two spellings are the same file: `./notes.txt` and its absolute path, a
//! folder link and the real folder, `Notes.txt` and `notes.txt` on a volume
//! that ignores case. For a file that exists in a git repository it is
//! `$(git rev-parse --show-toplevel)/<path>`, the path a turn checkpoint names
//! the file by. The hub records it beside each tool call path
//! (`hub/tool_paths.rs`); clients compare only these.

use std::path::Path;

/// The canonical form of `path`, a tool call's path as the agent wrote it, in
/// a session working in `cwd`. None when it has none: an empty path, a
/// relative one with no `cwd`.
pub fn canonical_path(_path: &str, _cwd: Option<&Path>) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// A folder for one test, `real/Notes.txt` in it and `link` -> `real`,
    /// with its own path resolved (macOS's temp folder is under a link).
    fn tree(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acpmux-canon-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("real")).unwrap();
        std::fs::write(dir.join("real/Notes.txt"), "notes\n").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(dir.join("real"), dir.join("link")).unwrap();
        std::fs::canonicalize(&dir).unwrap()
    }

    fn text(path: PathBuf) -> String {
        path.into_os_string().into_string().unwrap()
    }

    #[cfg(unix)]
    #[test]
    fn a_folder_link_dot_segments_and_doubled_slashes_name_the_real_file() {
        let dir = tree("spellings");
        let want = text(dir.join("real/Notes.txt"));
        let link = dir.join("link");
        for spelling in [
            text(dir.join("link/Notes.txt")),
            "./Notes.txt".to_owned(),
            "Notes.txt".to_owned(),
            "../real/./Notes.txt".to_owned(),
            format!("{}//real///Notes.txt", dir.display()),
        ] {
            assert_eq!(
                canonical_path(&spelling, Some(&link)).as_deref(),
                Some(&*want),
                "{spelling}"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_file_not_there_yet_keeps_its_spelling_under_its_real_folder() {
        let dir = tree("new");
        let link = dir.join("link");
        let want = text(dir.join("real/New File.swift"));
        let before = canonical_path("New File.swift", Some(&link));
        assert_eq!(before.as_deref(), Some(&*want));
        assert_eq!(
            canonical_path("sub/../New File.swift", Some(&link)).as_deref(),
            Some(&*want),
            "a missing folder's `..` still goes back up"
        );
        // A refused Write and the retry that creates the file are one file:
        // the created file is stored as it was spelled.
        std::fs::write(link.join("New File.swift"), "").unwrap();
        assert_eq!(canonical_path("New File.swift", Some(&link)), before);
        assert_eq!(
            canonical_path("deeper/x.txt", Some(&link)).as_deref(),
            Some(&*text(dir.join("real/deeper/x.txt")))
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn another_letter_case_names_the_file_as_the_volume_stores_it() {
        let dir = tree("case");
        let typed = dir.join("LINK/notes.TXT");
        // Only a volume that ignores case finds the file in another case (APFS
        // by default; Linux volumes do not).
        if !typed.exists() {
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        let want = text(dir.join("real/Notes.txt"));
        assert_eq!(canonical_path(typed.to_str().unwrap(), None).as_deref(), Some(&*want));
        assert_eq!(canonical_path("REAL/NOTES.txt", Some(&dir)).as_deref(), Some(&*want));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_file_in_a_repository_is_named_as_git_names_it() {
        let dir = tree("git");
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(dir.join("link"))
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .output()
                .ok()
                .filter(|o| o.status.success())
        };
        let Some(_) = git(&["init", "-q"]) else {
            let _ = std::fs::remove_dir_all(&dir);
            return;
        };
        let top = git(&["rev-parse", "--show-toplevel"]).unwrap();
        let top = String::from_utf8(top.stdout).unwrap();
        let want = format!("{}/Notes.txt", top.trim_end());
        let typed = if dir.join("LINK/NOTES.TXT").exists() { "NOTES.TXT" } else { "Notes.txt" };
        assert_eq!(canonical_path(typed, Some(&dir.join("link"))).as_deref(), Some(&*want));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn home_is_expanded_and_a_bare_relative_path_has_none() {
        if let Some(home) = dirs::home_dir().and_then(|h| std::fs::canonicalize(h).ok()) {
            let want = text(home.join("acpmux-canon-not-there.txt"));
            assert_eq!(
                canonical_path("~/acpmux-canon-not-there.txt", None).as_deref(),
                Some(&*want)
            );
        }
        assert_eq!(canonical_path("notes.txt", None), None);
        assert_eq!(canonical_path("", Some(Path::new("/"))), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_name_stored_decomposed_reads_composed_as_git_shows_it() {
        let dir = tree("nfc");
        std::fs::write(dir.join("real/Cafe\u{301}.txt"), "").unwrap();
        let got = canonical_path("Cafe\u{301}.txt", Some(&dir.join("link"))).unwrap();
        assert!(got.ends_with("/real/Caf\u{e9}.txt"), "{got:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
