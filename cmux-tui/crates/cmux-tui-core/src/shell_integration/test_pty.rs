//! A shell on a pty for the shell-integration tests. Its output arrives
//! through `recv_timeout`, which also gives the one terminal reply a shell
//! may block on: fish 4 asks for the Primary Device Attributes (`CSI c`) at
//! startup and waits up to 10 s for the answer ("could not read response to
//! Primary Device Attribute query"), so a pty without a terminal behind it
//! costs every fish start 10 s. The owner answers each query as it receives
//! the output that holds it, as Ghostty does.
//!
//! The reader thread only reads and forwards: it never writes and never takes
//! a lock, so a test write blocked on a full pty input queue cannot stop the
//! output from draining (the shell then could not read its input, and both
//! sides would block). It holds only its own reader fd; dropping the
//! `TestPty` drops the writer and kills and reaps the shell.

use super::Shell;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::Duration;

/// The Primary Device Attributes queries a shell sends.
const DA1_QUERIES: [&[u8]; 2] = [b"\x1b[c", b"\x1b[0c"];
/// A VT220-class answer with ANSI color, Ghostty's reply.
const DA1_REPLY: &[u8] = b"\x1b[?62;22c";
/// Bytes of one chunk kept for the next, so a query split across two chunks
/// is still seen (one less than the longest query).
const CARRY: usize = 3;

/// A spawned shell, its output stream, and its input.
pub(super) struct TestPty {
    pub(super) spawned: cmux_pty::SpawnedPty,
    received: Receiver<Vec<u8>>,
    writer: Box<dyn Write + Send>,
    /// The last `CARRY` bytes of the previous chunk, already scanned.
    carried: Vec<u8>,
}

impl TestPty {
    /// Opens a pty of `size`, spawns `command` on it and starts the reader.
    pub(super) fn spawn(size: cmux_pty::PtySize, command: cmux_pty::PtyCommand) -> Self {
        let spawned = cmux_pty::open(size).unwrap().spawn(command).unwrap();
        let mut reader = spawned.master.try_clone_reader().unwrap();
        let writer = spawned.master.take_writer().unwrap();
        let (chunks, received) = channel::<Vec<u8>>();
        std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            // EOF, or EIO once the child side closes (Linux); a dropped
            // `TestPty` ends it at the next chunk.
            while let Ok(n) = reader.read(&mut chunk) {
                if n == 0 || chunks.send(chunk[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Self { spawned, received, writer, carried: Vec::new() }
    }

    /// The next chunk of output, after answering the DA1 queries it ends.
    pub(super) fn recv_timeout(&mut self, timeout: Duration) -> Result<Vec<u8>, RecvTimeoutError> {
        let chunk = self.received.recv_timeout(timeout)?;
        let start = self.carried.len();
        self.carried.extend_from_slice(&chunk);
        for _ in 0..da1_queries_ending_after(&self.carried, start) {
            self.write_quietly(DA1_REPLY);
        }
        let scanned = self.carried.len().saturating_sub(CARRY);
        self.carried.drain(..scanned);
        Ok(chunk)
    }

    /// The shell's pid.
    #[cfg(target_os = "macos")]
    pub(super) fn pid(&self) -> u32 {
        self.spawned.child.process_id().expect("a spawned pty child has a pid")
    }

    /// Types `bytes` into the shell.
    pub(super) fn write(&mut self, bytes: &[u8]) {
        self.writer.write_all(bytes).unwrap();
        self.writer.flush().unwrap();
    }

    /// Types `bytes` and ignores a closed pty (for replies and teardown).
    pub(super) fn write_quietly(&mut self, bytes: &[u8]) {
        let _ = self.writer.write_all(bytes).and_then(|()| self.writer.flush());
    }
}

impl Drop for TestPty {
    fn drop(&mut self) {
        let _ = self.spawned.child.kill();
        let _ = self.spawned.child.wait();
    }
}

/// The shell a shell-integration test runs. On macOS always one, on every
/// host: the system's /bin/zsh, and bash 5.3 and fish 4.9.3 from
/// `scripts/ci/pinned-shell.sh` (sha256-pinned; bash compiled and fish
/// unpacked once per host into ~/Library/Caches/cmux/pinned-shells, which
/// needs the network and a C compiler on the first run). A shell it cannot
/// get fails the test, so a Mac never passes a test without its shell.
#[cfg(target_os = "macos")]
pub(super) fn shell_path(shell: Shell) -> Option<PathBuf> {
    Some(match shell {
        Shell::Zsh => PathBuf::from("/bin/zsh"),
        Shell::Bash => pinned("bash-5.3"),
        Shell::Fish => pinned("fish-4.9.3"),
    })
}

/// The shell a shell-integration test runs, or `None` where it is not
/// installed (Linux CI has bash 5.2 and no zsh or fish); the test then
/// calls `skip`.
#[cfg(not(target_os = "macos"))]
pub(super) fn shell_path(shell: Shell) -> Option<PathBuf> {
    let find = |candidates: &[&str]| candidates.iter().map(PathBuf::from).find(|p| p.is_file());
    match shell {
        Shell::Zsh => find(&["/bin/zsh", "/usr/bin/zsh"]),
        Shell::Bash => find(&["/usr/local/bin/bash", "/usr/bin/bash", "/bin/bash"]),
        Shell::Fish => find(&["/usr/local/bin/fish", "/usr/bin/fish"]),
    }
}

/// A pinned shell build (`scripts/ci/pinned-shell.sh`, cached per host).
#[cfg(target_os = "macos")]
fn pinned(name: &str) -> PathBuf {
    let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../scripts/ci/pinned-shell.sh");
    let output = cmux_process::Command::new("/bin/bash")
        .arg(&script)
        .arg(name)
        .output()
        .unwrap_or_else(|error| panic!("{}: {error}", script.display()));
    let stderr = String::from_utf8_lossy(&output.stderr);
    eprint!("{stderr}");
    assert!(
        output.status.success(),
        "{name}: {} failed, so the shell under test cannot run: {stderr}",
        script.display()
    );
    PathBuf::from(String::from_utf8(output.stdout).unwrap().trim())
}

/// Says that a test did not run because its shell is missing (never on
/// macOS, where `shell_path` always has one). nextest keeps a passing
/// shell-integration test's output (`.config/nextest.toml`), so the step log
/// shows the line and a skip never reads as a pass.
pub(super) fn skip(tag: &str, what: &str, why: &str) {
    eprintln!("{tag} {what}: {why}");
}

/// The DA1 queries in `window` that end past its first `start` bytes (the
/// bytes carried from the previous chunk, already answered).
fn da1_queries_ending_after(window: &[u8], start: usize) -> usize {
    DA1_QUERIES
        .iter()
        .map(|query| {
            window
                .windows(query.len())
                .enumerate()
                .filter(|(at, bytes)| bytes == query && at + query.len() > start)
                .count()
        })
        .sum()
}

#[test]
fn a_da1_query_split_across_reads_is_answered_once() {
    // "\x1b[" ends one read, "c" starts the next.
    let first = b"prompt\x1b[".to_vec();
    assert_eq!(da1_queries_ending_after(&first, 0), 0);
    let carried = first[first.len() - CARRY..].to_vec();
    let mut window = carried.clone();
    window.extend_from_slice(b"c\x1b[0c");
    assert_eq!(da1_queries_ending_after(&window, carried.len()), 2);
    // A query wholly inside the carried bytes was answered with its read.
    assert_eq!(da1_queries_ending_after(b"\x1b[c", CARRY), 0);
}
