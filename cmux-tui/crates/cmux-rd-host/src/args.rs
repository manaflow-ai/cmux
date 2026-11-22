//! Minimal `--key value` option parsing, plus the few value-less flags in [`FLAGS`].

use std::collections::HashMap;

/// Options that take no value (`--listen-systemd`, `--no-udp-link`); each is stored as `"1"`.
const FLAGS: &[&str] = &["listen-systemd", "no-udp-link"];

pub struct Opts {
    map: HashMap<String, String>,
}

impl Opts {
    pub fn parse(args: &[String]) -> Result<Self, String> {
        let mut map = HashMap::new();
        let mut it = args.iter();
        while let Some(k) = it.next() {
            let key = k.strip_prefix("--").ok_or_else(|| format!("unexpected argument {k}"))?;
            if FLAGS.contains(&key) {
                map.insert(key.to_string(), "1".to_string());
                continue;
            }
            let val = it.next().ok_or_else(|| format!("missing value for --{key}"))?;
            map.insert(key.to_string(), val.clone());
        }
        Ok(Self { map })
    }

    pub fn str_or(&self, key: &str, default: &str) -> String {
        self.map.get(key).cloned().unwrap_or_else(|| default.to_string())
    }

    /// Whether a value-less flag (or `--key 1`) was given.
    pub fn flag(&self, key: &str) -> bool {
        self.map.get(key).is_some_and(|v| v == "1")
    }

    /// A switch that is on by `default`: `--key 0` (or `false`, `off`) turns it off, any other
    /// value turns it on.
    #[cfg_attr(not(feature = "link"), allow(dead_code))] // `cmux-rd serve` (feature `link`)
    pub fn flag_or(&self, key: &str, default: bool) -> bool {
        match self.map.get(key).map(String::as_str) {
            None => default,
            Some("0" | "false" | "off") => false,
            Some(_) => true,
        }
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.map.get(key).map(String::as_str)
    }

    /// `--encode-profile standard|ultra` (default standard): the one switch for ultra.
    pub fn encode_profile(&self) -> Result<cmux_rd_core::profile::EncodeProfile, String> {
        match self.map.get("encode-profile") {
            None => Ok(cmux_rd_core::profile::EncodeProfile::Standard),
            Some(v) => cmux_rd_core::profile::EncodeProfile::parse(v)
                .ok_or_else(|| format!("invalid value for --encode-profile: {v} (standard|ultra)")),
        }
    }

    pub fn num_or<T: std::str::FromStr>(&self, key: &str, default: T) -> Result<T, String> {
        match self.map.get(key) {
            None => Ok(default),
            Some(v) => v.parse().map_err(|_| format!("invalid value for --{key}: {v}")),
        }
    }
}

#[cfg(test)]
#[path = "args_tests.rs"]
mod tests;
