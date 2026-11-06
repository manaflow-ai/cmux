//! A small `--name value` / `--flag` command-line reader (no dependencies).

use std::collections::BTreeMap;

pub struct Args {
    values: BTreeMap<String, String>,
    flags: Vec<String>,
}

impl Args {
    /// Parses `argv` (without the program name). `flags` are the names that take no value.
    pub fn parse(argv: &[String], flags: &[&str]) -> Result<Args, String> {
        let mut values = BTreeMap::new();
        let mut seen = Vec::new();
        let mut it = argv.iter();
        while let Some(arg) = it.next() {
            let Some(name) = arg.strip_prefix("--") else {
                return Err(format!("unexpected argument {arg:?}"));
            };
            if let Some((key, value)) = name.split_once('=') {
                values.insert(key.to_string(), value.to_string());
            } else if flags.contains(&name) {
                seen.push(name.to_string());
            } else {
                let value = it.next().ok_or_else(|| format!("--{name} needs a value"))?;
                values.insert(name.to_string(), value.clone());
            }
        }
        Ok(Args {
            values,
            flags: seen,
        })
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|f| f == name)
    }

    pub fn text(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.values
            .keys()
            .map(String::as_str)
            .chain(self.flags.iter().map(String::as_str))
    }

    pub fn num<T: std::str::FromStr>(&self, name: &str, default: T) -> Result<T, String> {
        match self.values.get(name) {
            None => Ok(default),
            Some(text) => text
                .parse()
                .map_err(|_| format!("--{name}: not a number: {text:?}")),
        }
    }

    /// `--size COLSxROWS`.
    pub fn size(&self) -> Result<Option<(usize, usize)>, String> {
        let Some(text) = self.values.get("size") else {
            return Ok(None);
        };
        let parsed = text
            .split_once('x')
            .and_then(|(c, r)| Some((c.parse().ok()?, r.parse().ok()?)));
        match parsed {
            Some((c, r)) if c > 0 && r > 0 => Ok(Some((c, r))),
            _ => Err(format!("--size is COLSxROWS, not {text:?}")),
        }
    }
}
