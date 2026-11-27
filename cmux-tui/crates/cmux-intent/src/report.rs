//! What the layer says on stderr and appends to `~/.local/state/intent/log.jsonl`, in the Python
//! layer's words and fields.

use crate::close::shell_join;
use crate::repair::{Kind, Repair};
use serde_json::json;
use std::io::Write;
use std::path::PathBuf;

const LOG_MAX: u64 = 20 << 20;

/// `prog` and `argv` as one runnable command line.
pub fn show_words(prog: &str, argv: &[String]) -> String {
    let mut all = vec![prog.to_owned()];
    all.extend(argv.iter().cloned());
    shell_join(&all)
}

/// The one line (Ran), the exact-form refusal (Exact) or the candidates as runnable commands
/// (Candidates), written to `err`.
pub fn say_to(prog: &str, argv: &[String], result: &Repair, err: &mut dyn Write) {
    match result.outcome {
        Kind::Ran => {
            let notes = result.candidates.first().map(|c| c.notes.join("; ")).unwrap_or_default();
            let _ = writeln!(
                err,
                "{prog}: ran `{}` for `{}` ({notes})",
                show_words(prog, &result.argv),
                show_words(prog, argv)
            );
        }
        Kind::Exact => {
            let word = result.word.as_deref().unwrap_or_default();
            let cand =
                result.candidates.first().map(|c| show_words(prog, &c.argv)).unwrap_or_default();
            let _ = writeln!(
                err,
                "{prog}: `{}` is not a form of {prog}, and `{word}` is destructive or outward, so nothing ran: \
                 the exact form is needed. Did you mean:\n  {cand}",
                show_words(prog, argv)
            );
        }
        Kind::Candidates => {
            let _ = writeln!(err, "{prog}: `{}` could mean (nothing ran):", show_words(prog, argv));
            for c in &result.candidates {
                let _ = writeln!(err, "  {}", show_words(prog, &c.argv));
            }
        }
        Kind::Ok | Kind::None => {}
    }
}

pub fn say(prog: &str, argv: &[String], result: &Repair) {
    say_to(prog, argv, result, &mut std::io::stderr());
}

/// The log file: `$INTENT_LOG`, else `~/.local/state/intent/log.jsonl`.
pub fn log_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("INTENT_LOG").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    let home = std::env::var_os("HOME").filter(|h| !h.is_empty())?;
    Some(PathBuf::from(home).join(".local/state/intent/log.jsonl"))
}

/// `2026-11-23T07:50:24Z` for a unix time (the civil-from-days algorithm; no date crate).
pub fn iso_utc(secs: u64) -> String {
    let (days, rem) = (i64::try_from(secs / 86_400).unwrap_or(0), secs % 86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// One JSON line in the log for a non-ok outcome. Never fails the CLI.
pub fn log(prog: &str, argv: &[String], result: &Repair) {
    if let Some(path) = log_path() {
        log_to(&path, prog, argv, result);
    }
}

pub fn log_to(path: &std::path::Path, prog: &str, argv: &[String], result: &Repair) {
    let _ = (|| -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        if std::fs::metadata(path).is_ok_and(|m| m.len() > LOG_MAX) {
            return Ok(());
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let row = json!({
            "ts": iso_utc(now),
            "cli": prog,
            "from": argv,
            "outcome": result.outcome.name(),
            "to": result.candidates.iter().map(|c| &c.argv).collect::<Vec<_>>(),
            "notes": result.candidates.iter().flat_map(|c| c.notes.iter()).collect::<Vec<_>>(),
            "error": result.error.chars().take(300).collect::<String>(),
            "session": std::env::var("ACPMUX_SESSION_NAME").unwrap_or_default(),
        });
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
        writeln!(file, "{row}")
    })();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_date_is_utc_iso() {
        assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso_utc(1_795_420_224), "2026-11-23T07:50:24Z");
    }
}
