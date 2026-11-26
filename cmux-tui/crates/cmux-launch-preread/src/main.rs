//! `cmux-launch-preread`: the system calls of the login-time pre-read (the plan, the caps and the
//! report are the library's, unit tested). Run by the bundle's LaunchAgent at login while
//! `app.backgroundReady` is `warmAtLogin`; reads, prints one JSON line and exits 0, always.

use std::fs::File;
use std::io::{ErrorKind, Read};
use std::path::Path;
use std::time::Instant;

use cmux_launch_preread::{
    BUFFER_BYTES, Budget, FileReport, FileStatus, MACOS_DIR, Report, Stop, bundle_of, dry_plan,
    millis, parse_args, plan,
};

fn main() {
    let started = Instant::now();
    background_priority();
    let line = run(started).to_json();
    println!("{line}");
    system_log(&line);
}

fn run(started: Instant) -> Report {
    let mut report = Report {
        bundle: None,
        caps: Default::default(),
        files: Vec::new(),
        total_bytes: 0,
        wall_ms: 0,
        stop: Stop::Done,
        error: None,
    };
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(args) => args,
        Err(error) => {
            report.stop = Stop::Usage;
            report.error = Some(error);
            return report;
        }
    };
    report.caps = args.caps;
    let Some(bundle) =
        args.bundle.or_else(|| std::env::current_exe().ok().and_then(|exe| bundle_of(&exe)))
    else {
        report.stop = Stop::NoBundle;
        return report;
    };
    report.bundle = Some(bundle.display().to_string());
    let files = plan(&macos_files(&bundle));

    if args.dry_run {
        let sized: Vec<(String, Option<u64>)> = files
            .into_iter()
            .map(|f| {
                let size = std::fs::metadata(bundle.join(&f))
                    .ok()
                    .filter(|m| m.is_file())
                    .map(|m| m.len());
                (f, size)
            })
            .collect();
        let (reports, would_stop) = dry_plan(&sized, args.caps);
        report.total_bytes = reports.iter().map(|r| r.bytes).fold(0, u64::saturating_add);
        report.files = reports;
        report.stop = if would_stop == Stop::ByteCap { Stop::ByteCap } else { Stop::DryRun };
        report.wall_ms = millis(started.elapsed());
        return report;
    }

    let mut budget = Budget::new(args.caps);
    let mut buffer = vec![0u8; BUFFER_BYTES];
    let mut stopped: Option<Stop> = None;
    for file in files {
        if stopped.is_some() {
            report.files.push(FileReport {
                file,
                bytes: 0,
                wall_ms: 0,
                status: FileStatus::NotReached,
            });
            continue;
        }
        let (file_report, stop) =
            read_one(&bundle.join(&file), file, &mut budget, &mut buffer, started);
        report.files.push(file_report);
        stopped = stop;
    }
    report.total_bytes = budget.total();
    report.stop = stopped.unwrap_or(Stop::Done);
    report.wall_ms = millis(started.elapsed());
    report
}

/// The regular files of `Contents/MacOS`, by name; none when the folder is unreadable.
fn macos_files(bundle: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(bundle.join(MACOS_DIR)) else { return Vec::new() };
    entries
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|e| e.file_name().into_string().ok())
        .collect()
}

/// Reads `path` to its end with plain `read()` calls into `buffer` (page cache fill), or until a cap.
fn read_one(
    path: &Path,
    file: String,
    budget: &mut Budget,
    buffer: &mut [u8],
    started: Instant,
) -> (FileReport, Option<Stop>) {
    let file_started = Instant::now();
    let before = budget.total();
    let done = |status, budget: &Budget| FileReport {
        file: file.clone(),
        bytes: budget.total().saturating_sub(before),
        wall_ms: millis(file_started.elapsed()),
        status,
    };
    let mut handle = match File::open(path) {
        Ok(handle) => handle,
        Err(e) if e.kind() == ErrorKind::NotFound => {
            return (done(FileStatus::Missing, budget), None);
        }
        Err(_) => return (done(FileStatus::Error, budget), None),
    };
    loop {
        let len = match budget.next_len(started.elapsed(), buffer.len()) {
            Ok(len) => len,
            Err(stop) => return (done(FileStatus::Partial, budget), Some(stop)),
        };
        let Some(chunk) = buffer.get_mut(..len) else {
            return (done(FileStatus::Error, budget), None);
        };
        match handle.read(chunk) {
            Ok(0) => return (done(FileStatus::Read, budget), None),
            Ok(n) => budget.add(n),
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => return (done(FileStatus::Error, budget), None),
        }
    }
}

/// Background CPU and I/O priority for the whole process (launchd's ProcessType Background and
/// LowPriorityIO say the same; this holds when the reader is run by hand too).
#[cfg(target_os = "macos")]
fn background_priority() {
    // SAFETY: setpriority takes plain integers and touches no memory of ours.
    unsafe {
        libc::setpriority(libc::PRIO_DARWIN_PROCESS, 0, libc::PRIO_DARWIN_BG);
    }
}

#[cfg(not(target_os = "macos"))]
fn background_priority() {}

/// The line in the system log too: a LaunchAgent's stdout goes nowhere (the plist names no
/// StandardOutPath: it is sealed in a bundle every user shares). `log show --predicate
/// 'process == "cmux-launch-preread"'` reads it.
#[cfg(target_os = "macos")]
fn system_log(line: &str) {
    let Ok(message) = std::ffi::CString::new(line) else { return };
    // SAFETY: both strings are NUL-terminated and live across the calls; "%s" takes one string.
    unsafe {
        libc::openlog(c"cmux-launch-preread".as_ptr(), libc::LOG_PID, libc::LOG_USER);
        libc::syslog(libc::LOG_NOTICE, c"%s".as_ptr(), message.as_ptr());
        libc::closelog();
    }
}

#[cfg(not(target_os = "macos"))]
fn system_log(_line: &str) {}
