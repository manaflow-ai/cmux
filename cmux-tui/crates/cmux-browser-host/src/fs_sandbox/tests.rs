use super::*;

fn sandbox() -> (FsSandbox, PathBuf, PathBuf) {
    let base = std::env::temp_dir().join(format!(
        "fs-sandbox-{}-{}",
        std::process::id(),
        std::thread::current().name().unwrap_or("t").replace("::", "-")
    ));
    let _ = std::fs::remove_dir_all(&base);
    let root = base.join("root");
    let outside = base.join("outside");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    (FsSandbox::with_tmp(&root, base.join("tmp")), root, outside)
}

#[test]
fn intermediate_symlinks_cannot_leave_the_root() {
    let (fs, root, outside) = sandbox();
    std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
    let made = fs.call("mkdir", &json!({"path": "link/a/b", "recursive": true}));
    assert_eq!(made["error"]["code"], "EACCES", "{made}");
    assert!(!outside.join("a").exists());
    let written = fs.call("writeFile", &json!({"path": "link/x.txt", "base64": "aGk="}));
    assert_eq!(written["error"]["code"], "EACCES");
}

#[test]
fn a_dangling_final_symlink_cannot_write_outside() {
    let (fs, root, outside) = sandbox();
    std::os::unix::fs::symlink(outside.join("created.txt"), root.join("dang")).unwrap();
    let written = fs.call("writeFile", &json!({"path": "dang", "base64": "aGk="}));
    assert_eq!(written["error"]["code"], "EACCES", "{written}");
    assert!(!outside.join("created.txt").exists());
}

#[test]
fn the_temp_root_is_the_sessions_own() {
    let (fs, _root, _outside) = sandbox();
    let shared = std::env::temp_dir().join("not-this-session.txt");
    let read = fs.call("writeFile", &json!({"path": shared.display().to_string(), "base64": ""}));
    assert_eq!(read["error"]["code"], "EACCES", "{read}");
    let tmp = fs.call("resolve", &json!({"path": "."}));
    assert!(tmp["ok"].is_string());
}

#[test]
fn base64_round_trips() {
    for sample in [&b""[..], b"h", b"hi", b"hi!", b"\x00\xff\x10binary"] {
        assert_eq!(base64_decode(&base64_encode(sample)).unwrap(), sample);
    }
    assert_eq!(base64_encode(b"hi"), "aGk=");
    assert!(base64_decode("@@").is_none());
    // What the page may send: no padding, line breaks.
    assert_eq!(base64_decode("aGk").unwrap(), b"hi");
    assert_eq!(base64_decode("aGkh\naGk=\r\n").unwrap(), b"hi!hi");
}
