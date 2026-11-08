//! Restores only evidence recorded by the test-tampering detector. Callers name an event and
//! finding, never a path or replacement text. A stale or ambiguous hunk is refused unchanged.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::path::{Component, Path};

const MAX_FILE: u64 = 4 * 1024 * 1024;
// Two Restore clicks must not race each other's compare/rename. Other programs do not take
// this lock: check their writes before replacement and retain the displaced inode afterward.
static RESTORES: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn refused(reason: &str) -> RpcError {
    RpcError::invalid_params(format!("Test changes could not be restored: {reason}"))
        .with_data(json!({"reason": format!("test_tampering.{reason}")}))
}

/// An exact line-bounded match only: never fuzz a patch onto newer edits or choose between
/// repeated assertions. Empty replacement evidence cannot locate a deletion without context.
pub(crate) fn replacement(current: &str, old: &str, new: &str) -> Result<String, RpcError> {
    if new.is_empty() || old == new || old.len() as u64 > MAX_FILE || new.len() as u64 > MAX_FILE {
        return Err(refused("missing_context"));
    }
    let matches = line_matches(current, new);
    let [at] = matches.as_slice() else {
        return Err(refused(if matches.is_empty() { "changed" } else { "ambiguous" }));
    };
    let mut result = current.to_owned();
    result.replace_range(*at..*at + new.len(), old);
    Ok(result)
}

fn line_matches(current: &str, text: &str) -> Vec<usize> {
    if text.is_empty() {
        return Vec::new();
    }
    current
        .match_indices(text)
        .filter_map(|(at, _)| {
            let end = at + text.len();
            let starts_line = at == 0 || current.as_bytes().get(at - 1) == Some(&b'\n');
            let ends_line = text.ends_with('\n')
                || end == current.len()
                || current.as_bytes().get(end) == Some(&b'\n');
            (starts_line && ends_line).then_some(at)
        })
        .take(2)
        .collect()
}

/// Refuse links at every named component, including in-root links, and parent traversal.
/// The authoritative session root is canonicalized, never supplied by the client.
fn target(root: &Path, path: &str) -> Result<std::path::PathBuf, RpcError> {
    let root = root.canonicalize().map_err(|_| refused("missing_root"))?;
    let input = Path::new(path);
    if input.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(refused("outside_root"));
    }
    let target = if input.is_absolute() { input.to_path_buf() } else { root.join(input) };
    let relative = target.strip_prefix(&root).map_err(|_| refused("outside_root"))?;
    let mut checked = root;
    for component in relative.components() {
        if matches!(component, Component::CurDir) {
            continue;
        }
        checked.push(component);
        let meta = std::fs::symlink_metadata(&checked).map_err(|_| refused("missing_file"))?;
        if meta.file_type().is_symlink() {
            return Err(refused("symlink"));
        }
    }
    if !checked.is_file() {
        return Err(refused("not_file"));
    }
    Ok(checked)
}

pub(crate) fn restore(
    root: &Path,
    report: &Value,
    file: usize,
    finding: usize,
) -> Result<Value, RpcError> {
    let _guard = RESTORES.lock().unwrap_or_else(|error| error.into_inner());
    let file =
        report.get("files").and_then(|v| v.get(file)).ok_or_else(|| refused("missing_evidence"))?;
    let path =
        file.get("path").and_then(Value::as_str).ok_or_else(|| refused("missing_evidence"))?;
    let finding = file
        .get("findings")
        .and_then(|v| v.get(finding))
        .ok_or_else(|| refused("missing_evidence"))?;
    let old =
        finding.get("old").and_then(Value::as_str).ok_or_else(|| refused("missing_evidence"))?;
    let new =
        finding.get("new").and_then(Value::as_str).ok_or_else(|| refused("missing_evidence"))?;
    let path = target(root, path)?;
    let anchored = Anchored::open(root, &path)?;
    let mut source = anchored.source()?;
    let metadata = source.metadata().map_err(|_| refused("missing_file"))?;
    if !metadata.is_file() || metadata.len() > MAX_FILE {
        return Err(refused("file_too_large"));
    }
    let mut current = String::new();
    (&mut source)
        .take(MAX_FILE + 1)
        .read_to_string(&mut current)
        .map_err(|_| refused("not_text"))?;
    if current.len() as u64 > MAX_FILE {
        return Err(refused("file_too_large"));
    }
    // A deletion's retained context is also present inside the restored old block.
    // Check that block first: matching the context again would insert the test twice.
    if old != new && !new.is_empty() && line_matches(&current, old).len() == 1 {
        return Ok(json!({"restored": true, "alreadyRestored": true}));
    }
    let restored = replacement(&current, old, new)?;
    let recovery = anchored.replace(root, &path, &current, &restored, &metadata, |_| {})?;
    Ok(json!({"restored": true, "recoveryPath": recovery}))
}

