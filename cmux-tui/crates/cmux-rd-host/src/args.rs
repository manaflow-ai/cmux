//! Minimal `--key value` option parsing, plus the few value-less flags in [`FLAGS`].

use std::collections::HashMap;

/// Options that take no value (`--listen-systemd`); each is stored as `"1"`.
const FLAGS: &[&str] = &["listen-systemd"];

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

    pub fn get(&self, key: &str) -> Option<&str> {
        self.map.get(key).map(String::as_str)
    }

    pub fn num_or<T: std::str::FromStr>(&self, key: &str, default: T) -> Result<T, String> {
        match self.map.get(key) {
            None => Ok(default),
            Some(v) => v.parse().map_err(|_| format!("invalid value for --{key}: {v}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Opts, String> {
        Opts::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn listen_systemd_takes_no_value() {
        let o = parse(&["--listen-systemd", "--peer-uid", "0", "--display", ":99"]).expect("parse");
        assert!(o.flag("listen-systemd"));
        assert_eq!(o.get("peer-uid"), Some("0"));
        assert_eq!(o.get("display"), Some(":99"));
        assert!(!parse(&["--display", ":99"]).expect("parse").flag("listen-systemd"));
        assert!(parse(&["--display"]).is_err());
    }
}
