//! Real Security.framework coverage; no signing certificate or keychain needed.
use super::*;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

const CHILD_SOCKET: &str = "CMUX_SIGN_CLONE_TEST_SOCKET";
const CHILD_TEST: &str = "caller::macos::sign_clone_tests::sign_clone_fixture_child";

// Only the parent test opts into this fixture. Its socket keeps the child
// alive while the parent checks its audit-token-bound code identity.
#[test]
fn sign_clone_fixture_child() {
    let Some(socket) = std::env::var_os(CHILD_SOCKET) else { return };
    let mut stream = UnixStream::connect(socket).expect("connect fixture socket");
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    stream.write_all(b"ready").unwrap();
    let mut release = [0];
    stream.read_exact(&mut release).expect("parent releases fixture");
}

struct FixtureChild(Child);

impl Drop for FixtureChild {
    fn drop(&mut self) {
        // Only this test's own child; also runs on assertion failure. The
        // child has no descendants and never starts an app or daemon.
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn sign(path: &Path, identifier: &str) {
    let result = Command::new("/usr/bin/codesign")
        .args(["--force", "--sign", "-", "--identifier", identifier])
        .arg(path)
        .output()
        .expect("codesign is available on the fleet Mac");
    assert!(result.status.success(), "codesign: {}", String::from_utf8_lossy(&result.stderr));
}

fn valid_static(path: &Path, requirement: CFTypeRef) -> Result<Owned, String> {
    let code = static_code(path)?;
    // SAFETY: code is live; requirement is null or a live object owned by the test.
    status(unsafe { SecStaticCodeCheckValidity(code.0, 0, requirement) }, "fixture validity")?;
    Ok(code)
}

fn running_matches(executable: &Path, installed: &Owned) -> bool {
    let socket_dir = cmux_unix_socket::short_test_dir("signpeer");
    let socket = socket_dir.path().join("peer.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let _child = FixtureChild(
        Command::new(executable)
            .args(["--exact", CHILD_TEST, "--nocapture", "--test-threads=1"])
            .env(CHILD_SOCKET, &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .spawn()
            .expect("launch signed fixture"),
    );
    let mut entry = libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: one live pollfd. Bound the accept, including a child that failed
    // to launch its selected test; no polling loop or indefinite accept.
    assert_eq!(unsafe { libc::poll(&raw mut entry, 1, 15_000) }, 1, "fixture connects");
    assert_ne!(entry.revents & libc::POLLIN, 0);
    let (mut stream, _) = listener.accept().unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    let mut ready = [0; 5];
    stream.read_exact(&mut ready).unwrap();
    assert_eq!(&ready, b"ready");
    let token = peer_audit_token(stream.as_raw_fd()).expect("real socket peer token");
    let guest = guest_code(&token).expect("resolve live fixture by audit token");
    let accepted = check_running_requirement(&guest, installed).is_ok();
    stream.write_all(b"x").unwrap();
    accepted
}

/// Mutate executable code, not its Mach-O header or signature padding. Rust
/// test executables on the fleet are thin little-endian 64-bit Mach-O files.
fn tamper_text(path: &Path) {
    let mut bytes = std::fs::read(path).unwrap();
    let word = |offset| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
    assert_eq!(word(0), 0xfeed_facf, "thin 64-bit Mach-O fixture");
    let mut command = 32;
    let mut text = None;
    for _ in 0..word(16) {
        let size = word(command + 4) as usize;
        assert!(size >= 8 && command + size <= bytes.len());
        if word(command) == 0x19 {
            for index in 0..word(command + 64) as usize {
                let section = command + 72 + index * 80;
                assert!(section + 80 <= command + size);
                if &bytes[section..section + 7] == b"__text\0"
                    && &bytes[section + 16..section + 23] == b"__TEXT\0"
                {
                    text = Some(word(section + 48) as usize);
                }
            }
        }
        command += size;
    }
    let offset = text.expect("fixture contains executable __TEXT,__text");
    bytes[offset] ^= 1;
    std::fs::write(path, bytes).unwrap();
}

#[test]
fn sign_clone_real_signatures_match_and_resigned_or_tampered_copies_fail() {
    let dir = cmux_unix_socket::short_test_dir("signreal");
    let installed_path = dir.path().join("installed");
    std::fs::copy(std::env::current_exe().unwrap(), &installed_path).unwrap();
    sign(&installed_path, "com.cmuxterm.test.sign-clone");
    let installed = valid_static(&installed_path, ptr::null()).expect("valid ad-hoc fixture");
    let requirement = designated_requirement(&installed).expect("real designated requirement");

    let clone = dir.path().join("com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.fixture/cmux NIGHTLY.app.bundle/Contents/MacOS/fixture");
    std::fs::create_dir_all(clone.parent().unwrap()).unwrap();
    std::fs::copy(&installed_path, &clone).unwrap();
    valid_static(&clone, requirement.0).expect("copied signature matches installed requirement");
    assert!(running_matches(&clone, &installed), "matching running code resolves");

    // Ad-hoc fixtures exercise the real requirement matcher, not the
    // production Apple-anchored Team ID policy. That policy still refuses them.
    assert!(static_code_signed_by(&clone, "ABCDEFGHIJ", 0, "team policy").is_err());

    let resigned = dir.path().join("resigned");
    std::fs::copy(&installed_path, &resigned).unwrap();
    sign(&resigned, "com.cmuxterm.test.different-clone");
    valid_static(&resigned, ptr::null()).expect("re-signed code is independently valid");
    assert!(valid_static(&resigned, requirement.0).is_err(), "different requirement refused");
    assert!(!running_matches(&resigned, &installed), "different running identity refused");

    let tampered = dir.path().join("tampered");
    std::fs::copy(&installed_path, &tampered).unwrap();
    tamper_text(&tampered);
    static_code(&tampered).expect("tampered Mach-O remains parseable");
    assert!(valid_static(&tampered, requirement.0).is_err(), "modified code seal refused");
    // Never execute the tampered binary. TempDir removes only these copies.
}
