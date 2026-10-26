//! The site report: one JSON line per new (site, kind) of a process, the MQ-13
//! input (plans/cmux-next/chrome-parity/p02-threads.md, section 6). The site
//! table in [`super`] keeps counts for `server.blocking`; this file keeps what a
//! process saw after it panicked or was killed, which no snapshot can read back.

use std::fmt::Write as _;
use std::fs::File;
use std::io::Write as _;
use std::panic::Location;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use super::{BlockingKind, BlockingMode};

/// The environment variable naming the site report's directory: one JSON line
/// per new (site, kind), appended to `<dir>/blocking-<pid>.jsonl`. Unset or
/// empty: no report.
pub const REPORT_ENV: &str = "CMUX_DAEMON_BLOCKING_REPORT";

/// Why [`set_report_dir`] did not take effect.
#[derive(Debug)]
pub enum ReportError {
    /// The report was already chosen: by [`REPORT_ENV`] at the first
    /// violation, or by an earlier [`set_report_dir`].
    AlreadyConfigured,
    /// The report file could not be opened.
    Open { path: PathBuf, source: std::io::Error },
}

impl std::fmt::Display for ReportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AlreadyConfigured => f.write_str("the blocking site report is already chosen"),
            Self::Open { path, source } => {
                write!(f, "cannot open the blocking site report {}: {source}", path.display())
            }
        }
    }
}

impl std::error::Error for ReportError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::AlreadyConfigured => None,
            Self::Open { source, .. } => Some(source),
        }
    }
}

/// This process's append-only report file.
struct SiteReport {
    path: PathBuf,
    file: File,
}

impl SiteReport {
    /// Test and bench tooling, opened once per process: plain std file calls,
    /// not [`crate::checked`], so the report never reports itself.
    fn open(dir: &Path) -> Result<Self, ReportError> {
        let path = dir.join(format!("blocking-{}.jsonl", std::process::id()));
        let file = std::fs::create_dir_all(dir)
            .and_then(|()| std::fs::OpenOptions::new().create(true).append(true).open(&path))
            .map_err(|source| ReportError::Open { path: path.clone(), source })?;
        Ok(Self { path, file })
    }

    /// One `write` of one line to an `O_APPEND` file, so lines from concurrent
    /// threads do not interleave.
    fn append(&self, line: &ReportLine<'_>) {
        if let Err(error) = (&self.file).write_all(line.to_json().as_bytes()) {
            eprintln!("cmux_threads: blocking site report {}: {error}", self.path.display());
        }
    }
}

static REPORT: OnceLock<Option<SiteReport>> = OnceLock::new();

fn site_report() -> Option<&'static SiteReport> {
    REPORT
        .get_or_init(|| {
            let dir = std::env::var_os(REPORT_ENV).filter(|dir| !dir.is_empty())?;
            SiteReport::open(Path::new(&dir))
                .map_err(|error| eprintln!("cmux_threads: {error}"))
                .ok()
        })
        .as_ref()
}

/// Sends this process's site report to `<dir>/blocking-<pid>.jsonl`, in place
/// of [`REPORT_ENV`], and returns the file's path. The report is chosen once
/// per process, at the first violation or by the first call here.
pub fn set_report_dir(dir: &Path) -> Result<PathBuf, ReportError> {
    if REPORT.get().is_some() {
        return Err(ReportError::AlreadyConfigured);
    }
    let report = SiteReport::open(dir)?;
    let path = report.path.clone();
    REPORT.set(Some(report)).map_err(|_| ReportError::AlreadyConfigured)?;
    Ok(path)
}

/// The path of this process's site report, once one is open (after the first
/// violation with [`REPORT_ENV`] set, or after [`set_report_dir`]).
pub fn report_path() -> Option<&'static Path> {
    REPORT.get().and_then(Option::as_ref).map(|report| report.path.as_path())
}

/// Appends a first sighting made on the current thread to the report, if this
/// process has one. Called by the violation path before a Panic-mode panic.
pub(super) fn report_first_sighting(
    location: &Location<'_>,
    kind: BlockingKind,
    mode: BlockingMode,
    overflow: bool,
) {
    let Some(report) = site_report() else { return };
    let thread = std::thread::current();
    report.append(&ReportLine {
        pid: std::process::id(),
        thread: thread.name().unwrap_or("<unnamed>"),
        location,
        kind,
        mode,
        overflow,
    });
}

/// One report line: the MQ-13 key (location, kind, thread) of a first sighting.
struct ReportLine<'a> {
    pid: u32,
    thread: &'a str,
    location: &'a Location<'a>,
    kind: BlockingKind,
    mode: BlockingMode,
    /// The site table was full: the site is in the report but not in
    /// [`super::snapshot`].
    overflow: bool,
}

impl ReportLine<'_> {
    fn to_json(&self) -> String {
        let mut line = String::with_capacity(192);
        let _ = write!(line, "{{\"pid\":{},\"thread\":", self.pid);
        push_json_string(&mut line, self.thread);
        line.push_str(",\"file\":");
        push_json_string(&mut line, self.location.file());
        let mode = match self.mode {
            BlockingMode::Record => "record",
            BlockingMode::Panic => "panic",
        };
        let _ = writeln!(
            line,
            ",\"line\":{},\"column\":{},\"kind\":\"{}\",\"mode\":\"{mode}\",\"overflow\":{}}}",
            self.location.line(),
            self.location.column(),
            self.kind.as_str(),
            self.overflow,
        );
        line
    }
}

/// Appends `value` as a JSON string (RFC 8259 escapes).
fn push_json_string(out: &mut String, value: &str) {
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if u32::from(ch) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", u32::from(ch));
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_line_is_one_json_object_with_the_mq13_key() {
        let location = Location::caller();
        let line = ReportLine {
            pid: 42,
            thread: "mux-conn",
            location,
            kind: BlockingKind::IpcReply,
            mode: BlockingMode::Panic,
            overflow: false,
        }
        .to_json();
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
        let expected = format!(
            "{{\"pid\":42,\"thread\":\"mux-conn\",\"file\":\"{}\",\"line\":{},\"column\":{},\
             \"kind\":\"ipc-reply\",\"mode\":\"panic\",\"overflow\":false}}\n",
            location.file(),
            location.line(),
            location.column(),
        );
        assert_eq!(line, expected);
    }

    #[test]
    fn json_strings_escape_quotes_backslashes_and_controls() {
        let mut out = String::new();
        push_json_string(&mut out, "a\"b\\c\nd\u{1}é");
        assert_eq!(out, "\"a\\\"b\\\\c\\nd\\u0001é\"");
    }
}
