//! `LaunchRecordRequest` (Windows/LaunchRecordRequest.swift): `--record-launch DIR
//! [--record-launch-seconds N]`.

use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchRecordRequest {
    pub dir: String,
    pub seconds: f64,
}

/// `expandingTildeInPath` for `~` and `~/...` (another user's `~name` stays as given).
pub fn expand_tilde(path: &str, home: &str) -> String {
    if path == "~" {
        home.to_string()
    } else if let Some(rest) = path.strip_prefix("~/") {
        format!("{}/{rest}", home.trim_end_matches('/'))
    } else {
        path.to_string()
    }
}

impl LaunchRecordRequest {
    /// `init?(arguments:)`: nil without a directory after the flag; seconds 6 by default, 0.1...12.
    pub fn parse(arguments: &[String], home: &str) -> Option<Self> {
        let flag = arguments.iter().position(|a| a == "--record-launch")?;
        let dir = arguments.get(flag + 1).filter(|d| !d.starts_with("--"))?;
        let asked = arguments
            .iter()
            .position(|a| a == "--record-launch-seconds")
            .and_then(|i| arguments.get(i + 1))
            .and_then(|s| s.parse::<f64>().ok());
        Some(Self {
            dir: expand_tilde(dir, home),
            seconds: 0.1f64.max(asked.unwrap_or(6.)).min(12.),
        })
    }
}
