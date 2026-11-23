//! The local spool: one `YYYY-MM-DD.jsonl` per UTC day in a 0700 folder, each file 0600, each
//! record one whole line written with one `O_APPEND` write, so lines from two writers never
//! interleave. Files older than [`KEEP_DAYS`] are deleted.

use crate::record::Record;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;

/// Days a spool file is kept, sent or not.
pub const KEEP_DAYS: i64 = 30;
const SUFFIX: &str = ".jsonl";

/// Makes `dir` (and its parents) and narrows it to 0700.
pub fn private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Opens `path` for writing, created 0600; appending when `append`, else truncated.
pub(crate) fn open_private(path: &Path, append: bool) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true);
    if append {
        options.append(true);
    } else {
        options.write(true).truncate(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// The spool file name of the UTC day holding `at_ms`.
pub fn day_file(at_ms: u64) -> String {
    let day = i64::try_from(at_ms)
        .ok()
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map_or_else(|| "1970-01-01".to_owned(), |at| at.format("%Y-%m-%d").to_string());
    format!("{day}{SUFFIX}")
}

/// Appends `record` to its day's file in `dir` as one line.
pub fn append(dir: &Path, record: &Record) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(record).map_err(std::io::Error::other)?;
    line.push(b'\n');
    private_dir(dir)?;
    let mut file = open_private(&dir.join(day_file(record.at)), true)?;
    file.write_all(&line)
}

/// The spool files in `dir`, oldest first (their names sort by day).
pub fn files(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| is_day_file(n))
        .collect();
    names.sort();
    names
}

fn is_day_file(name: &str) -> bool {
    name.strip_suffix(SUFFIX).is_some_and(|day| {
        chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d").is_ok() && day.len() == 10
    })
}

/// Deletes the spool files of days more than [`KEEP_DAYS`] before `now_ms`; returns their names.
pub fn prune(dir: &Path, now_ms: u64) -> Vec<String> {
    let oldest = day_file(now_ms.saturating_sub(
        u64::try_from(KEEP_DAYS).unwrap_or(30).saturating_mul(24 * 60 * 60 * 1000),
    ));
    let mut gone = Vec::new();
    for name in files(dir) {
        if name < oldest && std::fs::remove_file(dir.join(&name)).is_ok() {
            gone.push(name);
        }
    }
    gone
}
