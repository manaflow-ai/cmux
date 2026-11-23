//! The knobs: one struct holds every load the simulator applies (the table in
//! `cmux-next-ios/design/duress-sim.md`), its three presets, and the spec string
//! `PRESET[,knob=value...]` that picks a preset and overrides some of its knobs.

use cmux_fault::shaper::{LinkProfile, ProfileFile};
use serde::{Deserialize, Serialize};

/// Every knob, resolved. `duress.json` carries this as written here.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Knobs {
    /// The preset the spec started from.
    pub preset: String,
    /// Styled scrollback rows fed to each terminal before the bench starts.
    pub history_rows: u64,
    /// Terminal kbit/s still streaming during the bench (Claude Code redraws).
    pub stream_kbps: u64,
    /// Terminals fed at once (the visible one plus hidden ones). Read by the app's reader.
    pub panes: u64,
    /// Workspaces the mock list holds. Read by the app's reader.
    pub workspaces: u64,
    /// acpmux records the chat replays (looped from the fixture, seq renumbered).
    pub chat_records: u64,
    /// Chat records a second while the bench runs (0: all at once).
    pub chat_rate: u64,
    /// The `cmux-fault` link profile shaping every delivery time; `None` is no link.
    pub link: Option<String>,
    /// Busy threads in the app process. Read by the app's reader.
    pub cpu_threads: u64,
    /// The fraction of each 10 ms a busy thread spins, 0 to 1. Read by the app's reader.
    pub cpu_duty: f64,
    /// Every draw: jitter, loss, synthesized text.
    pub seed: u64,
    /// Length of the stream schedule before the reader loops it.
    pub stream_seconds: u64,
}

/// The presets, in the design table's order.
pub const PRESETS: [&str; 3] = ["idle", "duress", "heavy"];

/// Every knob a spec can set.
pub const KNOBS: [&str; 11] = [
    "history_rows",
    "stream_kbps",
    "panes",
    "workspaces",
    "chat_records",
    "chat_rate",
    "link",
    "cpu_threads",
    "cpu_duty",
    "seed",
    "stream_seconds",
];

impl Knobs {
    /// A preset by name.
    pub fn preset(name: &str) -> Result<Self, String> {
        let base = |history_rows, stream_kbps, panes, workspaces, chat_records, chat_rate| Knobs {
            preset: name.to_owned(),
            history_rows,
            stream_kbps,
            panes,
            workspaces,
            chat_records,
            chat_rate,
            link: None,
            cpu_threads: 0,
            cpu_duty: 0.0,
            seed: 1,
            stream_seconds: 120,
        };
        Ok(match name {
            "idle" => base(0, 0, 1, 20, 0, 0),
            "duress" => Knobs {
                link: Some("lte".to_owned()),
                cpu_threads: 2,
                cpu_duty: 0.5,
                ..base(10_000, 256, 4, 150, 3561, 40)
            },
            "heavy" => Knobs {
                link: Some("lossy-3".to_owned()),
                cpu_threads: 4,
                cpu_duty: 0.8,
                ..base(100_000, 2048, 8, 500, 20_000, 200)
            },
            other => {
                return Err(format!("unknown preset {other:?}; presets: {}", PRESETS.join(", ")));
            }
        })
    }

    /// `PRESET[,knob=value...]`, e.g. `heavy,link=2g-trickle,cpu_threads=6`. `link=none` turns the
    /// link off. The link is checked against the builtin profiles.
    pub fn parse(spec: &str) -> Result<Self, String> {
        let mut parts = spec.split(',').map(str::trim);
        let preset = parts.next().unwrap_or_default();
        let mut knobs = Self::preset(preset)?;
        for part in parts.filter(|part| !part.is_empty()) {
            let Some((key, value)) = part.split_once('=') else {
                return Err(format!("{part:?} is not knob=value; knobs: {}", KNOBS.join(", ")));
            };
            knobs.set(key.trim(), value.trim())?;
        }
        knobs.link_profile()?;
        Ok(knobs)
    }

    /// Sets one knob from its text.
    pub fn set(&mut self, key: &str, value: &str) -> Result<(), String> {
        let int = |value: &str| {
            value.parse::<u64>().map_err(|_| format!("{key}={value}: not a whole number"))
        };
        match key {
            "history_rows" => self.history_rows = int(value)?,
            "stream_kbps" => self.stream_kbps = int(value)?,
            "panes" => self.panes = int(value)?,
            "workspaces" => self.workspaces = int(value)?,
            "chat_records" => self.chat_records = int(value)?,
            "chat_rate" => self.chat_rate = int(value)?,
            "cpu_threads" => self.cpu_threads = int(value)?,
            "seed" => self.seed = int(value)?,
            "stream_seconds" => self.stream_seconds = int(value)?,
            "cpu_duty" => {
                let duty = value
                    .parse::<f64>()
                    .ok()
                    .filter(|duty| (0.0..=1.0).contains(duty))
                    .ok_or_else(|| format!("cpu_duty={value}: a fraction from 0 to 1"))?;
                self.cpu_duty = duty;
            }
            "link" => {
                self.link = match value {
                    "" | "none" => None,
                    name => Some(name.to_owned()),
                };
            }
            other => {
                return Err(format!("unknown knob {other:?}; knobs: {}", KNOBS.join(", ")));
            }
        }
        Ok(())
    }

    /// The link profile the knobs name, from `cmux-fault`'s builtin `link-profiles.json`.
    pub fn link_profile(&self) -> Result<Option<LinkProfile>, String> {
        let Some(name) = &self.link else {
            return Ok(None);
        };
        let file = ProfileFile::builtin();
        file.get(name).cloned().map(Some).ok_or_else(|| {
            let names: Vec<&str> = file.profiles.iter().map(|p| p.name.as_str()).collect();
            format!("unknown link profile {name:?}; profiles: none, {}", names.join(", "))
        })
    }
}

/// The presets as the design doc's table, for `cmux-duress presets`.
pub fn presets_table() -> String {
    let presets: Vec<Knobs> = PRESETS.iter().filter_map(|name| Knobs::preset(name).ok()).collect();
    let mut out = format!("{:<16}", "knob");
    for knobs in &presets {
        out.push_str(&format!("{:>12}", knobs.preset));
    }
    out.push('\n');
    for key in KNOBS {
        out.push_str(&format!("{key:<16}"));
        for knobs in &presets {
            let value = match key {
                "history_rows" => knobs.history_rows.to_string(),
                "stream_kbps" => knobs.stream_kbps.to_string(),
                "panes" => knobs.panes.to_string(),
                "workspaces" => knobs.workspaces.to_string(),
                "chat_records" => knobs.chat_records.to_string(),
                "chat_rate" => knobs.chat_rate.to_string(),
                "link" => knobs.link.clone().unwrap_or_else(|| "none".to_owned()),
                "cpu_threads" => knobs.cpu_threads.to_string(),
                "cpu_duty" => knobs.cpu_duty.to_string(),
                "seed" => knobs.seed.to_string(),
                _ => knobs.stream_seconds.to_string(),
            };
            out.push_str(&format!("{value:>12}"));
        }
        out.push('\n');
    }
    out
}
