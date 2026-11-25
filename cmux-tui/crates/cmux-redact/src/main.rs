//! `cmux-redact`: reads text on stdin and writes it to stdout with known secret shapes masked.
//!
//! The matcher is acpmux's `secret_scan::mask` (gitleaks' rule set plus cmux's own), used as a
//! library, so there is a single rule set and no second copy to drift. The text is
//! handled one line at a time (a transcript is JSONL), so memory stays flat for any size. A line
//! that is not valid UTF-8 is decoded lossily first: a masker must never pass bytes it could not
//! read. Exit status is 0 on success and 1 on an I/O error; the output is then incomplete and the
//! caller must discard it.

use acpmux::secret_scan;
use std::io::{self, BufRead, BufWriter, Write};
use std::process::ExitCode;

/// Masks one line (with its trailing newline, if any) into `out`.
pub fn redact_line(line: &[u8], out: &mut Vec<u8>) {
    let text = String::from_utf8_lossy(line);
    // Fast path: nothing here needs a scan when a line is blank.
    if text.trim().is_empty() {
        out.extend_from_slice(text.as_bytes());
        return;
    }
    out.extend_from_slice(secret_scan::mask(&text).as_bytes());
}

/// Redacts all of `input` into `output`.
pub fn redact_stream<R: BufRead, W: Write>(mut input: R, output: W) -> io::Result<()> {
    let mut output = BufWriter::with_capacity(256 * 1024, output);
    let mut line = Vec::new();
    let mut out = Vec::new();
    loop {
        line.clear();
        if input.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        out.clear();
        redact_line(&line, &mut out);
        output.write_all(&out)?;
    }
    output.flush()
}

fn main() -> ExitCode {
    let input = io::BufReader::with_capacity(256 * 1024, io::stdin().lock());
    match redact_stream(input, io::stdout().lock()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-redact: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests;
