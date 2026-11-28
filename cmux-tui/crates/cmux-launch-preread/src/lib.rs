//! The login-time pre-read of cmux NEXT (`app.backgroundReady` = `warmAtLogin`, off by default).
//!
//! After a reboot the app's code is not in memory: a first open reads about 79 MB from disk
//! (4268 pageins; the app framework 0% resident) and puts the window on screen 851 ms later than a
//! warm open (1427 ms against 576 ms, signed builds, a fleet Mac mini (M4), n=5). At login a
//! LaunchAgent (the bundle's `Contents/Library/LaunchAgents/com.cmux.launch-preread.plist`, which
//! the app registers only while the setting says so: cmux-background-ready's
//! `registers_preread_agent`) runs this reader once. It reads the app's executable and its two big
//! frameworks, in that order, with plain sequential `read()` calls into one reused 1 MiB buffer, so
//! the kernel's page cache holds them when the person first opens the app. No `mmap`, no `mlock`,
//! no `F_NOCACHE`: nothing is pinned, and memory pressure can drop every page again. It runs at
//! background priority, stops at a byte cap or a wall-time cap, whichever comes first, writes
//! nothing but one JSON line (stdout and, on macOS, the system log) and always exits 0. Nothing
//! stays running.
//!
//! This module is the reader's pure part (the plan, the caps, the stop reason, the report), unit
//! tested on any OS; `main.rs` is the few system calls.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The default byte cap: the measured cold read is about 79 MB, so 160 MiB covers it twice over
/// and still bounds a much larger future bundle.
pub const DEFAULT_MAX_BYTES: u64 = 160 * 1024 * 1024;
/// The default wall-time cap.
pub const DEFAULT_MAX_WALL: Duration = Duration::from_secs(5);
/// No argument can raise the byte cap past this.
pub const MAX_BYTES_CEILING: u64 = 1024 * 1024 * 1024;
/// No argument can raise the wall-time cap past this.
pub const MAX_WALL_CEILING: Duration = Duration::from_secs(30);
/// The one read buffer.
pub const BUFFER_BYTES: usize = 1024 * 1024;

/// The bundle's executables folder; every regular file in it is read first, in name order (the
/// app's executable, and with cmux#44204 its stub and the real executable).
pub const MACOS_DIR: &str = "Contents/MacOS";
/// Read after the executables, each only when present.
pub const FRAMEWORK_FILES: [&str; 2] = [
    "Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp",
    "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework",
];

/// The two bounds of one run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Caps {
    pub max_bytes: u64,
    pub max_wall: Duration,
}

impl Default for Caps {
    fn default() -> Self {
        Caps { max_bytes: DEFAULT_MAX_BYTES, max_wall: DEFAULT_MAX_WALL }
    }
}

/// Why a run stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    /// Every planned file was read to its end (or skipped as missing).
    Done,
    /// The byte cap was reached.
    ByteCap,
    /// The wall-time cap was reached.
    TimeCap,
    /// The reader is not inside an app bundle and was given none.
    NoBundle,
    /// The arguments did not parse; nothing was read.
    Usage,
    /// `--dry-run`: the plan was printed and nothing was read.
    DryRun,
}

impl Stop {
    pub fn as_str(self) -> &'static str {
        match self {
            Stop::Done => "done",
            Stop::ByteCap => "byte_cap",
            Stop::TimeCap => "time_cap",
            Stop::NoBundle => "no_bundle",
            Stop::Usage => "usage",
            Stop::DryRun => "dry_run",
        }
    }
}

/// The command line: `cmux-launch-preread [--dry-run] [--bundle PATH] [--max-bytes N] [--max-ms N]`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Args {
    pub dry_run: bool,
    /// The app bundle; without it, the bundle that holds the reader's own executable.
    pub bundle: Option<PathBuf>,
    pub caps: Caps,
}

/// Parses the arguments after the program name. Each cap is clamped to its ceiling, so no argument
/// makes the read unbounded.
pub fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Result<Args, String> {
    let mut out = Args::default();
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--dry-run" => out.dry_run = true,
            "--bundle" => out.bundle = Some(PathBuf::from(value(&mut args, "--bundle")?)),
            "--max-bytes" => {
                let n = number(&value(&mut args, "--max-bytes")?, "--max-bytes")?;
                out.caps.max_bytes = n.min(MAX_BYTES_CEILING);
            }
            "--max-ms" => {
                let n = number(&value(&mut args, "--max-ms")?, "--max-ms")?;
                out.caps.max_wall = Duration::from_millis(n).min(MAX_WALL_CEILING);
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    Ok(out)
}

fn value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next().ok_or_else(|| format!("{flag} needs a value"))
}

