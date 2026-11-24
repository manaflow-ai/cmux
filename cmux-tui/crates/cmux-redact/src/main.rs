//! `cmux-redact`: reads text on stdin and writes it to stdout with known secret shapes masked.
//!
//! The matcher is acpmux's `secret_scan` (gitleaks' rule set plus cmux's own), compiled in from
//! that one source file, so there is a single rule set and no second copy to drift. The text is
//! handled one line at a time (a transcript is JSONL), so memory stays flat for any size. A line
//! that is not valid UTF-8 is decoded lossily first: a masker must never pass bytes it could not
//! read. Exit status is 0 on success and 1 on an I/O error; the output is then incomplete and the
//! caller must discard it.

#[allow(dead_code, unreachable_pub, clippy::all)]
#[path = "../../acpmux/src/secret_scan.rs"]
mod secret_scan;

use std::io::{self, BufRead, BufWriter, Write};

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

/// Redacts all of `input` into `output`; returns the number of lines read.
pub fn redact_stream<R: BufRead, W: Write>(mut input: R, output: W) -> io::Result<u64> {
    let mut output = BufWriter::with_capacity(256 * 1024, output);
    let mut line = Vec::new();
    let mut out = Vec::new();
    let mut lines = 0u64;
    loop {
        line.clear();
        if input.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        out.clear();
        redact_line(&line, &mut out);
        output.write_all(&out)?;
        lines += 1;
    }
    output.flush()?;
    Ok(lines)
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    if let Err(error) =
        redact_stream(io::BufReader::with_capacity(256 * 1024, stdin.lock()), stdout.lock())
    {
        eprintln!("cmux-redact: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests;
