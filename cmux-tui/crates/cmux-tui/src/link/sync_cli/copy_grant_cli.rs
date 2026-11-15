//! `cmux link copy-grant`: the app's "Copy anyway" for a folder refused as too big to copy
//! ([`super::size_cap`]). `measure` counts the folder to the end, by the rules a copy counts by,
//! reporting as it goes, and answers the canonical folder with what it found; the app shows that,
//! and `record` grants exactly that, plus the margin, for a day. `record` refuses numbers above
//! what a `measure` of the same folder found in the last hour, or with no such count. One JSON line on stdout; `measure` also prints one JSON line on stderr per
//! report (`{"counted_bytes":N,"counted_files":M}`). A count is cancelled by ending the process.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::json;

use super::size_cap;

const USAGE: &str = "usage: cmux link copy-grant measure FOLDER
       cmux link copy-grant record FOLDER --bytes BYTES --files FILES
       (measure: counts what a copy of FOLDER sends, to the end;
        record: lets copies of FOLDER send that much, plus 1 GB or 10% and 10,000 files or 10%,
        for a day)";

/// The error code of a count or a grant that failed.
const FAILED: &str = "copy.grant_failed";

enum Command {
    Measure(PathBuf),
    Record { folder: PathBuf, bytes: u64, files: u64 },
}

fn parse(args: &[String]) -> Option<Command> {
    match args {
        [verb, folder] if verb == "measure" => Some(Command::Measure(PathBuf::from(folder))),
        [verb, rest @ ..] if verb == "record" => {
            let (mut folder, mut bytes, mut files) = (None, None, None);
            let mut words = rest.iter();
            while let Some(word) = words.next() {
                match word.as_str() {
                    "--bytes" => bytes = Some(words.next()?.parse().ok()?),
                    "--files" => files = Some(words.next()?.parse().ok()?),
                    _ if folder.is_none() && !word.starts_with("--") => {
                        folder = Some(PathBuf::from(word));
                    }
                    _ => return None,
                }
            }
            Some(Command::Record { folder: folder?, bytes: bytes?, files: files? })
        }
        _ => None,
    }
}

/// `cmux link copy-grant ...`: the exit code (0, 1 on a failure, 64 on a usage error).
pub(crate) fn run(args: &[String]) -> i32 {
    let Some(command) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let answer = match command {
        Command::Measure(folder) => {
            let progress = size_cap::Progress(Arc::new(|bytes, files| {
                eprintln!("{}", json!({ "counted_bytes": bytes, "counted_files": files }));
            }));
            size_cap::measure(&folder, Some(progress)).map(|measured| {
                json!({
                    "ok": true,
                    "folder": measured.folder,
                    "bytes": measured.bytes,
                    "files": measured.files,
                    "git_bytes": measured.git_bytes,
                })
            })
        }
        Command::Record { folder, bytes, files } => {
            size_cap::record(&folder, bytes, files).map(|grant| {
                json!({
                    "ok": true,
                    "folder": grant.folder,
                    "bytes": grant.bytes,
                    "files": grant.files,
                    "max_bytes": grant.max_bytes(),
                    "max_files": grant.max_files(),
                    "expires_at": grant.expires_at(),
                })
            })
        }
    };
    match answer {
        Ok(line) => {
            println!("{line}");
            0
        }
        Err(error) => {
            let error = format!("{error:#}");
            println!("{}", json!({ "ok": false, "error": error, "error_code": FAILED }));
            1
        }
    }
}

#[cfg(test)]
#[path = "copy_grant_cli_tests.rs"]
mod tests;