/// Keep the directory descriptor through read, staging and rename. Replacing any parent
/// pathname with a symlink cannot redirect a write or cleanup to another directory.
#[cfg(unix)]
struct Anchored {
    parent: std::fs::File,
    name: std::ffi::CString,
}

#[cfg(unix)]
impl Anchored {
    fn open(root: &Path, path: &Path) -> Result<Self, RpcError> {
        use std::os::fd::{AsRawFd, FromRawFd};
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::OpenOptionsExt;
        let root = root.canonicalize().map_err(|_| refused("missing_root"))?;
        let relative = path.strip_prefix(&root).map_err(|_| refused("outside_root"))?;
        let mut parent = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&root)
            .map_err(|_| refused("missing_root"))?;
        let mut components =
            relative.components().filter(|c| !matches!(c, Component::CurDir)).peekable();
        while let Some(component) = components.next() {
            let name = std::ffi::CString::new(component.as_os_str().as_bytes())
                .map_err(|_| refused("outside_root"))?;
            if components.peek().is_none() {
                return Ok(Self { parent, name });
            }
            // SAFETY: both the live descriptor and NUL-terminated component remain valid.
            let fd = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(refused("changed"));
            }
            // SAFETY: openat returned a new owned descriptor.
            parent = unsafe { std::fs::File::from_raw_fd(fd) };
        }
        Err(refused("outside_root"))
    }

    fn source(&self) -> Result<std::fs::File, RpcError> {
        use std::os::fd::{AsRawFd, FromRawFd};
        // SAFETY: this object owns the directory and name for the whole call.
        let fd = unsafe {
            libc::openat(
                self.parent.as_raw_fd(),
                self.name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(refused("changed"));
        }
        // SAFETY: openat returned a new owned descriptor.
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        Ok(file)
    }

    fn replace(
        &self,
        root: &Path,
        path: &Path,
        current: &str,
        restored: &str,
        metadata: &std::fs::Metadata,
        mut interleave: impl FnMut(bool),
    ) -> Result<std::path::PathBuf, RpcError> {
        use std::os::fd::{AsRawFd, FromRawFd};
        use std::os::unix::fs::MetadataExt;
        let name = std::ffi::CString::new(format!(".cmux-test-restore-{}", uuid::Uuid::now_v7()))
            .map_err(|_| refused("write_failed"))?;
        // SAFETY: the parent/name are live, and the explicit mode is required with O_CREAT.
        let fd = unsafe {
            libc::openat(
                self.parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600 as libc::c_uint,
            )
        };
        if fd < 0 {
            return Err(refused("write_failed"));
        }
        // SAFETY: openat returned a new owned descriptor.
        let mut staged = unsafe { std::fs::File::from_raw_fd(fd) };
        let result = (|| {
            staged.set_permissions(metadata.permissions()).map_err(|_| refused("write_failed"))?;
            staged.write_all(restored.as_bytes()).map_err(|_| refused("write_failed"))?;
            staged.sync_all().map_err(|_| refused("write_failed"))?;
            interleave(false);
            // Check that the named directory is still the pinned one, and the same inode
            // still has the bytes we read. This refuses a rename or edit while staging.
            target(root, path.to_str().ok_or_else(|| refused("not_text"))?)?;
            let fresh = Self::open(root, path)?;
            let parent = self.parent.metadata().map_err(|_| refused("changed"))?;
            let fresh_parent = fresh.parent.metadata().map_err(|_| refused("changed"))?;
            let mut source = self.source()?;
            let now = source.metadata().map_err(|_| refused("changed"))?;
            if parent.dev() != fresh_parent.dev()
                || parent.ino() != fresh_parent.ino()
                || now.dev() != metadata.dev()
                || now.ino() != metadata.ino()
                || now.len() > MAX_FILE
            {
                return Err(refused("changed"));
            }
            let mut bytes = Vec::new();
            (&mut source)
                .take(MAX_FILE + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| refused("changed"))?;
            if bytes != current.as_bytes() {
                return Err(refused("changed"));
            }
            interleave(true);
            // A compare followed by rename can discard a writer racing this last check.
            // Exchange keeps the actual displaced inode, including any writes through an
            // already-open descriptor. Never unlink it or attempt a racy rollback. One
            // recovery file remains per successful Restore (normally at most MAX_FILE).
            self.exchange(&name)?;
            Ok(path.with_file_name(name.to_string_lossy().as_ref()))
        })();
        if result.is_err() {
            // SAFETY: unlink only the unique staging name we created in the pinned parent.
            unsafe {
                libc::unlinkat(self.parent.as_raw_fd(), name.as_ptr(), 0);
            }
        }
        result
    }

    fn exchange(&self, staged: &std::ffi::CStr) -> Result<(), RpcError> {
        use std::os::fd::AsRawFd;
        let fd = self.parent.as_raw_fd();
        #[cfg(any(target_os = "linux", target_os = "android"))]
        // SAFETY: live directory fd and NUL-terminated names. The syscall also supports
        // musl, which does not expose a renameat2 wrapper.
        let result = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                fd,
                staged.as_ptr(),
                fd,
                self.name.as_ptr(),
                libc::RENAME_EXCHANGE,
            )
        };
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        // SAFETY: both names are relative to the same pinned directory; no parent path
        // is followed, even if a concurrent process replaced it with a symlink.
        let result = unsafe {
            libc::renameatx_np(fd, staged.as_ptr(), fd, self.name.as_ptr(), libc::RENAME_SWAP)
        };
        #[cfg(not(any(
            target_os = "linux",
            target_os = "android",
            target_os = "macos",
            target_os = "ios"
        )))]
        let result = -1;
        if result < 0 { Err(refused("exchange_failed")) } else { Ok(()) }
    }
}

