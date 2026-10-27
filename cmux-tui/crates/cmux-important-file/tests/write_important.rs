//! write_important: contents, permissions, refusals and a full disk leave the
//! target whole and no temporary file behind.

use std::fs;
use std::io;
use std::path::Path;

use cmux_important_file::{Mode, Options, Step, WriteError, write_important, write_important_with};

fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn writes_a_new_file_and_leaves_no_temp() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.json");
    write_important(&path, b"{\"a\":1}", Mode::Default).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"{\"a\":1}");
    assert_eq!(names(dir.path()), ["state.json"]);
}

#[test]
fn replaces_an_existing_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.json");
    fs::write(&path, b"old contents that are longer").unwrap();
    write_important(&path, b"new", Mode::Default).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"new");
    assert_eq!(names(dir.path()), ["state.json"]);
}

#[test]
fn a_missing_folder_fails_unless_asked_to_create_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a/b/state.json");
    let error = write_important(&path, b"x", Mode::Default).unwrap_err();
    assert_eq!(error.step(), Step::CreateTemp);
    assert_eq!(error.kind(), io::ErrorKind::NotFound);
    assert!(!error.is_disk_full());

    write_important_with(&path, b"x", &Options::new(Mode::Default).create_parent()).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"x");
}

#[test]
fn a_refused_check_keeps_the_old_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("revoked.krl");
    fs::write(&path, b"old").unwrap();
    let check = |temp: &Path| {
        assert_eq!(fs::read(temp).unwrap(), b"bad");
        Err("ssh-keygen cannot read it".to_owned())
    };
    let error = write_important_with(&path, b"bad", &Options::new(Mode::Default).check(&check))
        .unwrap_err();
    assert!(
        matches!(error, WriteError::Refused { ref reason, .. } if reason.contains("ssh-keygen"))
    );
    assert_eq!(error.step(), Step::Check);
    assert_eq!(fs::read(&path).unwrap(), b"old");
    assert_eq!(names(dir.path()), ["revoked.krl"]);
}

#[test]
fn no_file_name_is_an_error_not_a_panic() {
    let error = write_important(Path::new("/"), b"x", Mode::Default).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn many_writers_of_one_file_never_share_a_temp() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("shared.json");
    std::thread::scope(|scope| {
        for writer in 0..8u8 {
            let path = &path;
            scope.spawn(move || {
                for _ in 0..25 {
                    write_important(path, &[writer; 64], Mode::Default).unwrap();
                }
            });
        }
    });
    let bytes = fs::read(&path).unwrap();
    assert_eq!(bytes.len(), 64);
    assert!(bytes.iter().all(|byte| *byte == bytes[0]), "one writer's whole contents");
    assert_eq!(names(dir.path()), ["shared.json"]);
}

#[test]
fn write_error_into_io_error_keeps_the_kind_and_path() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missing/state.json");
    let error: io::Error = write_important(&path, b"x", Mode::Default).unwrap_err().into();
    assert_eq!(error.kind(), io::ErrorKind::NotFound);
    assert!(error.to_string().contains("state.json"), "{error}");
}

#[cfg(unix)]
mod unix {
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::*;

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o7777
    }

    #[test]
    fn exact_mode_is_set_past_the_umask() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("token");
        write_important(&path, b"secret", Mode::Exact(0o600)).unwrap();
        assert_eq!(mode(&path), 0o600);
        write_important(&path, b"script", Mode::Exact(0o755)).unwrap();
        assert_eq!(mode(&path), 0o755);
    }

    #[test]
    fn keep_mode_keeps_the_replaced_files_bits() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        write_important(&path, b"new", Mode::Keep).unwrap();
        assert_eq!(mode(&path), 0o640);
        assert_eq!(fs::read(&path).unwrap(), b"new");
    }

    #[test]
    fn a_symlinked_target_is_replaced_not_written_through() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real");
        let link = dir.path().join("link");
        fs::write(&real, b"real").unwrap();
        symlink(&real, &link).unwrap();
        write_important(&link, b"new", Mode::Default).unwrap();
        assert_eq!(fs::read(&real).unwrap(), b"real");
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_file());
    }

    #[test]
    fn a_read_only_folder_fails_at_the_temp_and_keeps_the_file() {
        if is_root() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o500)).unwrap();
        let error = write_important(&path, b"new", Mode::Default).unwrap_err();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(error.step(), Step::CreateTemp);
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read(&path).unwrap(), b"old");
    }

    /// Root ignores folder permissions; `id -u` keeps this test free of FFI.
    fn is_root() -> bool {
        std::process::Command::new("id")
            .arg("-u")
            .output()
            .is_ok_and(|out| String::from_utf8_lossy(&out.stdout).trim() == "0")
    }
}

/// The full-disk chaos case: every write to `/dev/full` fails with `ENOSPC`.
#[cfg(target_os = "linux")]
#[test]
fn a_full_disk_is_typed_and_keeps_the_old_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.json");
    fs::write(&path, b"old").unwrap();
    let full = |_temp: &Path| fs::OpenOptions::new().write(true).open("/dev/full");
    let error =
        write_important_with(&path, b"new contents", &Options::new(Mode::Default).open_temp(&full))
            .unwrap_err();
    assert!(error.is_disk_full(), "{error}");
    assert!(
        matches!(error, WriteError::DiskFull { step: Step::Write | Step::Sync, .. }),
        "{error}"
    );
    assert!(error.to_string().contains("the disk is full"), "{error}");
    assert_eq!(io::Error::from(error).kind(), io::ErrorKind::StorageFull);
    assert_eq!(fs::read(&path).unwrap(), b"old");
    assert_eq!(names(dir.path()), ["session.json"]);
}
