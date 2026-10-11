//! Minimal `--key value` option parsing.

use std::collections::HashMap;

pub struct Opts {
    map: HashMap<String, String>,
}

impl Opts {
    pub fn parse(args: &[String]) -> Result<Self, String> {
        let mut map = HashMap::new();
        let mut it = args.iter();
        while let Some(k) = it.next() {
            let key = k.strip_prefix("--").ok_or_else(|| format!("unexpected argument {k}"))?;
            let val = it.next().ok_or_else(|| format!("missing value for --{key}"))?;
            map.insert(key.to_string(), val.clone());
        }
        Ok(Self { map })
    }

    pub fn str_or(&self, key: &str, default: &str) -> String {
        self.map.get(key).cloned().unwrap_or_else(|| default.to_string())
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
