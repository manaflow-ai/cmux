//! One spelling for each file a tool call names, so a client can tell that
//! two spellings are the same file: `./notes.txt` and its absolute path, a
//! folder link and the real folder, `Notes.txt` and `notes.txt` on a volume
//! that ignores case. For a file that exists in a git repository it is
//! `$(git rev-parse --show-toplevel)/<path>`, the path a turn checkpoint names
//! the file by, up to Unicode normalization: this path is NFC, and git may
//! print a folder stored decomposed as it is stored, so a client normalizes
//! the checkpoint side to NFC before comparing. The hub records it beside
//! each tool call path (`hub/tool_paths.rs`); clients compare only these.

use std::path::{Path, PathBuf};

/// The canonical form of `path`, a tool call's path as the agent wrote it, in
/// a session working in `cwd`: absolute (a leading `~` is the home folder),
/// with `.`, `..`, doubled slashes and symlinks resolved the way the OS opens
/// it (`hand::policy::resolve`), and on macOS each existing component spelled
/// as the volume stores it, NFC (`realpath` already returns the stored letter
/// case; reading each stored name keeps that true when the realpath fallback
/// runs). A component that is not there yet keeps the spelling given, so a
/// call before the file exists and one after it names it the same way: the
/// file is stored as it was spelled. None for an empty or non-UTF-8 path, a
/// relative one with no `cwd`, or one a dangling link breaks. None on
/// Windows, where the resolved form `\\?\C:\...` never matches git's `C:/...`.
pub fn canonical_path(path: &str, cwd: Option<&Path>) -> Option<String> {
    if cfg!(windows) {
        return None;
    }
    let path = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => {
            dirs::home_dir()?.join(rest.trim_start_matches('/'))
        }
        _ => PathBuf::from(path),
    };
    if path.as_os_str().is_empty() || (path.is_relative() && cwd.is_none()) {
        return None;
    }
    let joined = cwd.map_or_else(|| path.clone(), |cwd| cwd.join(&path));
    // Most paths name a file that is there: one realpath for all of it.
    let resolved = match std::fs::canonicalize(&joined) {
        Ok(real) => real,
        Err(_) => crate::hand::policy::resolve(joined.to_str()?, None).ok()?,
    };
    if !resolved.is_absolute() {
        return None;
    }
    #[cfg(target_os = "macos")]
    let resolved = stored_spelling(&resolved);
    let text = resolved.into_os_string().into_string().ok()?;
    // As git shows names on macOS (core.precomposeunicode).
    #[cfg(target_os = "macos")]
    let text: String = unicode_normalization::UnicodeNormalization::nfc(text.as_str()).collect();
    Some(text)
}

/// `path` (resolved: no links, `.` or `..`) with each component that exists
/// as the volume stores its name, and the rest as given.
#[cfg(target_os = "macos")]
fn stored_spelling(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    let mut there = true;
    for part in path.components() {
        match part {
            Component::Normal(name) if there => match stored_name(&out.join(name)) {
                Some(stored) => out.push(stored),
                None => {
                    there = false;
                    out.push(name);
                }
            },
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// The name the volume stores for the last component of `path`
/// (`getattrlist` `ATTR_CMN_NAME`, not following a final link), or None when
/// it is not there.
#[cfg(target_os = "macos")]
fn stored_name(path: &Path) -> Option<std::ffi::OsString> {
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: attrlist is plain old data; all-zero is a valid empty request.
    let mut request: libc::attrlist = unsafe { std::mem::zeroed() };
    request.bitmapcount = libc::ATTR_BIT_MAP_COUNT;
    request.commonattr = libc::ATTR_CMN_NAME;
    // The reply's u32 length, an attrreference_t, then the name (NAME_MAX
    // UTF-8 characters and its NUL).
    let mut reply = [0u8; 4 + 8 + 255 * 3 + 1];
    // SAFETY: c_path is NUL-terminated, request and reply live through the
    // call, and the reply's size is passed with it.
    let status = unsafe {
        libc::getattrlist(
            c_path.as_ptr(),
            (&mut request as *mut libc::attrlist).cast(),
            reply.as_mut_ptr().cast(),
            reply.len(),
            libc::FSOPT_NOFOLLOW,
        )
    };
    if status != 0 {
        return None;
    }
    // attrreference_t: the name's offset from the reference itself, and its
    // length with the NUL.
    let offset = i32::from_ne_bytes(reply.get(4..8)?.try_into().ok()?);
    let length = u32::from_ne_bytes(reply.get(8..12)?.try_into().ok()?) as usize;
    let start = usize::try_from(4 + i64::from(offset)).ok()?;
    let name = reply.get(start..start.checked_add(length)?.checked_sub(1)?)?;
    (!name.is_empty()).then(|| std::ffi::OsString::from_vec(name.to_vec()))
}

// canonical_path is None on Windows.
#[cfg(all(test, unix))]
mod tests {
    use super::*;

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