fn number(text: &str, flag: &str) -> Result<u64, String> {
    text.parse::<u64>().map_err(|_| format!("{flag} needs a whole number, not {text:?}"))
}

/// The app bundle that holds `exe`: the innermost ancestor named `*.app` that `exe` sits under the
/// `Contents` folder of (the reader is `<app>/Contents/Resources/bin/cmux-launch-preread`).
pub fn bundle_of(exe: &Path) -> Option<PathBuf> {
    exe.ancestors().skip(1).find_map(|dir| {
        let name = dir.file_name()?.to_str()?;
        let is_app = name.len() > ".app".len() && name.ends_with(".app");
        (is_app && exe.starts_with(dir.join("Contents"))).then(|| dir.to_path_buf())
    })
}

/// The files to read, relative to the bundle, in order: each of `macos_files` (the regular files of
/// `Contents/MacOS`, any order; read in name order), then [`FRAMEWORK_FILES`]. A file that turns out
/// missing is skipped at read time.
pub fn plan(macos_files: &[String]) -> Vec<String> {
    let mut names: Vec<&String> =
        macos_files.iter().filter(|n| !n.is_empty() && !n.contains('/')).collect();
    names.sort();
    names.dedup();
    names
        .into_iter()
        .map(|n| format!("{MACOS_DIR}/{n}"))
        .chain(FRAMEWORK_FILES.iter().map(|f| (*f).to_owned()))
        .collect()
}

/// The running count against the caps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    caps: Caps,
    read: u64,
}

impl Budget {
    pub fn new(caps: Caps) -> Self {
        Budget { caps, read: 0 }
    }

    /// How many bytes the next `read()` asks for at `elapsed` since the start: the buffer, or less
    /// so the byte cap is never passed; or the cap that stops the run. Time is checked first: a run
    /// out of time reads nothing more.
    pub fn next_len(&self, elapsed: Duration, buffer: usize) -> Result<usize, Stop> {
        if elapsed >= self.caps.max_wall {
            return Err(Stop::TimeCap);
        }
        let remaining = self.caps.max_bytes.saturating_sub(self.read);
        if remaining == 0 {
            return Err(Stop::ByteCap);
        }
        Ok(usize::try_from(remaining).map_or(buffer, |r| r.min(buffer)))
    }

    /// Counts `n` bytes a `read()` returned.
    pub fn add(&mut self, n: usize) {
        self.read = self.read.saturating_add(u64::try_from(n).unwrap_or(u64::MAX));
    }

    pub fn total(&self) -> u64 {
        self.read
    }
}

/// What happened to one planned file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileStatus {
    /// Read to its end.
    Read,
    /// Read in part: a cap stopped the run inside it.
    Partial,
    /// Not in this bundle: skipped.
    Missing,
    /// Could not be opened or read (anything but missing): skipped.
    Error,
    /// A cap stopped the run before it.
    NotReached,
    /// `--dry-run`: what the run would read.
    Planned,
}

impl FileStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            FileStatus::Read => "read",
            FileStatus::Partial => "partial",
            FileStatus::Missing => "missing",
            FileStatus::Error => "error",
            FileStatus::NotReached => "not_reached",
            FileStatus::Planned => "planned",
        }
    }
}

/// One file's line in the report.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileReport {
    /// Relative to the bundle.
    pub file: String,
    pub bytes: u64,
    pub wall_ms: u64,
    pub status: FileStatus,
}

/// What `--dry-run` prints: for each planned file with its size (None: missing), the bytes a run
/// would read under the byte cap alone (the wall-time cap depends on the disk), and the stop the
/// byte cap would cause.
pub fn dry_plan(files: &[(String, Option<u64>)], caps: Caps) -> (Vec<FileReport>, Stop) {
    let mut left = caps.max_bytes;
    let mut stop = Stop::Done;
    let reports = files
        .iter()
        .map(|(file, size)| {
            let (bytes, status) = match size {
                None => (0, FileStatus::Missing),
                Some(_) if left == 0 => {
                    stop = Stop::ByteCap;
                    (0, FileStatus::NotReached)
                }
                Some(size) => {
                    let bytes = (*size).min(left);
                    left = left.saturating_sub(bytes);
                    if bytes < *size {
                        stop = Stop::ByteCap;
                    }
                    (bytes, FileStatus::Planned)
                }
            };
            FileReport { file: file.clone(), bytes, wall_ms: 0, status }
        })
        .collect();
    (reports, stop)
}

