use super::*;

fn tar_xz() -> Vec<u8> {
    let mut tar = tar::Builder::new(Vec::new());
    // Enough incompressible-ish bytes that xz's output outgrows a pipe buffer.
    let body: Vec<u8> =
        (0..400_000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    let mut h = tar::Header::new_gnu();
    h.set_size(body.len() as u64);
    h.set_mode(0o755);
    h.set_cksum();
    tar.append_data(&mut h, "pkg/bin/tool", body.as_slice()).unwrap();
    xz(tar.into_inner().unwrap())
}

/// `xz -zc -0` of `bytes`, fed from a thread so a large input cannot fill both pipes.
fn xz(bytes: Vec<u8>) -> Vec<u8> {
    let mut child = std::process::Command::new("xz")
        .args(["-zc", "-0"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let writer = std::thread::spawn(move || {
        use std::io::Write as _;
        stdin.write_all(&bytes).unwrap();
    });
    let out = child.wait_with_output().unwrap();
    writer.join().unwrap();
    assert!(out.status.success());
    out.stdout
}

/// Our xz child was already reaped by `unpack_xz`: `waitpid` on it says there is no such child (ECHILD).
/// A child still running (or a zombie no one waited) would return 0 or its pid.
#[cfg(unix)]
fn reaped(pid: u32) -> bool {
    let mut status = 0;
    // SAFETY: waitpid with WNOHANG on a pid this process spawned; it only reads that child's state.
    let r = unsafe { libc::waitpid(pid as libc::pid_t, &mut status, libc::WNOHANG) };
    r == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD)
}

#[cfg(not(unix))]
fn reaped(_pid: u32) -> bool {
    true
}

type Unpacked = Result<BTreeMap<String, (Vec<u8>, bool)>>;

fn run(archive: Vec<u8>, strip: usize) -> (Unpacked, u32) {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut pid = 0;
        let out = unpack_xz(&archive, strip, |p| pid = p);
        let _ = tx.send((out.map_err(|e| e.to_string()), pid));
    });
    let (out, pid) =
        rx.recv_timeout(std::time::Duration::from_secs(30)).expect("unpack_xz deadlocked");
    (out.map_err(Into::into), pid)
}

#[test]
fn valid_xz_unpacks_and_reaps_xz() {
    let (out, pid) = run(tar_xz(), 1);
    let files = out.unwrap();
    let (bytes, exec) = &files["bin/tool"];
    assert_eq!(bytes.len(), 400_000);
    assert!(exec);
    assert!(reaped(pid), "xz {pid} still running");
}

#[test]
fn truncated_xz_errors_and_reaps_xz() {
    let mut archive = tar_xz();
    archive.truncate(archive.len() / 2);
    let (out, pid) = run(archive, 1);
    let err = out.unwrap_err().to_string();
    assert!(!err.to_lowercase().contains("broken pipe"), "feeder error hid the cause: {err}");
    assert!(reaped(pid), "xz {pid} still running");
}

#[test]
fn strip_error_wins_over_the_feeders_broken_pipe() {
    // A path escaping the tree fails in read_tar early, while xz still has input: the cause must surface.
    let mut tar = tar::Builder::new(Vec::new());
    let mut h = tar::Header::new_gnu();
    h.set_size(1);
    h.set_cksum();
    let name = b"pkg/../../evil";
    h.as_old_mut().name[..name.len()].copy_from_slice(name);
    h.set_cksum();
    tar.append(&h, &b"x"[..]).unwrap();
    let mut rest = tar::Header::new_gnu();
    // Incompressible, so the compressed archive is far bigger than a pipe buffer and the feeder is still
    // writing when read_tar fails.
    let mut x = 0x9e37_79b9_7f4a_7c15u64;
    let pad: Vec<u8> = (0..2_000_000)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 32) as u8
        })
        .collect();
    rest.set_size(pad.len() as u64);
    rest.set_cksum();
    tar.append_data(&mut rest, "pkg/pad", pad.as_slice()).unwrap();
    let archive = xz(tar.into_inner().unwrap());
    assert!(archive.len() > 1_000_000, "the pad must stay incompressible");
    let (res, pid) = run(archive, 1);
    let err = res.unwrap_err().to_string();
    assert!(err.contains("leaves the tree"), "got {err}");
    assert!(reaped(pid), "xz {pid} still running");
}
