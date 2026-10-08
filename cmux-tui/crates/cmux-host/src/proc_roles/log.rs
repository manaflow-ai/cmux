//! A role's output: a bounded ring of files (server.md 5.1, 7.6).
//! `<name>.log` is the newest; at the size bound it becomes `<name>.log.1`
//! and older files move up, the oldest is dropped.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// Bytes per file and files kept (16 MiB x 4).
pub const LOG_FILE_BYTES: u64 = 16 * 1024 * 1024;
pub const LOG_FILES: usize = 4;

pub fn log_path(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.log"))
}

fn numbered(path: &Path, n: usize) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(format!(".{n}"));
    PathBuf::from(s)
}

/// Appends to the ring. Not shared: one writer thread per role run.
pub struct RingLog {
    path: PathBuf,
    file: File,
    len: u64,
    limit: u64,
    files: usize,
}

fn open_append(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}

impl RingLog {
    pub fn open(path: PathBuf, limit: u64, files: usize) -> io::Result<RingLog> {
        let file = open_append(&path)?;
        let len = file.metadata()?.len();
        Ok(RingLog { path, file, len, limit, files: files.max(1) })
    }

    pub fn write_line(&mut self, line: &[u8]) -> io::Result<()> {
        if self.len > 0 && self.len + line.len() as u64 > self.limit {
            self.rotate()?;
        }
        self.file.write_all(line)?;
        self.len += line.len() as u64;
        Ok(())
    }

    fn rotate(&mut self) -> io::Result<()> {
        for n in (1..self.files).rev() {
            let from = if n == 1 { self.path.clone() } else { numbered(&self.path, n - 1) };
            match fs::rename(&from, numbered(&self.path, n)) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
        }
        if self.files == 1 {
            fs::remove_file(&self.path).or_else(|e| match e.kind() {
                io::ErrorKind::NotFound => Ok(()),
                _ => Err(e),
            })?;
        }
        self.file = open_append(&self.path)?;
        self.len = 0;
        Ok(())
    }
}

/// The last `max_bytes` of the ring (older file first), cut to whole lines.
pub fn tail(dir: &Path, name: &str, max_bytes: u64) -> io::Result<Vec<u8>> {
    let newest = log_path(dir, name);
    let mut parts = Vec::new();
    let mut left = max_bytes;
    for n in 0..LOG_FILES {
        if left == 0 {
            break;
        }
        let path = if n == 0 { newest.clone() } else { numbered(&newest, n) };
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::NotFound => break,
            Err(e) => return Err(e),
        };
        let len = file.metadata()?.len();
        let take = len.min(left);
        file.seek(SeekFrom::Start(len - take))?;
        let mut buf = Vec::with_capacity(take as usize);
        file.take(take).read_to_end(&mut buf)?;
        left -= take;
        parts.push(buf);
    }
    let mut out: Vec<u8> = parts.into_iter().rev().flatten().collect();
    if out.len() as u64 == max_bytes
        && let Some(cut) = out.iter().position(|b| *b == b'\n')
    {
        out.drain(..=cut);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_rotates_and_tail_reads_across_files() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = RingLog::open(log_path(dir.path(), "chief"), 20, 3).unwrap();
        for i in 0..10 {
            log.write_line(format!("line {i}\n").as_bytes()).unwrap();
        }
        // 7 bytes per line, 2 lines per file, 3 files kept: lines 4..=9.
        assert!(!numbered(&log_path(dir.path(), "chief"), 3).exists());
        let all = tail(dir.path(), "chief", 1 << 20).unwrap();
        assert_eq!(
            String::from_utf8(all).unwrap(),
            "line 4\nline 5\nline 6\nline 7\nline 8\nline 9\n"
        );
        let last = tail(dir.path(), "chief", 10).unwrap();
        assert_eq!(String::from_utf8(last).unwrap(), "line 9\n");
        assert!(tail(dir.path(), "other", 10).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn log_is_private_and_never_follows_a_symlink() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = log_path(dir.path(), "chief");
        RingLog::open(path.clone(), 100, 2).unwrap().write_line(b"x\n").unwrap();
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let evil = log_path(dir.path(), "evil");
        std::os::unix::fs::symlink(dir.path().join("target"), &evil).unwrap();
        assert!(RingLog::open(evil, 100, 2).is_err());
        assert!(!dir.path().join("target").exists());
    }
}
