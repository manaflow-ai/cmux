//! Real Git indexes cross fs-v1 and the pull planner without a whole-index buffer.
use super::*;
use std::fs::File;
use std::io::{Read as _, Write};
use std::time::Instant;

/// Git permits unknown optional extensions whose signature starts uppercase.
/// Keep every staged entry and a valid checksum while making the index large.
fn pad_index(path: &Path, padding: u32) -> u64 {
    struct Hashed {
        file: File,
        hash: ring::digest::Context,
    }
    impl Write for Hashed {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            let count = self.file.write(bytes)?;
            self.hash.update(&bytes[..count]);
            Ok(count)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            self.file.flush()
        }
    }
    let source = File::open(path).unwrap();
    let body = source.metadata().unwrap().len().checked_sub(20).unwrap();
    let part = path.with_extension("padded");
    let mut out = Hashed {
        file: File::create(&part).unwrap(),
        hash: ring::digest::Context::new(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY),
    };
    std::io::copy(&mut source.take(body), &mut out).unwrap();
    out.write_all(b"TEST").unwrap();
    out.write_all(&padding.to_be_bytes()).unwrap();
    std::io::copy(&mut std::io::repeat(0x5a).take(u64::from(padding)), &mut out).unwrap();
    let digest = out.hash.finish();
    out.file.write_all(digest.as_ref()).unwrap();
    out.file.sync_all().unwrap();
    drop(out.file);
    std::fs::rename(part, path).unwrap();
    body + 8 + u64::from(padding) + 20
}

fn padded_index_pull(padding: u32) {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    std::fs::write(remote.join("staged.txt"), "the staged bytes\n").unwrap();
    git(&remote, &["add", "staged.txt"]);
    let expected = staged(&remote);
    let bytes = pad_index(&remote.join(".git/index"), padding);
    assert_eq!(staged(&remote), expected, "padded index must remain valid Git input");

    // Measure only the real CLI pull, not fixture creation. GNU time reports the
    // CLI's peak RSS (excluding the in-process fs service and fixture verifier).
    let rss = socket.with_extension("rss");
    let mut command = if cfg!(target_os = "linux") && Path::new("/usr/bin/time").is_file() {
        let mut command = Command::new("/usr/bin/time");
        command.args(["-f", "%M", "-o"]).arg(&rss);
        command.arg(env!("CARGO_BIN_EXE_cmux-tui"));
        command
    } else {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
    };
    let begin = Instant::now();
    let output = command
        .env("CMUX_TUI_STATE_DIR", state_of(&socket))
        .args(["link", "sync", "pull", "--socket"])
        .arg(&socket)
        .arg(&repo)
        .arg(&remote)
        .output()
        .unwrap();
    let elapsed = begin.elapsed().as_secs_f64();
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(staged(&repo), expected);
    assert_eq!(git(&repo, &["show", ":staged.txt"]), "the staged bytes\n");
    assert_eq!(std::fs::read_to_string(repo.join("staged.txt")).unwrap(), "the staged bytes\n");
    let rss_kib = std::fs::read_to_string(rss).unwrap_or_else(|_| "unavailable".into());
    eprintln!(
        "git_index bytes={bytes} elapsed_s={elapsed:.6} throughput_mib_s={:.3} peak_rss_kib={}",
        bytes as f64 / (1024.0 * 1024.0) / elapsed,
        rss_kib.trim()
    );
}

#[test]
fn git_index_multimegabyte_pull_preserves_staging() {
    padded_index_pull(17 * 1024 * 1024);
}

#[test]
#[ignore = "explicit fleet performance measurement"]
fn git_index_256_mib_pull_throughput() {
    padded_index_pull(256 * 1024 * 1024);
}

#[test]
#[ignore = "explicit fleet regression transfers an index over 1 GiB"]
fn git_index_past_old_1_gib_cap() {
    padded_index_pull((1 << 30) + 13 * 1024 * 1024);
}

#[test]
fn git_index_missing_means_empty_staging() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    std::fs::remove_file(remote.join(".git/index")).unwrap();
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(ok, "{answer}");
    assert_eq!(staged(&repo), "");
}

#[test]
fn git_index_invalid_leaves_local_staging_untouched() {
    let (_root, _sockets, repo, remote, socket) = pushed_repo();
    let before = staged(&repo);
    std::fs::write(remote.join(".git/index"), b"invalid index").unwrap();
    let (ok, answer) = pull(&socket, &repo, &remote);
    assert!(!ok, "{answer}");
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(staged(&repo), before);
}