/// The one line a run writes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    pub bundle: Option<String>,
    pub caps: Caps,
    pub files: Vec<FileReport>,
    pub total_bytes: u64,
    pub wall_ms: u64,
    pub stop: Stop,
    /// The usage error, for [`Stop::Usage`].
    pub error: Option<String>,
}

impl Report {
    /// One JSON object, no newline.
    pub fn to_json(&self) -> String {
        let mut out = String::from("{\"event\":\"cmux-launch-preread\"");
        out.push_str(",\"bundle\":");
        match &self.bundle {
            Some(b) => push_string(&mut out, b),
            None => out.push_str("null"),
        }
        let _ = write!(
            out,
            ",\"caps\":{{\"max_bytes\":{},\"max_ms\":{}}},\"files\":[",
            self.caps.max_bytes,
            millis(self.caps.max_wall)
        );
        for (i, f) in self.files.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str("{\"file\":");
            push_string(&mut out, &f.file);
            let _ = write!(
                out,
                ",\"bytes\":{},\"wall_ms\":{},\"status\":\"{}\"}}",
                f.bytes,
                f.wall_ms,
                f.status.as_str()
            );
        }
        let _ = write!(
            out,
            "],\"total_bytes\":{},\"wall_ms\":{},\"stop\":\"{}\"",
            self.total_bytes,
            self.wall_ms,
            self.stop.as_str()
        );
        if let Some(error) = &self.error {
            out.push_str(",\"error\":");
            push_string(&mut out, error);
        }
        out.push('}');
        out
    }
}

