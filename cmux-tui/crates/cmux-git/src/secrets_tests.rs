use super::*;

#[test]
fn secrets_are_named() {
    let top = Path::new("/nonexistent");
    for path in [
        ".env",
        ".env.local",
        ".envrc",
        "app/.env.production",
        "id_rsa",
        "keys/id_ed25519",
        "id_ecdsa_work",
        "cert.pem",
        "deploy/server.KEY",
        "bundle.p12",
        ".netrc",
    ] {
        assert!(reason(top, path.as_bytes()).is_some(), "{path}");
    }
    for path in ["README.md", "id_rsa.pub", "src/env.rs", ".envrc-notes/x", "keyboard.rs"] {
        assert_eq!(reason(top, path.as_bytes()), None, "{path}");
    }
}

#[test]
fn registry_files_with_tokens_are_secrets() {
    let dir = std::env::temp_dir().join(format!("cmux-seed-secrets-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(".npmrc"), "//registry.npmjs.org/:_authToken=abc\n").unwrap();
    std::fs::write(dir.join(".pypirc"), "[pypi]\nusername = x\n").unwrap();
    assert!(reason(&dir, b".npmrc").is_some());
    assert_eq!(reason(&dir, b".pypirc"), None);
    // In a subfolder the file is found by its content too, on every filesystem: the token
    // is read from that file (an unreadable one gets another reason), and its own clean
    // sibling is not mistaken for the root's.
    const TOKEN: Option<&str> = Some("package registry credentials file with a token");
    std::fs::create_dir_all(dir.join("pkg")).unwrap();
    std::fs::write(dir.join("pkg/.npmrc"), "//registry.npmjs.org/:_authToken=abc\n").unwrap();
    std::fs::write(dir.join("pkg/.pypirc"), "[pypi]\nusername = x\n").unwrap();
    std::fs::write(dir.join(".pypirc"), "[pypi]\npassword = y\n").unwrap();
    assert_eq!(reason(&dir, b"pkg/.npmrc"), TOKEN);
    assert_eq!(reason(&dir, b"pkg/.pypirc"), None);
    assert_eq!(reason(&dir, b".pypirc"), TOKEN);
    // A folder whose name is not UTF-8 is read by its raw bytes, never a lossy spelling.
    // APFS (macOS) refuses such a name (EILSEQ), so no seed there can hold one; ext4 and
    // the other Linux filesystems take raw bytes, and the Linux runs of the cmux-tui tests
    // (`cmux-tui-rust-check.sh test --os linux`, cmux-tui.yml `test (linux)`) cover this case.
    match std::fs::create_dir_all(dir.join(OsStr::from_bytes(b"bad-\xff"))) {
        Err(e) if cfg!(target_os = "macos") && e.raw_os_error() == Some(libc::EILSEQ) => {}
        created => {
            created.unwrap();
            std::fs::write(
                dir.join(OsStr::from_bytes(b"bad-\xff/.npmrc")),
                "//registry.npmjs.org/:_authToken=abc\n",
            )
            .unwrap();
            assert_eq!(reason(&dir, b"bad-\xff/.npmrc"), TOKEN, "read by its raw path");
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A registry file name on something that is not a regular file is kept here unread: a FIFO
/// would block the walk forever and `/dev/zero` would read without end (cmux#36050 review).
#[test]
fn a_registry_name_on_a_special_file_is_kept_unread() {
    let dir = tempfile_dir("special");
    let fifo = dir.join(".npmrc");
    let c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
    // SAFETY: a valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    std::os::unix::fs::symlink("/dev/zero", dir.join(".pypirc")).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let top = dir.clone();
    std::thread::spawn(move || {
        let _ = tx.send((reason(&top, b".npmrc"), reason(&top, b".pypirc")));
    });
    let (npmrc, pypirc) =
        rx.recv_timeout(std::time::Duration::from_secs(10)).expect("the check returned");
    const KEPT: Option<&str> = Some("package registry credentials file that is not a regular file");
    assert_eq!((npmrc, pypirc), (KEPT, KEPT));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_registry_file_too_long_to_check_stays_here() {
    let dir = tempfile_dir("long");
    let mut text = "x".repeat(REGISTRY_FILE_BYTES as usize);
    text.push_str("\n_authToken=late\n");
    std::fs::write(dir.join(".npmrc"), text).unwrap();
    assert_eq!(
        reason(&dir, b".npmrc"),
        Some("package registry credentials file too long to check for a token")
    );
    std::fs::write(dir.join(".npmrc"), "x".repeat(REGISTRY_FILE_BYTES as usize)).unwrap();
    assert_eq!(reason(&dir, b".npmrc"), None, "a MiB exactly, no token: it goes");
    let _ = std::fs::remove_dir_all(&dir);
}

fn tempfile_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-seed-secrets-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
