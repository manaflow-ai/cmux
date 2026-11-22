//! WAL archiving and base backups (server.md 8.4).
//!
//! [`archive_wal`] is Postgres's `archive_command`: it returns `Ok` only
//! after the segment is durable under its final name (copy to a temporary
//! file, fsync, hard-link to the final name, fsync the directory). The hard
//! link never replaces an existing file: an existing segment with the same
//! bytes is success (a retry after a crash), different bytes is an error.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use super::Postgres;
use crate::error::{Error, IoContext, Result};
use crate::process::Cmd;
use crate::{fsx, sys};

/// How a base backup gets its WAL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WalMethod {
    /// `-X none`: the daily backup; restore replays the WAL archive.
    None,
    /// `-X stream`: self-contained, for the final backup before `--purge`
    /// deletes the WAL archive with the rest of the state.
    Stream,
}

/// A WAL file name: `[A-Za-z0-9._-]`, not `.` or `..` (segments, `.history`,
/// `.backup`, `.partial`).
fn valid_wal_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name != "."
        && name != ".."
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn same_content(a: &Path, b: &Path) -> io::Result<bool> {
    let (mut fa, mut fb) = (File::open(a)?, File::open(b)?);
    if fa.metadata()?.len() != fb.metadata()?.len() {
        return Ok(false);
    }
    let (mut ba, mut bb) = (vec![0u8; 64 * 1024], vec![0u8; 64 * 1024]);
    loop {
        let n = fa.read(&mut ba)?;
        if n == 0 {
            return Ok(true);
        }
        fb.read_exact(&mut bb[..n])?;
        if ba[..n] != bb[..n] {
            return Ok(false);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Archived {
    Stored,
    /// The same bytes were already archived (a retry).
    AlreadyPresent,
}

/// Copies `src` (`%p`, relative to the data directory, which is the
/// archiver's working directory) to `<wal_dir>/<name>` (`%f`).
pub fn archive_wal(wal_dir: &Path, src: &Path, name: &str) -> Result<Archived> {
    if !valid_wal_name(name) {
        return Err(Error::usage(format!("invalid WAL file name {name:?}")));
    }
    let dest = wal_dir.join(name);
    if dest.exists() {
        return match same_content(src, &dest).ctx(dest.display())? {
            // A retry after a crash: the earlier link may not be durable
            // yet, so the file and the directory are synced before success.
            true => {
                File::open(&dest).and_then(|f| f.sync_all()).ctx(dest.display())?;
                sys::fsync_dir(wal_dir).ctx(wal_dir.display())?;
                Ok(Archived::AlreadyPresent)
            }
            false => Err(Error::rejected(format!(
                "{} exists with other content; refusing to overwrite",
                dest.display()
            ))),
        };
    }
    let tmp = fsx::temp_sibling(&dest, "tmp");
    let result = (|| -> Result<()> {
        let mut input = File::open(src).ctx(src.display())?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut out = options.open(&tmp).ctx(tmp.display())?;
        io::copy(&mut input, &mut out).ctx(tmp.display())?;
        out.sync_all().ctx(tmp.display())?;
        match fs::hard_link(&tmp, &dest) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                if !same_content(src, &dest).ctx(dest.display())? {
                    return Err(Error::rejected(format!(
                        "{} appeared with other content",
                        dest.display()
                    )));
                }
            }
            Err(e) => return Err(Error::io(dest.display(), e)),
        }
        fs::remove_file(&tmp).ctx(tmp.display())?;
        sys::fsync_dir(wal_dir).ctx(wal_dir.display())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result.map(|()| Archived::Stored)
}

/// `YYYYMMDDTHHMMSSZ` for a Unix time in ms (UTC).
pub fn utc_stamp(ms: u64) -> String {
    let secs = ms / 1000;
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Civil date from days since 1970-01-01 (proleptic Gregorian).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}{month:02}{day:02}T{:02}{:02}{:02}Z", rem / 3600, (rem % 3600) / 60, rem % 60)
}

impl Postgres<'_> {
    /// `pg_basebackup -Ft -z -c fast` into the new directory `dest`.
    pub fn basebackup(&self, dest: &Path, wal: WalMethod) -> Result<PathBuf> {
        if fsx::exists_no_follow(dest) {
            return Err(Error::rejected(format!("{} exists; refusing", dest.display())));
        }
        let x = match wal {
            WalMethod::None => "none",
            WalMethod::Stream => "stream",
        };
        let cmd = Cmd::new(self.bin("pg_basebackup")).arg("-D").arg(dest);
        let cmd = cmd.args(["-Ft", "-z", "-X", x, "-c", "fast", "-w"]);
        let result = self.runner.check(&self.admin_env(cmd));
        if result.is_err() {
            let _ = fsx::remove_tree(dest);
        }
        result.map(|_| dest.to_path_buf())
    }

    /// The daily-style backup into `<state>/backups/base/<stamp>`.
    pub fn backup_now(&self, now_ms: u64) -> Result<PathBuf> {
        let base = self.state_dir("backups/base");
        fsx::ensure_dir(&base, 0o700)?;
        self.basebackup(&base.join(utc_stamp(now_ms)), WalMethod::None)
    }

    /// The newest archived WAL file name, if any.
    pub fn last_wal(&self) -> Option<String> {
        let dir = fsx::local(&self.layout.wal_archive());
        fs::read_dir(dir)
            .ok()?
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| !n.starts_with('.'))
            .max()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamps_are_utc_civil_time() {
        assert_eq!(utc_stamp(0), "19700101T000000Z");
        // 2026-10-02T22:01:14Z
        assert_eq!(utc_stamp(1_790_978_474_000), "20261002T220114Z");
        assert_eq!(utc_stamp(951_782_400_000), "20000229T000000Z");
    }

    #[test]
    fn archive_is_idempotent_and_refuses_other_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let wal = tmp.path().join("wal");
        fs::create_dir(&wal).unwrap();
        let src = tmp.path().join("seg");
        fs::write(&src, b"segment-1").unwrap();
        let name = "000000010000000000000001";
        assert_eq!(archive_wal(&wal, &src, name).unwrap(), Archived::Stored);
        assert_eq!(fs::read(wal.join(name)).unwrap(), b"segment-1");
        assert_eq!(archive_wal(&wal, &src, name).unwrap(), Archived::AlreadyPresent);
        fs::write(&src, b"segment-X").unwrap();
        assert!(archive_wal(&wal, &src, name).is_err());
        assert_eq!(fs::read(wal.join(name)).unwrap(), b"segment-1");
        assert!(archive_wal(&wal, &src, "../escape").is_err());
        let leftovers: Vec<_> = fs::read_dir(&wal).unwrap().flatten().collect();
        assert_eq!(leftovers.len(), 1, "no temporary files remain");
    }
}