/// No pathname-based fallback on platforms without the confined descriptor operation.
#[cfg(not(unix))]
struct Anchored;
#[cfg(not(unix))]
impl Anchored {
    fn open(_: &Path, _: &Path) -> Result<Self, RpcError> {
        Err(refused("unsupported_platform"))
    }
    fn source(&self) -> Result<std::fs::File, RpcError> {
        Err(refused("unsupported_platform"))
    }
    fn replace(
        &self,
        _: &Path,
        _: &Path,
        _: &str,
        _: &str,
        _: &std::fs::Metadata,
        _: impl FnMut(bool),
    ) -> Result<std::path::PathBuf, RpcError> {
        Err(refused("unsupported_platform"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restores_only_the_named_hunk_and_preserves_unrelated_changes() {
        assert_eq!(
            replacement(
                "other edit\nexpect(n).toBeTruthy();\nlast\n",
                "expect(n).toEqual(3);",
                "expect(n).toBeTruthy();"
            )
            .unwrap(),
            "other edit\nexpect(n).toEqual(3);\nlast\n"
        );
    }

    #[test]
    fn stale_ambiguous_empty_and_partial_lines_are_refused() {
        for (current, new) in [("newer", "old"), ("x\nx\n", "x"), ("any", ""), ("prefix x\n", "x")]
        {
            assert!(replacement(current, "restored", new).is_err());
        }
    }

    #[test]
    fn deleted_assertion_restores_at_unique_context() {
        assert_eq!(
            replacement("test {\n}\n", "test {\n  assert!(ok);\n}", "test {\n}").unwrap(),
            "test {\n  assert!(ok);\n}\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn disk_restore_is_scoped_and_refuses_stale_evidence() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.test.ts");
        std::fs::write(&path, "before\nexpect(n).toBeTruthy();\nafter\n").unwrap();
        let report = json!({"files":[{"path":"a.test.ts","findings":[{"old":"expect(n).toEqual(3);","new":"expect(n).toBeTruthy();"}]}]});
        let receipt = restore(dir.path(), &report, 0, 0).unwrap();
        let recovery = receipt["recoveryPath"].as_str().unwrap();
        assert_eq!(
            std::fs::read_to_string(recovery).unwrap(),
            "before\nexpect(n).toBeTruthy();\nafter\n"
        );
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "before\nexpect(n).toEqual(3);\nafter\n"
        );
        assert_eq!(restore(dir.path(), &report, 0, 0).unwrap()["alreadyRestored"], true);
        std::fs::write(&path, "a newer edit\n").unwrap();
        assert!(restore(dir.path(), &report, 0, 0).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn one_sided_deletion_restore_does_not_duplicate_the_test_on_retry() {
        let context = "// retained boundary";
        for old in [
            "// retained boundary\n#[test]\nfn removed() { assert!(true); }",
            "#[test]\nfn removed() { assert!(true); }\n// retained boundary",
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("tests.rs");
            std::fs::write(&path, format!("{context}\n")).unwrap();
            let report =
                json!({"files":[{"path":"tests.rs","findings":[{"old":old,"new":context}]}]});
            let first = restore(dir.path(), &report, 0, 0).unwrap();
            let expected = format!("{old}\n");
            assert_eq!(std::fs::read_to_string(&path).unwrap(), expected);
            assert_eq!(
                std::fs::read_to_string(first["recoveryPath"].as_str().unwrap()).unwrap(),
                format!("{context}\n")
            );
            assert_eq!(line_matches(&expected, context).len(), 1);
            let second = restore(dir.path(), &report, 0, 0).unwrap();
            assert_eq!(second, json!({"restored":true,"alreadyRestored":true}));
            assert_eq!(std::fs::read_to_string(&path).unwrap(), expected);
            assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 2);
        }
    }

    #[test]
    fn path_escape_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        assert!(target(dir.path(), "../other.test.ts").is_err());
        assert!(target(dir.path(), "/etc/passwd").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_refused_even_inside_the_root() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("real"), "x").unwrap();
        std::os::unix::fs::symlink(dir.path().join("real"), dir.path().join("linked.test.ts"))
            .unwrap();
        assert!(target(dir.path(), "linked.test.ts").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn racing_content_and_inode_replacements_are_preserved() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.test.ts");
        std::fs::write(&path, "new\n").unwrap();
        let canonical = path.canonicalize().unwrap();
        let anchored = Anchored::open(dir.path(), &canonical).unwrap();
        let metadata = anchored.source().unwrap().metadata().unwrap();
        assert!(
            anchored
                .replace(dir.path(), &canonical, "new\n", "old\n", &metadata, |_| {
                    std::fs::write(&path, "concurrent\n").unwrap();
                })
                .is_err()
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "concurrent\n");
        let metadata = anchored.source().unwrap().metadata().unwrap();
        assert!(
            anchored
                .replace(dir.path(), &canonical, "concurrent\n", "old\n", &metadata, |_| {
                    let replacement = dir.path().join("replacement");
                    std::fs::write(&replacement, "concurrent\n").unwrap();
                    std::fs::rename(&replacement, &path).unwrap();
                })
                .is_err()
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "concurrent\n");
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn edits_after_the_final_check_survive_in_the_recovery_file() {
        for replace_inode in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("a.test.ts");
            std::fs::write(&path, "new\n").unwrap();
            let canonical = path.canonicalize().unwrap();
            let anchored = Anchored::open(dir.path(), &canonical).unwrap();
            let metadata = anchored.source().unwrap().metadata().unwrap();
            let recovery = anchored
                .replace(dir.path(), &canonical, "new\n", "old\n", &metadata, |committing| {
                    if committing {
                        if replace_inode {
                            let replacement = dir.path().join("replacement");
                            std::fs::write(&replacement, "concurrent\n").unwrap();
                            std::fs::rename(replacement, &path).unwrap();
                        } else {
                            std::fs::write(&path, "concurrent\n").unwrap();
                        }
                    }
                })
                .unwrap();
            assert_eq!(std::fs::read_to_string(path).unwrap(), "old\n");
            assert_eq!(std::fs::read_to_string(recovery).unwrap(), "concurrent\n");
            assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 2);
        }
    }

    #[cfg(unix)]
    #[test]
    fn an_open_writer_keeps_its_inode_after_restore() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.test.ts");
        std::fs::write(&path, "new\n").unwrap();
        let mut writer = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        let canonical = path.canonicalize().unwrap();
        let anchored = Anchored::open(dir.path(), &canonical).unwrap();
        let metadata = anchored.source().unwrap().metadata().unwrap();
        let recovery =
            anchored.replace(dir.path(), &canonical, "new\n", "old\n", &metadata, |_| {}).unwrap();
        writer.write_all(b"later\n").unwrap();
        assert_eq!(std::fs::read_to_string(path).unwrap(), "old\n");
        assert_eq!(std::fs::read_to_string(recovery).unwrap(), "later\n");
    }

    #[cfg(unix)]
    #[test]
    fn racing_parent_symlink_never_writes_or_cleans_outside_the_root() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let parent = dir.path().join("tests");
        std::fs::create_dir(&parent).unwrap();
        let path = parent.join("a.test.ts");
        std::fs::write(&path, "new\n").unwrap();
        std::fs::write(outside.path().join("a.test.ts"), "outside\n").unwrap();
        let canonical = path.canonicalize().unwrap();
        let anchored = Anchored::open(dir.path(), &canonical).unwrap();
        let metadata = anchored.source().unwrap().metadata().unwrap();
        let moved = dir.path().join("moved");
        assert!(
            anchored
                .replace(dir.path(), &canonical, "new\n", "old\n", &metadata, |_| {
                    std::fs::rename(&parent, &moved).unwrap();
                    std::os::unix::fs::symlink(outside.path(), &parent).unwrap();
                })
                .is_err()
        );
        assert_eq!(std::fs::read_to_string(outside.path().join("a.test.ts")).unwrap(), "outside\n");
        assert_eq!(std::fs::read_to_string(moved.join("a.test.ts")).unwrap(), "new\n");
        assert_eq!(std::fs::read_dir(&moved).unwrap().count(), 1);
        assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 1);
    }

    #[test]
    fn old_block_matches_are_exact_and_line_bounded() {
        assert_eq!(line_matches("old\nold\n", "old").len(), 2);
        assert!(line_matches("prefix old\n", "old").is_empty());
        assert_eq!(line_matches("old\n", "old").len(), 1);
    }
}