/// Whole milliseconds, saturating.
pub fn millis(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

fn push_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if u32::from(c) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, String> {
        parse_args(list.iter().map(|s| (*s).to_owned()))
    }

    const MIB: u64 = 1024 * 1024;

    #[test]
    fn default_caps_are_160_mib_and_5_s() {
        let a = args(&[]).unwrap();
        assert_eq!(a.caps.max_bytes, 160 * MIB);
        assert_eq!(a.caps.max_wall, Duration::from_secs(5));
        assert!(!a.dry_run);
        assert_eq!(a.bundle, None);
    }

    #[test]
    fn arguments_parse_and_caps_clamp_to_their_ceilings() {
        let a = args(&[
            "--dry-run",
            "--bundle",
            "/Applications/cmux NEXT.app",
            "--max-bytes",
            "1000",
            "--max-ms",
            "250",
        ])
        .unwrap();
        assert!(a.dry_run);
        assert_eq!(a.bundle.as_deref(), Some(Path::new("/Applications/cmux NEXT.app")));
        assert_eq!(a.caps, Caps { max_bytes: 1000, max_wall: Duration::from_millis(250) });
        let big = args(&["--max-bytes", "99999999999999", "--max-ms", "99999999"]).unwrap();
        assert_eq!(big.caps.max_bytes, MAX_BYTES_CEILING);
        assert_eq!(big.caps.max_wall, MAX_WALL_CEILING);
    }

    #[test]
    fn bad_arguments_are_errors() {
        assert!(args(&["--max-bytes"]).is_err());
        assert!(args(&["--max-bytes", "-1"]).is_err());
        assert!(args(&["--max-ms", "1.5"]).is_err());
        assert!(args(&["--bundle"]).is_err());
        assert!(args(&["--fast"]).is_err());
    }

    #[test]
    fn bundle_is_the_app_that_holds_the_reader() {
        let exe =
            Path::new("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-launch-preread");
        assert_eq!(bundle_of(exe).as_deref(), Some(Path::new("/Applications/cmux NEXT.app")));
        // The innermost app wins (a helper app inside the bundle would be its own).
        let nested = Path::new("/A.app/Contents/Helpers/B.app/Contents/MacOS/x");
        assert_eq!(bundle_of(nested).as_deref(), Some(Path::new("/A.app/Contents/Helpers/B.app")));
        // Outside a bundle, or an .app with no Contents above the reader: none.
        assert_eq!(bundle_of(Path::new("/usr/local/bin/cmux-launch-preread")), None);
        assert_eq!(bundle_of(Path::new("/tmp/x.app/bin/cmux-launch-preread")), None);
        assert_eq!(bundle_of(Path::new("/tmp/.app/Contents/x")), None);
    }

    #[test]
    fn plan_reads_executables_in_name_order_then_the_frameworks() {
        let p = plan(&[
            "cmux".into(),
            "cmux-stub".into(),
            "Cmux".into(),
            String::new(),
            "a/b".into(),
            "cmux".into(),
        ]);
        assert_eq!(
            p,
            vec![
                "Contents/MacOS/Cmux".to_owned(),
                "Contents/MacOS/cmux".to_owned(),
                "Contents/MacOS/cmux-stub".to_owned(),
                FRAMEWORK_FILES[0].to_owned(),
                FRAMEWORK_FILES[1].to_owned(),
            ]
        );
        assert_eq!(plan(&[]), FRAMEWORK_FILES.iter().map(|f| (*f).to_owned()).collect::<Vec<_>>());
    }

    #[test]
    fn budget_never_reads_past_the_byte_cap() {
        let mut b = Budget::new(Caps { max_bytes: 2 * MIB + 10, max_wall: Duration::from_secs(5) });
        let t = Duration::ZERO;
        assert_eq!(b.next_len(t, BUFFER_BYTES), Ok(BUFFER_BYTES));
        b.add(BUFFER_BYTES);
        b.add(BUFFER_BYTES);
        assert_eq!(b.next_len(t, BUFFER_BYTES), Ok(10));
        b.add(10);
        assert_eq!(b.next_len(t, BUFFER_BYTES), Err(Stop::ByteCap));
        assert_eq!(b.total(), 2 * MIB + 10);
        assert_eq!(
            Budget::new(Caps { max_bytes: 0, ..Caps::default() }).next_len(t, BUFFER_BYTES),
            Err(Stop::ByteCap)
        );
    }

    #[test]
    fn budget_stops_at_the_wall_time_cap_first() {
        let b = Budget::new(Caps { max_bytes: 0, max_wall: Duration::from_secs(5) });
        assert_eq!(
            b.next_len(Duration::from_secs(5), BUFFER_BYTES),
            Err(Stop::TimeCap),
            "time wins a tie"
        );
        let b = Budget::new(Caps::default());
        assert_eq!(b.next_len(Duration::from_millis(4999), BUFFER_BYTES), Ok(BUFFER_BYTES));
        assert_eq!(b.next_len(Duration::from_secs(6), BUFFER_BYTES), Err(Stop::TimeCap));
    }

    #[test]
    fn dry_plan_skips_missing_files_and_names_the_byte_cap() {
        let files = vec![
            ("Contents/MacOS/cmux".to_owned(), Some(30 * MIB)),
            (FRAMEWORK_FILES[0].to_owned(), None),
            (FRAMEWORK_FILES[1].to_owned(), Some(200 * MIB)),
        ];
        let (reports, stop) = dry_plan(&files, Caps::default());
        assert_eq!(stop, Stop::ByteCap);
        assert_eq!(
            reports.iter().map(|r| (r.bytes, r.status)).collect::<Vec<_>>(),
            vec![
                (30 * MIB, FileStatus::Planned),
                (0, FileStatus::Missing),
                (130 * MIB, FileStatus::Planned),
            ]
        );
        let (_, stop) = dry_plan(&files[..2], Caps::default());
        assert_eq!(stop, Stop::Done);
        let (reports, stop) = dry_plan(&files, Caps { max_bytes: 30 * MIB, ..Caps::default() });
        assert_eq!(stop, Stop::ByteCap);
        assert_eq!(reports[2].status, FileStatus::NotReached);
    }

    #[test]
    fn report_is_one_json_line_with_escaped_paths() {
        let r = Report {
            bundle: Some("/Applications/cmux \"NEXT\".app".into()),
            caps: Caps::default(),
            files: vec![FileReport {
                file: "Contents/MacOS/cmux".into(),
                bytes: 5,
                wall_ms: 1,
                status: FileStatus::Read,
            }],
            total_bytes: 5,
            wall_ms: 2,
            stop: Stop::Done,
            error: Some("a\nb".into()),
        };
        let json = r.to_json();
        assert!(!json.contains('\n'));
        assert_eq!(
            json,
            "{\"event\":\"cmux-launch-preread\",\"bundle\":\"/Applications/cmux \\\"NEXT\\\".app\",\
             \"caps\":{\"max_bytes\":167772160,\"max_ms\":5000},\
             \"files\":[{\"file\":\"Contents/MacOS/cmux\",\"bytes\":5,\"wall_ms\":1,\"status\":\"read\"}],\
             \"total_bytes\":5,\"wall_ms\":2,\"stop\":\"done\",\"error\":\"a\\nb\"}"
        );
        let none = Report { bundle: None, files: vec![], error: None, stop: Stop::NoBundle, ..r };
        assert!(none.to_json().contains("\"bundle\":null"));
        assert!(none.to_json().ends_with("\"stop\":\"no_bundle\"}"));
    }
}
