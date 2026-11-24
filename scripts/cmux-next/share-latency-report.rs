//! Read one latency sample in milliseconds per stdin line and print one JSON report.
//!
//! This CLI and the fake-room report both include `share_latency_report.rs`,
//! the shared implementation extracted from cmux#52169 (68b153f8).

#[path = "../../cmux-tui/crates/cmux-tui-core/src/server/share_latency_report.rs"]
mod share_latency_report;

use share_latency_report::{summarize, Summary};
use std::io::{self, BufRead};
use std::process;

fn json(summary: &Summary) -> String {
    format!(
        "{{\"n\":{},\"p50_ms\":{},\"p95_ms\":{},\"max_ms\":{},\"within_1s\":{},\"all_samples_within_1s\":{}}}",
        summary.n,
        summary.p50_ms,
        summary.p95_ms,
        summary.max_ms,
        summary.within_1s,
        summary.all_samples_within_1s,
    )
}

fn run() -> Result<(), String> {
    let stdin = io::stdin();
    let mut samples = Vec::new();
    for (line_number, line) in stdin.lock().lines().enumerate() {
        let line =
            line.map_err(|error| format!("reading stdin line {}: {error}", line_number + 1))?;
        let text = line.trim();
        if text.is_empty() {
            continue;
        }
        let value = text
            .parse::<f64>()
            .map_err(|_| format!("invalid number on line {}", line_number + 1))?;
        samples.push(value);
    }
    let summary = summarize(&samples)?;
    println!("{}", json(&summary));
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("share-latency-report: {error}");
        process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::share_latency_report::summarize;

    #[test]
    fn keeps_upper_median_and_nearest_rank() {
        let samples: Vec<f64> = (1..=20).map(f64::from).collect();
        let output = summarize(&samples).expect("report");
        assert_eq!(output.p50_ms, 11.0);
        assert_eq!(output.p95_ms, 19.0);
        assert_eq!(output.max_ms, 20.0);
        assert!(output.within_1s);
    }

    #[test]
    fn compares_raw_samples_before_display_rounding() {
        let output = summarize(&[999.96]).expect("report");
        assert_eq!(output.max_ms, 1000.0);
        assert!(output.within_1s);
        assert!(output.all_samples_within_1s);
        assert!(!summarize(&[1000.0]).unwrap().within_1s);
    }

    #[test]
    fn rejects_empty_and_invalid_reports() {
        assert!(summarize(&[]).is_err());
        assert!(summarize(&[-1.0]).is_err());
    }
}
